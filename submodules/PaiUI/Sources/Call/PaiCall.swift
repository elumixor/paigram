import AVFoundation
import CallKit
import Foundation
import UIKit

/// The one voice call with an agent: started from anywhere (`PaiCall.shared.start(agent:)`), shown in its own
/// window over the app, carried by CallKit so it is a real call (lock screen, AirPods controls, keeps running with
/// the screen locked). Audio goes both ways over the daemon's `/calls/<id>/ws` as 24 kHz PCM16.
/// Everything here runs on the main thread except the socket's audio, which goes straight to the player.
@available(iOS 16.0, *)
public final class PaiCall: NSObject, ObservableObject {
    public static let shared = PaiCall()
    /// Posted when a call ends, so lists of calls can reload.
    public static let ended = Notification.Name("PaiCall.ended")

    public struct Line: Identifiable, Equatable {
        public let id: Int
        public let role: String
        public var text: String
        public var final: Bool
    }

    /// Whether a call is in progress (the screen may still show an ended one for a moment).
    @Published public private(set) var active = false
    @Published public private(set) var slug = ""
    /// connecting, listening, thinking, speaking, ended.
    @Published public private(set) var state = "connecting"
    @Published public private(set) var engine: String
    @Published public private(set) var engines = PaiCallEngine.defaults
    @Published public private(set) var muted = false
    @Published public private(set) var connectedAt: Date?
    @Published public private(set) var lines: [Line] = []
    @Published public private(set) var note: String?
    @Published public private(set) var endReason: String?
    @Published public private(set) var minimized = false

    private static let engineKey = "pai.call.engine"
    private let audio = PaiCallAudio()
    private let urlSession = URLSession(configuration: .default)
    private let controller = CXCallController()
    private var provider: CXProvider?
    private var uuid: UUID?
    private var callId: String?
    private var socket: URLSessionWebSocketTask?
    private var streaming = false
    private var usesCallKit = false
    private var nextLineId = 0
    private var noteClear: DispatchWorkItem?

