import Foundation
import Observation
import WatchConnectivity
import WatchKit
import WidgetKit

/// Pai on the wrist: the usage glance, the questions waiting on the user and the agents with their plans. The phone hands over the box's
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
    /// The dashboard's navigation: an agent or an ask a complication opened.
    var path: [PaiRoute] = []
    /// Telegram's chats (and its sign-in), over the dashboard.
    var telegramPresented = false

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
        guard let target = PaiGlanceLink.parse(url) else { return }
        telegramPresented = false
        switch target {
        case let .agent(slug): path = [.agent(slug)]
        case .usage: path = []
        }
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

    /// Sends a draft need as the user, with his edits (`body`) applied first. `done` gets nil once sent, else why not.
    func sendDraft(_ need: PaiGlance.Need, fields: [String: String], done: @escaping (String?) -> Void) {
        guard let draft = need.draft else { return }
        answering.insert(need.id)
        let finish = { (error: String?) in
            DispatchQueue.main.async {
                self.answering.remove(need.id)
                if error == nil, let glance = self.glance {
                    self.apply(glance: glance.removing(need: need.id))
                    self.refresh()
                }
                done(error)
            }
        }
        guard let config = PaiVault.config else {
            relayDraft(draft.id, fields: fields, finish: finish)
            return
        }
        PaiGlanceLiveSource(config: config).sendDraft(id: draft.id, fields: fields) { result in
            switch result {
            case .success: finish(nil)
            // The box was reached and said no: the phone would hear the same.
            case let .failure(PaiGlanceError.refused(reason)): finish(reason)
            case .failure: self.relayDraft(draft.id, fields: fields, finish: finish)
            }
        }
    }

    /// The whole draft from the box, for one whose glance body was cut; nil when the box cannot be reached directly.
    func loadDraft(_ id: Int, completion: @escaping (PaiGlance.Need.Draft?) -> Void) {
        guard let config = PaiVault.config else {
            completion(nil)
            return
        }
        PaiGlanceLiveSource(config: config).draft(id: id) { result in
            DispatchQueue.main.async { completion(try? result.get()) }
        }
    }

    // MARK: - Change cards

    /// The change card behind a `change:<hash>` need, read from the box.
    func change(_ hash: String, completion: @escaping (Result<PaiGlance.Change, Error>) -> Void) {
        guard let config = PaiVault.config else {
            completion(.failure(PaiGlanceError.notSignedIn))
            return
        }
        PaiGlanceLiveSource(config: config).change(hash: hash) { result in
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Approves change `hash` with this watch's Secure Enclave key (`PaiWatchKey`), or denies it. `done` gets nil once
    /// the box took it, else what to tell the user.
    func decideChange(_ need: PaiGlance.Need, hash: String, approve: Bool, done: @escaping (String?) -> Void) {
        guard let config = PaiVault.config else {
            done("Open Paigram on your iPhone and sign in to pai.")
            return
        }
        answering.insert(need.id)
        let finish = { (error: String?) in
            DispatchQueue.main.async {
                self.answering.remove(need.id)
                if error == nil, let glance = self.glance {
                    self.apply(glance: glance.removing(need: need.id))
                    self.refresh()
                }
                done(error)
            }
        }
        let source = PaiGlanceLiveSource(config: config)
        guard approve else {
            source.denyChange(hash: hash) { finish(Self.say($0.error)) }
            return
        }
        source.watchChallenge(hash: hash) { result in
            switch result {
            case let .failure(error): finish(Self.say(error))
            case let .success((challenge, keys)):
                do {
                    let key = try PaiWatchKey.publicKey()
                    let id = PaiWatchKey.id(of: key)
                    guard keys.contains(id) else {
                        finish(PaiWatchKey.addHint)
                        return
                    }
                    let signature = try PaiWatchKey.sign(hash: hash, challenge: challenge)
                    source.watchApprove(hash: hash, key: id, challenge: challenge, signature: signature) { finish(Self.say($0.error)) }
                } catch {
                    finish(error.localizedDescription)
                }
            }
        }
    }

    private static func say(_ error: Error?) -> String? {
        guard let error else { return nil }
        if case let PaiGlanceError.refused(reason) = error {
            return reason.hasPrefix("no Apple Watch key") ? PaiWatchKey.addHint : reason
        }
        return "Can't reach pai"
    }

    /// Hands the watch key to the phone once per key, so Add Apple Watch there works while this app is closed.
    private func offerKey(_ session: WCSession) {
        guard session.activationState == .activated, let key = try? PaiWatchKey.publicKey() else { return }
        let id = PaiWatchKey.id(of: key)
        guard UserDefaults.standard.string(forKey: "pai.watchkey.offered") != id else { return }
        session.transferUserInfo(["watchKey": key, "watchName": WKInterfaceDevice.current().name])
        UserDefaults.standard.set(id, forKey: "pai.watchkey.offered")
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

    private func relayDraft(_ id: Int, fields: [String: String], finish: @escaping (String?) -> Void) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isReachable else {
            finish("Can't reach pai")
            return
        }
        session.sendMessage(["sendDraft": id, "fields": fields], replyHandler: { reply in
            finish(reply["ok"] as? Bool == true ? nil : reply["error"] as? String ?? "Not sent")
        }, errorHandler: { _ in finish("Can't reach pai") })
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
            self.offerKey(session)
        }
    }

    /// The phone's Add Apple Watch asks for this watch's public key (`["watchKey": true]`).
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["watchKey"] as? Bool == true else {
            replyHandler([:])
            return
        }
        DispatchQueue.main.async {
            do {
                replyHandler(["publicKey": try PaiWatchKey.publicKey(), "name": WKInterfaceDevice.current().name])
            } catch {
                replyHandler(["error": error.localizedDescription])
            }
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
        return with(needs: left, needsCount: max(0, needsCount - (needs.count - left.count)))
    }
}

private extension Result {
    /// The error of a failed result, nil for a success.
    var error: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
