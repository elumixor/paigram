import AccountContext
import Display
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

/// Opening the agents' chats.
public enum PaiAgentList {
    /// The agent whose peer this is.
    public static func slug(peerId: EnginePeer.Id) -> String? {
        guard peerId.isPaiAgent else {
            return nil
        }
        return PaiChat.agents.first(where: { paiAgentPeerId(slug: $0.slug) == peerId })?.slug
    }

    /// Under an agent chat's title: its role, and what it is doing when it is not idle.
    public static func subtitle(peerId: EnginePeer.Id) -> String? {
        guard let slug = slug(peerId: peerId), let agent = PaiChat.agent(slug) else {
            return nil
        }
        let state: String?
        if agent.status == "waiting" || PaiChat.needs.contains(where: { $0.agent == slug }) {
            state = "waiting on you"
        } else if agent.isBusy {
            state = "working"
        } else {
            state = nil
        }
        let role = agent.role.flatMap { $0.isEmpty ? nil : $0 } ?? "agent"
        return [role, state].compactMap { $0 }.joined(separator: " · ")
    }

    /// The agent whose peer this is, when its chat is the bot's: pai's own (the bot chat) or one with a topic.
    public static func botChatSlug(peerId: EnginePeer.Id) -> String? {
        guard let slug = slug(peerId: peerId) else {
            return nil
        }
        return slug == PaiChat.paiSlug || PaiChat.thread(of: slug) != nil ? slug : nil
    }

    /// Into an agent's chat: pai's is the bot chat, an agent with a topic is that topic, any other agent's is its own chat.
    public static func open(slug: String, context: AccountContext, navigationController: NavigationController) {
        let threadId = slug == PaiChat.paiSlug ? nil : PaiChat.thread(of: slug)
        if slug == PaiChat.paiSlug || threadId != nil {
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
            return
        }
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: paiAgentPeerId(slug: slug)))
        |> deliverOnMainQueue).startStandalone(next: { [weak navigationController] peer in
            guard let navigationController, let peer else {
                return
            }
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
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
}

/// Agent portraits, fetched once per run; the URLs are public.
public enum PaiAvatars {
    private static let cache = NSCache<NSString, UIImage>()

    public static func cached(_ url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
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
