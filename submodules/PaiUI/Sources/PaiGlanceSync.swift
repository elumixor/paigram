import Foundation
import UIKit
import UserNotifications
import WatchConnectivity
import WidgetKit
import PaiGlance

/// Keeps the glance fresh for the other surfaces while the app runs: the app group's snapshot (which the
/// home-screen widget shows), the usage alerts, and the watch, which gets the box's address and token plus the
/// latest glance through WatchConnectivity and answers questions through the phone when the box is out of reach.
public final class PaiGlanceSync: NSObject, WCSessionDelegate {
    public static let shared = PaiGlanceSync()

    private var started = false
    private var lastFetch: Date?
    private var fetching = false
    private var observers: [NSObjectProtocol] = []

    private var store: PaiGlanceStore? { PaiGlanceStore.appGroup() }

    private var config: PaiGlanceConfig? {
        PaiAuth.token.map { PaiGlanceConfig(baseURL: PaiSecrets.baseURL, token: $0) }
    }

    /// Starts once (at launch); after that, a sign-in or out only refreshes.
    public func start() {
        DispatchQueue.main.async {
            if !self.started {
                self.started = true
                if WCSession.isSupported() {
                    WCSession.default.delegate = self
                    WCSession.default.activate()
                }
                let center = NotificationCenter.default
                self.observers = [UIApplication.didBecomeActiveNotification, PaiChat.needsChanged, PaiChat.usageChanged].map { name in
                    center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
                }
            }
            self.refresh(force: true)
        }
    }

    /// Fetches a glance (at most once a minute unless forced) and hands it to the widget, the alerts and the watch.
    public func refresh(force: Bool = false) {
        guard let config else {
            sendToWatch(glance: nil)
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        if fetching || (!force && (lastFetch.map { Date().timeIntervalSince($0) < 60 } ?? false)) {
            return
        }
        fetching = true
        lastFetch = Date()
        PaiGlanceLiveSource(config: config).glance { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false
                guard case let .success(glance) = result else { return }
                let previous = self.store?.glance
                self.store?.saveGlance(glance)
                PaiPerf.first("glance.saved")
                if let store = self.store {
                    PaiUsageAlerts.post(store.crossings(in: glance))
                }
                if previous.map({ !Self.sameContent($0, glance) }) ?? true {
                    WidgetCenter.shared.reloadAllTimelines()
                }
                self.sendToWatch(glance: glance)
            }
        }
    }

    /// Two glances that look the same on the widget: the fetch time aside.
    private static func sameContent(_ lhs: PaiGlance, _ rhs: PaiGlance) -> Bool {
        lhs.windows.map { Int($0.percent) } == rhs.windows.map { Int($0.percent) } && Int(lhs.todayUsd) == Int(rhs.todayUsd)
            && lhs.running == rhs.running && lhs.needs == rhs.needs && lhs.agents.map(\.slug) == rhs.agents.map(\.slug)
    }

    // MARK: - Watch

    private func sendToWatch(glance: PaiGlance?) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        var context: [String: Any] = [:]
        if let config, let data = try? JSONEncoder().encode(config) {
            context["config"] = data
        }
        if let glance, let data = PaiGlanceStore.encode(glance) {
            context["glance"] = data
        }
        try? session.updateApplicationContext(context)
    }

    public func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.sendToWatch(glance: self.store?.glance)
        }
    }

    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    public func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.sendToWatch(glance: self.store?.glance)
        }
    }

    /// The watch asks for a fresh glance (`refresh`) or relays an answer (`answer` + `text`) it could not send itself.
    public func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let config else {
            replyHandler(["error": "signed out"])
            return
        }
        let source = PaiGlanceLiveSource(config: config)
        if let id = message["answer"] as? String, let text = message["text"] as? String {
            source.answer(need: id, text: text) { result in
                if case .success = result {
                    DispatchQueue.main.async { self.refresh(force: true) }
                }
                replyHandler(["ok": (try? result.get()) != nil])
            }
            return
        }
        source.glance { result in
            var reply: [String: Any] = [:]
            if case let .success(glance) = result, let data = PaiGlanceStore.encode(glance) {
                reply["glance"] = data
            }
            if let data = try? JSONEncoder().encode(config) {
                reply["config"] = data
            }
            replyHandler(reply)
        }
    }
}
