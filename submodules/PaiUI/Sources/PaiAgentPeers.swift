import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore

/// The app's half of the agents' identities (TelegramCore holds the rest): the agents pai lists become peers with
/// their portraits, for their profiles, and TelegramCore learns which topic of the pai bot's chat is whose, to load
/// each topic's history from before it (`PaiTopicHistory.swift`). pai's event stream, which only the app follows,
/// keeps the agent list fresh.
public enum PaiAgentPeers {
    private static var engine: TelegramEngine?
    private static let updateDisposable = MetaDisposable()
    private static let botDisposable = MetaDisposable()
    private static var observers: [NSObjectProtocol] = []
    private static var loadingAvatars = Set<String>()

    /// The account whose agents these are.
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
            ]
        }
        self.resolveBot()
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

    /// The pai bot's peer, so its topics get their history before the chat is first opened.
    private static func resolveBot() {
        guard PaiChat.botPeerId == nil, let engine = self.engine else {
            return
        }
        self.botDisposable.set((engine.peers.resolvePeerByName(name: PaiSecrets.botUsername, referrer: nil)
        |> deliverOnMainQueue).start(next: { result in
            guard case let .result(peer) = result, let peer else {
                return
            }
            if PaiChat.botPeerId == nil {
                PaiChat.botPeerId = peer.id
            }
            self.push()
        }))
    }

    private static func push() {
        guard let engine = self.engine else {
            return
        }
        let base = PaiSecrets.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let agents = PaiChat.agents.map { agent -> PaiAgentInfo in
            // The peer gets its photo once the portrait is stored; until then it shows its initials.
            let avatar = PaiAvatars.address(agent.avatar).flatMap { url -> String? in
                if engine.resources.completedResourcePath(id: EngineMediaResource(paiAgentAvatarResource(url: url)).id) != nil {
                    return url
                }
                self.loadAvatar(engine: engine, url: url)
                return nil
            }
            return PaiAgentInfo(slug: agent.slug, name: agent.name, role: agent.role, avatar: avatar, parent: agent.parent, threadId: agent.threadId, closed: agent.isClosed || agent.status == "done")
        }
        guard !agents.isEmpty else {
            return
        }
        self.updateDisposable.set(engine.paiAgents.update(agents: agents, botPeerId: PaiChat.botPeerId).start())
    }

    /// An agent's portrait as stored for its peer (256 pixels square), for lists that draw it: nil until downloaded.
    public static func storedPortrait(url: String) -> UIImage? {
        guard let engine = self.engine, let path = engine.resources.completedResourcePath(id: EngineMediaResource(paiAgentAvatarResource(url: url)).id) else {
            return nil
        }
        return UIImage(contentsOfFile: path)
    }

    /// Downloads a portrait, scales it to the 256-pixel square the peer photo declares and stores it where the agent
    /// peer looks (`paiAgentAvatarResource`), then hands the agents over again.
    private static func loadAvatar(engine: TelegramEngine, url: String) {
        guard !self.loadingAvatars.contains(url), let address = URL(string: url) else {
            return
        }
        self.loadingAvatars.insert(url)
        URLSession.shared.dataTask(with: address, completionHandler: { data, _, _ in
            let scaled = data.flatMap { UIImage(data: $0) }.flatMap { image -> Data? in
                let side: CGFloat = 256
                let scale = max(side / max(image.size.width, 1), side / max(image.size.height, 1))
                let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
                    image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
                }.jpegData(compressionQuality: 0.85)
            }
            if let scaled {
                engine.resources.storeResourceData(id: EngineMediaResource(paiAgentAvatarResource(url: url)).id, data: scaled, synchronous: true)
            }
            DispatchQueue.main.async {
                self.loadingAvatars.remove(url)
                if scaled != nil {
                    self.push()
                }
            }
        }).resume()
    }
}
