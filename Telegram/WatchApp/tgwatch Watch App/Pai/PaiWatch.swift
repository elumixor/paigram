import Foundation
import Observation
import WatchConnectivity
import WidgetKit

/// Pai on the wrist: the usage glance and the questions waiting on the user. The phone hands over the box's
/// address and token (and its latest glance) through WatchConnectivity; after that the watch asks the box
/// itself, and goes through the phone only when the box cannot be reached.
@Observable
final class PaiWatch: NSObject, WCSessionDelegate {
    static let shared = PaiWatch()

    private(set) var glance: PaiGlance? = PaiVault.glance
    private(set) var signedIn = PaiVault.config != nil
    private(set) var loading = false
    private(set) var failure: String?
    /// Needs whose answer is on its way.
    private(set) var answering: Set<String> = []
    /// The glance sheet, opened from the chat list or a complication.
    var presented = false

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// The `paigram://` links complications open.
    func open(_ url: URL) {
        guard url.scheme == PaiGlanceLink.scheme else { return }
        presented = true
        refresh()
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        guard let config = PaiVault.config else {
            askPhone()
            return
        }
        PaiGlanceLiveSource(config: config).glance { result in
            DispatchQueue.main.async {
                switch result {
                case let .success(glance):
                    self.loading = false
                    self.failure = nil
                    self.apply(glance: glance)
                case .failure:
                    self.askPhone()
                }
            }
        }
    }

    func answer(_ need: PaiGlance.Need, text: String, done: @escaping (Bool) -> Void) {
        answering.insert(need.id)
        let finish = { (ok: Bool) in
            DispatchQueue.main.async {
                self.answering.remove(need.id)
                if ok, let glance = self.glance {
                    self.apply(glance: glance.removing(need: need.id))
                    self.refresh()
                }
                done(ok)
            }
        }
        guard let config = PaiVault.config else {
            relayAnswer(need, text: text, finish: finish)
            return
        }
        PaiGlanceLiveSource(config: config).answer(need: need.id, text: text) { result in
            if case .success = result {
                finish(true)
            } else {
                self.relayAnswer(need, text: text, finish: finish)
            }
        }
    }

    // MARK: - Through the phone

    private func askPhone() {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isReachable else {
            DispatchQueue.main.async {
                self.loading = false
                self.failure = self.signedIn ? "Can't reach pai" : "Open Paigram on your iPhone"
            }
            return
        }
        session.sendMessage(["refresh": true], replyHandler: { reply in
            DispatchQueue.main.async {
                self.loading = false
                self.receive(reply)
                self.failure = reply["glance"] == nil ? (reply["error"] as? String ?? "Can't reach pai") : nil
            }
        }, errorHandler: { _ in
            DispatchQueue.main.async {
                self.loading = false
                self.failure = "Can't reach pai"
            }
        })
    }

    private func relayAnswer(_ need: PaiGlance.Need, text: String, finish: @escaping (Bool) -> Void) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isReachable else {
            finish(false)
            return
        }
        session.sendMessage(["answer": need.id, "text": text], replyHandler: { reply in
            finish(reply["ok"] as? Bool ?? false)
        }, errorHandler: { _ in finish(false) })
    }

    /// The phone's application context or its reply: the box config (or its absence: signed out) and a glance.
    private func receive(_ payload: [String: Any]) {
        if let data = payload["config"] as? Data, let config = try? JSONDecoder().decode(PaiGlanceConfig.self, from: data) {
            if PaiVault.config != config { PaiVault.config = config }
            signedIn = true
        } else if payload["error"] as? String == "signed out" || (payload["config"] == nil && payload["glance"] == nil) {
            PaiVault.config = nil
            PaiVault.glance = nil
            signedIn = false
            glance = nil
            WidgetCenter.shared.reloadAllTimelines()
        }
        if let data = payload["glance"] as? Data, let glance = PaiGlanceStore.decode(data) {
            apply(glance: glance)
        }
    }

    private func apply(glance: PaiGlance) {
        if let current = self.glance, current.at > glance.at { return }
        let glance = glance.keepingWindows(of: self.glance ?? PaiVault.glance)
        self.glance = glance
        PaiVault.glance = glance
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        DispatchQueue.main.async {
            if !context.isEmpty { self.receive(context) }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { self.receive(applicationContext) }
    }
}

extension PaiGlance {
    /// The glance with one need answered.
    func removing(need id: String) -> PaiGlance {
        let left = needs.filter { $0.id != id }
        return PaiGlance(at: at, todayUsd: todayUsd, usdPerHour: usdPerHour, windows: windows, agents: agents, running: running, needsCount: max(0, needsCount - (needs.count - left.count)), needs: left)
    }
}
