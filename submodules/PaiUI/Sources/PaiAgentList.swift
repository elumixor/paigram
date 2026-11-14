import AccountContext
import Display
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

/// pai's agents in Telegram's screens: an agent's peer is its profile, its chat is its topic of the bot's chat.
public enum PaiAgentList {
    /// The agent whose peer this is.
    public static func slug(peerId: EnginePeer.Id) -> String? {
        guard peerId.isPaiAgent else {
            return nil
        }
        return PaiChat.agents.first(where: { paiAgentPeerId(slug: $0.slug) == peerId })?.slug
    }

    /// The peer an agent's profile is.
    public static func peerId(slug: String) -> EnginePeer.Id {
        return paiAgentPeerId(slug: slug)
    }

    /// Under an agent's name: its role, and what it is doing when it is not idle.
    public static func subtitle(peerId: EnginePeer.Id) -> String? {
        guard let slug = slug(peerId: peerId), let agent = PaiChat.agent(slug) else {
            return nil
        }
        let role = agent.role.flatMap { $0.isEmpty ? nil : $0 } ?? (agent.isPai ? "assistant" : "agent")
        return [role, state(agent)].compactMap { $0 }.joined(separator: " · ")
    }

    /// What an agent is doing, in a word; nil when idle.
    public static func state(_ agent: PaiAgent) -> String? {
        if agent.status == "waiting" || PaiChat.needs.contains(where: { $0.agent == agent.slug }) {
            return "waiting on you"
        } else if agent.isBusy {
            return "working"
        } else if agent.isClosed || agent.status == "done" {
            return "closed"
        }
        return nil
    }

    /// Into an agent's chat: its topic of the bot's chat (pai's is the main topic, as is any agent without a topic yet).
    public static func open(slug: String, context: AccountContext, navigationController: NavigationController) {
        let threadId = PaiChat.thread(of: slug) ?? PaiChat.mainThreadId
        let _ = (botPeer(context: context) |> deliverOnMainQueue).startStandalone(next: { [weak navigationController] peer in
            guard let navigationController, let peer else {
                return
            }
            let location: NavigateToChatControllerParams.Location
            if let threadId {
                location = .replyThread(ChatReplyThreadMessage(peerId: peer.id, threadId: threadId, channelMessageId: nil, isChannelPost: false, isForumPost: true, isMonoforumPost: false, maxMessage: nil, maxReadIncomingMessageId: nil, maxReadOutgoingMessageId: nil, unreadCount: 0, initialFilledHoles: IndexSet(), initialAnchor: .automatic, isNotAvailable: false))
            } else {
                location = .peer(peer)
            }
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: location))
        })
    }

    private static func botPeer(context: AccountContext) -> Signal<EnginePeer?, NoError> {
        if let botPeerId = PaiChat.botPeerId {
            return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: botPeerId))
        }
        return context.engine.peers.resolvePeerByName(name: PaiSecrets.botUsername, referrer: nil)
        |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
            guard case let .result(peer) = result else {
                return .complete()
            }
            return .single(peer)
        }
        |> take(1)
    }

    /// A topic's icon in the bot chat's topic list: its agent's portrait. Nil for a topic that is no agent's.
    public static func topicIcon(thread: Int64, size: CGFloat) -> UIImage? {
        return PaiChat.agent(thread: thread).map { portrait(agent: $0, size: size) }
    }

    /// An agent's portrait in a circle as it is stored for its peer, its initials until then.
    public static func portrait(agent: PaiAgent, size: CGFloat) -> UIImage {
        let key = "\(agent.slug):\(agent.avatar ?? ""):\(Int(size))" as NSString
        if let cached = portraits.object(forKey: key) {
            return cached
        }
        guard let stored = PaiAvatars.address(agent.avatar).flatMap({ PaiAvatars.cached($0) ?? PaiAgentPeers.storedPortrait(url: $0) }) else {
            return PaiAvatars.placeholder(name: agent.name, slug: agent.slug, size: size)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).addClip()
            let scale = max(size / max(stored.size.width, 1), size / max(stored.size.height, 1))
            let drawn = CGSize(width: stored.size.width * scale, height: stored.size.height * scale)
            stored.draw(in: CGRect(x: (size - drawn.width) / 2, y: (size - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
        portraits.setObject(image, forKey: key)
        return image
    }

    private static let portraits = NSCache<NSString, UIImage>()
}

/// Agent portraits, fetched once per run; the URLs are public.
public enum PaiAvatars {
    private static let cache = NSCache<NSString, UIImage>()

    public static func cached(_ url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
    }

    /// An agent's `avatar` (absolute, or a path on the box) as an address.
    public static func address(_ avatar: String?) -> String? {
        guard let avatar, !avatar.isEmpty else {
            return nil
        }
        if avatar.hasPrefix("http") {
            return avatar
        }
        let base = PaiSecrets.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return base + (avatar.hasPrefix("/") ? "" : "/") + avatar
    }

    public static func image(_ url: String) -> Signal<UIImage?, NoError> {
        if let image = cached(url) {
            return .single(image)
        }
        return Signal { subscriber in
            guard let resolved = URL(string: url) else {
                subscriber.putNext(nil)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let task = URLSession.shared.dataTask(with: resolved) { data, _, _ in
                let image = data.flatMap { UIImage(data: $0) }
                if let image {
                    cache.setObject(image, forKey: url as NSString)
                }
                subscriber.putNext(image)
                subscriber.putCompletion()
            }
            task.resume()
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    /// Two letters of the name on a colour picked from the slug, for an agent with no portrait.
    public static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(name.prefix(2))
        return String(letters).uppercased()
    }

    /// The initials on their colour as a round image, for screens drawing a face before its portrait arrives.
    public static func placeholder(name: String, slug: String, size: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
            UIColor(hue: hue(slug), saturation: 0.45, brightness: 0.72, alpha: 1.0).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).fill()
            let text = NSAttributedString(string: initials(name), attributes: [.font: UIFont.systemFont(ofSize: size * 0.38, weight: .semibold), .foregroundColor: UIColor.white])
            let textSize = text.size()
            text.draw(at: CGPoint(x: (size - textSize.width) / 2.0, y: (size - textSize.height) / 2.0))
        }
    }

    public static func hue(_ slug: String) -> CGFloat {
        var hash: UInt32 = 0
        for scalar in slug.unicodeScalars {
            hash = hash &* 31 &+ scalar.value
        }
        return CGFloat(hash % 360) / 360.0
    }
}
