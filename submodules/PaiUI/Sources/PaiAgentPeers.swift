import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore

/// The app's half of the agent chats (TelegramCore holds the rest): the agents pai lists become peers under the pai
/// row, and pai's event stream, which only the app follows, keeps their chats live.
public enum PaiAgentPeers {
    private static var engine: TelegramEngine?
    private static let updateDisposable = MetaDisposable()
    private static var observers: [NSObjectProtocol] = []

    /// The account whose chat list shows the agents.
    public static func attach(engine: TelegramEngine?) {
        self.engine = engine
        if self.observers.isEmpty {
            self.observers = [
                NotificationCenter.default.addObserver(forName: PaiChat.agentsChanged, object: nil, queue: .main, using: { _ in
                    self.push()
                }),
                NotificationCenter.default.addObserver(forName: PaiAuth.didChange, object: nil, queue: .main, using: { _ in
                    self.follow()
                }),
                NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: { _ in
                    self.engine?.paiAgents.syncNow()
                }),
            ]
        }
        self.push()
        self.follow()
    }

    /// pai's event stream, which also refreshes the agents themselves.
    private static func follow() {
        guard PaiAuth.isSignedIn, self.engine != nil else {
            return
        }
        // Every caller runs on the main queue.
        if #available(iOS 16.0, *) {
            MainActor.assumeIsolated {
                PaiHost.store.start()
            }
        }
    }

    private static func push() {
        guard let engine = self.engine else {
            return
        }
        let base = PaiSecrets.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let agents = PaiChat.agents.map { agent -> PaiAgentInfo in
            let avatar = agent.avatar.map { $0.hasPrefix("http") ? $0 : base + ($0.hasPrefix("/") ? "" : "/") + $0 }
            return PaiAgentInfo(slug: agent.slug, name: agent.name, role: agent.role, avatar: avatar, parent: agent.parent, threadId: agent.threadId, closed: agent.isClosed || agent.status == "done")
        }
        guard !agents.isEmpty else {
            return
        }
        self.updateDisposable.set(engine.paiAgents.update(agents: agents).start())
    }
}
