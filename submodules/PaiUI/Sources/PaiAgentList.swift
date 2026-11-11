import AccountContext
import Display
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

/// An agent as a row of the chat list: who it is, what it is for, and whether it runs, rests or waits on the user.
public struct PaiAgentRow: Equatable {
    public enum State: Equatable {
        case running
        case idle
        /// Waiting on the user's decision.
        case blocked
        /// Stopped by the user.
        case paused
    }

    public let slug: String
    public let name: String
    public let role: String?
    public let avatar: String?
    public let job: String
    public let state: State
    /// How many decisions it waits on.
    public let needs: Int

    public var statusText: String {
        switch state {
        case .running: return "Working"
        case .blocked: return needs > 1 ? "\(needs) questions" : "Waiting on you"
        case .paused: return "Stopped"
        case .idle: return "Idle"
        }
    }
}

/// The agents shown in the chat list, kept fresh by the daemon's event stream.
public enum PaiAgentList {
    /// The live agents in tree order; finished, closed and trashed ones are left out.
    public static func rows() -> [PaiAgentRow] {
        let needs = PaiChat.needs
        return PaiChat.agents.compactMap { agent in
            switch agent.status {
            case "done", "closed": return nil
            default: break
            }
            let open = needs.filter { $0.agent == agent.slug }.count
            let state: PaiAgentRow.State
            if open > 0 || agent.status == "waiting" {
                state = .blocked
            } else if agent.status == "paused" {
                state = .paused
            } else if agent.isBusy {
                state = .running
            } else {
                state = .idle
            }
            return PaiAgentRow(slug: agent.slug, name: agent.name, role: agent.role, avatar: agent.avatar, job: agent.job, state: state, needs: open)
        }
    }

    /// The rows now and whenever an agent or a decision changes. Subscribing starts following the daemon.
    public static func signal() -> Signal<[PaiAgentRow], NoError> {
        return Signal { subscriber in
            subscriber.putNext(rows())
            let center = NotificationCenter.default
            let observers = [PaiChat.agentsChanged, PaiChat.needsChanged].map { name in
                center.addObserver(forName: name, object: nil, queue: nil) { _ in
                    subscriber.putNext(rows())
                }
            }
            if #available(iOS 16.0, *), PaiAuth.isSignedIn {
                Task { @MainActor in
                    PaiHost.store.start()
                }
            }
            return ActionDisposable {
                observers.forEach(center.removeObserver)
            }
        }
        |> distinctUntilChanged
    }

    /// Into an agent's chat: pai's is the bot chat, an agent with a topic is that topic, a sub-agent's is a screen of the app.
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
        guard #available(iOS 16.0, *) else {
            return
        }
        let chat = PaiAgentChatController(context: context, slug: slug)
        chat.openAgent = { [weak navigationController] next in
            guard let navigationController else {
                return
            }
            open(slug: next, context: context, navigationController: navigationController)
        }
        navigationController.pushViewController(chat)
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