    /// CallKit is not in the simulator, nor allowed in China; the call then runs on the audio session alone.
    private static var callKitAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let region = Locale.current.region?.identifier ?? ""
        return region != "CN" && region != "CHN"
        #endif
    }

    private override init() {
        engine = UserDefaults.standard.string(forKey: Self.engineKey) ?? "claude"
        super.init()
        if Self.callKitAvailable {
            let configuration = CXProviderConfiguration()
            configuration.supportsVideo = false
            configuration.maximumCallGroups = 1
            configuration.maximumCallsPerCallGroup = 1
            configuration.supportedHandleTypes = [.generic]
            configuration.includesCallsInRecents = false
            configuration.iconTemplateImageData = UIImage(systemName: "waveform")?.pngData()
            let provider = CXProvider(configuration: configuration)
            provider.setDelegate(self, queue: nil)
            self.provider = provider
        }
        audio.onCapture = { [weak self] chunk in
            guard let self, self.streaming, let socket = self.socket else { return }
            socket.send(.data(chunk)) { _ in }
        }
        Task { await refreshEngines() }
    }

    public var agentName: String { PaiChat.agent(slug)?.name ?? slug }

    // MARK: Controls

    /// Calls an agent; with a call already on, brings its screen back instead.
    public func start(agent slug: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.start(agent: slug) }
            return
        }
        if active {
            setMinimized(false)
            return
        }
        self.slug = slug
        active = true
        state = "connecting"
        muted = false
        connectedAt = nil
        lines = []
        note = nil
        endReason = nil
        callId = nil
        streaming = false
        minimized = false
        PaiCallWindow.show()

        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard self.active else { return }
                guard granted else {
                    self.finish(reason: "Microphone access is off: Settings › Paigram › Microphone", failed: true)
                    return
                }
                self.begin()
            }
        }
    }

    public func hangUp() {
        guard active else {
            PaiCallWindow.hide()
            return
        }
        if usesCallKit, let uuid {
            controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { error in
                if error != nil { DispatchQueue.main.async { self.hangUpLocally() } }
            }
        } else {
            hangUpLocally()
        }
    }

    public func setMuted(_ on: Bool) {
        if usesCallKit, let uuid {
            controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: on))) { error in
                if error != nil { DispatchQueue.main.async { self.applyMute(on) } }
            }
        } else {
            applyMute(on)
        }
    }

    public func setEngine(_ id: String) {
        guard id != engine else { return }
        engine = id
        UserDefaults.standard.set(id, forKey: Self.engineKey)
        if streaming { sendJSON(["type": "engine", "engine": id]) }
    }

    public func setMinimized(_ on: Bool) {
        minimized = on
        PaiCallWindow.layout()
    }

    public func label(engine id: String?) -> String {
        guard let id else { return "" }
        return engines.first(where: { $0.id == id })?.label ?? id
    }

    func refreshEngines() async {
        guard let list = try? await PaiClient().calls(limit: 1), !list.engines.isEmpty else { return }
        await MainActor.run { self.engines = list.engines }
    }

    // MARK: Lifecycle

    private func begin() {
        if let provider {
            let uuid = UUID()
            self.uuid = uuid
            usesCallKit = true
            let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: agentName))
            action.isVideo = false
            controller.request(CXTransaction(action: action)) { error in
                guard error != nil else { return }
                DispatchQueue.main.async {
                    // CallKit refused (another call, restrictions): the call still runs, just not as a system call.
                    self.usesCallKit = false
                    self.uuid = nil
                    self.beginWithoutCallKit()
                }
            }
            _ = provider
        } else {
            beginWithoutCallKit()
        }
    }

    private func beginWithoutCallKit() {
        usesCallKit = false
        do {
            try PaiCallAudio.configureSession()
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            finish(reason: "Audio unavailable: \(error.localizedDescription)", failed: true)
            return
        }
        startAudio()
        connect()
    }

    private func startAudio() {
        audio.muted = muted
        do {
            try audio.start()
        } catch {
            show(note: "Microphone failed: \(error.localizedDescription)")
        }
    }

    private func connect() {
        let slug = self.slug, engine = self.engine
        Task {
            do {
                let call = try await PaiClient().startCall(agent: slug, engine: engine)
                await MainActor.run { self.open(call) }
            } catch {
                await MainActor.run { self.finish(reason: error.localizedDescription, failed: true) }
            }
        }
    }

    private func open(_ call: PaiCallRecord) {
        guard active else {
            Task { try? await PaiClient().endCall(call.id) }
            return
        }
        callId = call.id
        let base = PaiSecrets.baseURL.hasSuffix("/") ? String(PaiSecrets.baseURL.dropLast()) : PaiSecrets.baseURL
        guard let ws = call.ws, var components = URLComponents(string: base + ws) else {
            finish(reason: "The server gave no call socket", failed: true)
            return
        }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        guard let url = components.url else {
            finish(reason: "Bad call socket address", failed: true)
            return
        }
        let task = urlSession.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        socket = task
        task.resume()
        receive(task)
    }

    /// Reads the socket until it closes. Audio and `clear` act right here, in arrival order; the rest goes to main.
    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(.data(data)):
                self.audio.play(data)
                self.receive(task)
            case let .success(.string(text)):
                if let data = text.data(using: .utf8), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    if json["type"] as? String == "clear" { self.audio.flush() }
                    DispatchQueue.main.async { self.handle(json) }
                }
                self.receive(task)
            case .success:
                self.receive(task)
            case .failure:
                DispatchQueue.main.async {
                    guard self.socket === task, self.active else { return }
                    self.finish(reason: "Connection lost", failed: true)
                }
            }
        }
    }

    private func handle(_ json: [String: Any]) {
        guard active else { return }
        switch json["type"] as? String {
        case "ready":
            streaming = true
            if let engine = json["engine"] as? String { self.engine = engine }
            connectedAt = Date()
            state = "listening"
            if usesCallKit, let uuid { provider?.reportOutgoingCall(with: uuid, connectedAt: Date()) }
            if muted { sendJSON(["type": "mute", "on": true]) }
        case "state":
            if let value = json["state"] as? String { state = value }
        case "transcript":
            guard let role = json["role"] as? String, let text = json["text"] as? String else { return }
            transcript(role: role, text: text, final: json["final"] as? Bool ?? true)
        case "note":
            if let text = json["text"] as? String { show(note: text) }
        case "engine":
            if let engine = json["engine"] as? String { self.engine = engine }
        case "error":
            let message = json["message"] as? String ?? "Something went wrong"
            if streaming { show(note: message) } else { finish(reason: message, failed: true) }
        case "ended":
            finish(reason: json["reason"] as? String, failed: false)
        default:
            break
        }
    }

    /// A partial replaces the last partial of the same role; a final settles it.
    private func transcript(role: String, text: String, final: Bool) {
        if let index = lines.lastIndex(where: { $0.role == role && !$0.final }) {
            lines[index].text = text
            lines[index].final = final
        } else {
            nextLineId += 1
            lines.append(Line(id: nextLineId, role: role, text: text, final: final))
        }
    }

    private func show(note text: String) {
        note = text
        noteClear?.cancel()
        let clear = DispatchWorkItem { [weak self] in self?.note = nil }
        noteClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: clear)
    }

    private func applyMute(_ on: Bool) {
        muted = on
        audio.muted = on
        if streaming { sendJSON(["type": "mute", "on": on]) }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func hangUpLocally() {
        guard active else { return }
        if let socket, streaming {
            let data = try? JSONSerialization.data(withJSONObject: ["type": "end"])
            socket.send(.string(String(data: data ?? Data(), encoding: .utf8) ?? "")) { _ in
                socket.cancel(with: .normalClosure, reason: nil)
            }
            self.socket = nil
        } else if let callId {
            Task { try? await PaiClient().endCall(callId) }
        }
        finish(reason: "hung up", failed: false, local: true)
    }

    /// The call is over, from either side: socket, audio and CallKit wound down, the screen gone a moment later.
    private func finish(reason: String?, failed: Bool, local: Bool = false) {
        guard active else { return }
        active = false
        streaming = false
        state = "ended"
        endReason = reason
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        audio.stop()
        if usesCallKit, let uuid, !local {
            provider?.reportCall(with: uuid, endedAt: Date(), reason: failed ? .failed : .remoteEnded)
        }
        if !usesCallKit {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        uuid = nil
        NotificationCenter.default.post(name: Self.ended, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + (failed ? 3.0 : 1.2)) { [weak self] in
            guard let self, !self.active else { return }
            PaiCallWindow.hide()
        }
    }
}

@available(iOS 16.0, *)
extension PaiCall: CXProviderDelegate {
    public func providerDidReset(_ provider: CXProvider) {
        finish(reason: "reset", failed: false, local: true)
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        do {
            try PaiCallAudio.configureSession()
        } catch {
            action.fail()
            return
        }
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
        connect()
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        if active { startAudio() }
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        audio.stop()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        hangUpLocally()
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        applyMute(action.isMuted)
        action.fulfill()
    }
}
