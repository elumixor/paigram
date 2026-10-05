import Foundation
import UIKit
import Display
import AsyncDisplayKit
import ComponentFlow
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ChatPresentationInterfaceState
import AlertUI
import PresentationDataUtils
import OverlayStatusController
import PaiUI
import ChatTitleView

/// A topic of the pai bot's chat as a chat location; the same shape `updateChatLocationThread` builds.
private func paiThread(peerId: PeerId, threadId: Int64) -> ChatReplyThreadMessage {
    return ChatReplyThreadMessage(peerId: peerId, threadId: threadId, channelMessageId: nil, isChannelPost: false, isForumPost: true, isMonoforumPost: false, maxMessage: nil, maxReadIncomingMessageId: nil, maxReadOutgoingMessageId: nil, unreadCount: 0, initialFilledHoles: IndexSet(), initialAnchor: .automatic, isNotAvailable: false)
}

extension ChatControllerImpl {
    /// Into an agent's chat, keeping the navigation stack the shape of the tree: going down pushes (so the back
    /// swipe goes up a level), going up pops to the level when it is on the stack and switches this chat otherwise.
    /// An agent with a topic is that topic of the bot chat; a sub-agent's chat is a screen of the app.
    func openPaiAgent(slug: String?, thread: Int64?) {
        guard #available(iOS 16.0, *), let navigationController = self.effectiveNavigationController, let peerId = self.chatLocation.peerId else {
            return
        }
        let target = PaiChat.agent(slug) ?? PaiChat.agent(thread: thread)
        let targetSlug = target?.slug ?? slug
        let threadId = thread ?? targetSlug.flatMap { PaiChat.thread(of: $0) }
        let stack = navigationController.viewControllers
        let selfIndex = stack.firstIndex(where: { $0 === self }) ?? stack.count - 1

        if let threadId {
            if let existing = stack.last(where: { ($0 as? ChatControllerImpl)?.chatLocation.peerId == peerId && ($0 as? ChatControllerImpl)?.chatLocation.threadId == threadId }) {
                let _ = navigationController.popToViewController(existing, animated: true)
                return
            }
            let current = PaiChat.agent(thread: self.chatLocation.threadId)
            let goesDown = current.flatMap { current in targetSlug.map { PaiChat.isAncestor(current.slug, of: $0) } } ?? false
            if goesDown {
                let controller = ChatControllerImpl(context: self.context, chatLocation: .replyThread(message: paiThread(peerId: peerId, threadId: threadId)))
                navigationController.setViewControllers(Array(stack.prefix(selfIndex + 1)) + [controller], animated: true)
            } else {
                let _ = navigationController.popToViewController(self, animated: true)
                self.updateChatLocationThread(threadId: threadId, animationDirection: nil)
            }
            return
        }

        guard let targetSlug else {
            return
        }
        if let existing = stack.last(where: { ($0 as? PaiAgentChatController)?.slug == targetSlug }) {
            let _ = navigationController.popToViewController(existing, animated: true)
            return
        }
        // A sub-agent's chat goes right above its parent's, whichever screen that is.
        let parentIndex = target?.parent.flatMap { parent in stack.lastIndex(where: { ($0 as? PaiAgentChatController)?.slug == parent }) }
        let chat = PaiAgentChatController(context: self.context, slug: targetSlug)
        chat.openAgent = { [weak self] slug in
            self?.openPaiAgent(slug: slug, thread: nil)
        }
        navigationController.setViewControllers(Array(stack.prefix((parentIndex ?? selfIndex) + 1)) + [chat], animated: true)
    }

    /// A thread named only by its short id (a reply's "started […]" link): always pushed as a fresh chat,
    /// never a switch — unlike an agent's topic, a plain thread has no place of its own in the nav stack yet.
    func openPaiThread(shortId: String) {
        guard #available(iOS 16.0, *), let navigationController = self.effectiveNavigationController, let peerId = self.chatLocation.peerId else {
            return
        }
        let stack = navigationController.viewControllers
        let selfIndex = stack.firstIndex(where: { $0 === self }) ?? stack.count - 1

        let statusController = OverlayStatusController(theme: self.presentationData.theme, type: .loading(cancelled: nil))
        self.present(statusController, in: .window(.root))

        let client = PaiClient()
        Task { @MainActor [weak self, weak navigationController, weak statusController] in
            defer { statusController?.dismiss() }
            for attempt in 0..<20 {
                guard let tasks = try? await client.tasks() else { continue }
                if let session = (tasks.live + tasks.recent).first(where: { $0.shortId == shortId }) {
                    if let threadId = session.threadId {
                        guard let self, let navigationController else { return }
                        if let existing = stack.last(where: { ($0 as? ChatControllerImpl)?.chatLocation.peerId == peerId && ($0 as? ChatControllerImpl)?.chatLocation.threadId == threadId }) {
                            let _ = navigationController.popToViewController(existing, animated: true)
                            return
                        }
                        let controller = ChatControllerImpl(context: self.context, chatLocation: .replyThread(message: paiThread(peerId: peerId, threadId: threadId)))
                        navigationController.setViewControllers(Array(stack.prefix(selfIndex + 1)) + [controller], animated: true)
                        return
                    }
                    // Found but not yet given a topic: keep waiting, same as starting one from the New Thread card.
                } else if attempt > 2 {
                    // Not in the live/recent list at all — no point in the full 20 attempts.
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard let self else { return }
            self.present(textAlertController(context: self.context, title: nil, text: "Couldn't open that thread.", actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]), in: .window(.root))
        }
    }

    /// pai's settings: status, usage, what its sessions are given.
    func openPaiSettings() {
        guard #available(iOS 16.0, *) else { return }
        let settings = PaiSettingsController(context: self.context)
        settings.openProjects = { [weak self] in self?.interfaceInteraction?.openPai?() }
        self.effectiveNavigationController?.pushViewController(settings)
    }

    /// Interrupts the session a busy status card shows; the card updates once the daemon reports it stopped.
    func stopPaiSession(_ session: String) {
        guard #available(iOS 16.0, *) else { return }
        Task {
            try? await PaiClient().stop(session: session)
        }
    }
}

/// The pai bot's chat titles itself with where it is: "pai › Hiring › Screener" over an agent's topic, "pai" over
/// the main one, "pai › <topic>" over a plain thread; under it, how many decisions wait on the user. Tapping it
/// opens the hub.
/// nil anywhere outside the bot's chat, which keeps Telegram's own title.
func paiTitleContent(_ interfaceState: ChatPresentationInterfaceState, base: ChatTitleContent) -> ChatTitleContent? {
    guard PaiChat.isBot(interfaceState.renderedPeer?.peer), case .standard(.default) = interfaceState.mode else {
        return nil
    }
    let threadId = interfaceState.chatLocation.threadId
    var crumbs: [String]
    if let agent = PaiChat.agent(thread: threadId), !agent.isPai {
        crumbs = PaiChat.chain(to: agent.slug).map(\.name)
        if PaiChat.chain(to: agent.slug).first?.slug != PaiChat.paiSlug {
            crumbs.insert("pai", at: 0)
        }
    } else if threadId == nil {
        crumbs = ["pai", PaiChat.pendingProject?.slug ?? "New thread"]
    } else if threadId == PaiChat.mainThreadId {
        crumbs = ["pai"]
    } else if case let .peer(_, customTitle?, _, _, _, _, _, _, _) = base {
        crumbs = ["pai", customTitle]
    } else {
        crumbs = ["pai"]
    }
    // What waits on the user reads under the breadcrumb, like unread messages; tapping the title opens it.
    let waiting = PaiChat.needs.count
    let subtitle = waiting == 0 ? nil : waiting == 1 ? "1 decision waiting" : "\(waiting) decisions waiting"
    return .custom(title: [ChatTitleContent.TitleTextItem(id: AnyHashable(0), content: .text(crumbs.joined(separator: " › ")))], subtitle: subtitle, isEnabled: true)
}

/// Where the bot chat's avatar would be: the subscription's limits as two rings — the session window outside,
/// the week inside, amber past 80%, red past 95% — and what the sessions cost so far in the middle.
final class PaiUsageRingNode: ASDisplayNode {
    private let outerTrack = CAShapeLayer()
    private let outer = CAShapeLayer()
    private let innerTrack = CAShapeLayer()
    private let inner = CAShapeLayer()
    private let costNode = ImmediateTextNode()

    override init() {
        super.init()
        for layer in [self.outerTrack, self.outer, self.innerTrack, self.inner] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineCap = .round
            self.layer.addSublayer(layer)
        }
        self.addSubnode(self.costNode)
    }

    override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        return CGSize(width: 44.0, height: 44.0)
    }

    func update(usage: PaiUsage?, theme: PresentationTheme) {
        let size = CGSize(width: 44.0, height: 44.0)
        let bar = theme.rootController.navigationBar
        let center = CGPoint(x: size.width / 2.0, y: size.height / 2.0)
        let color: (Double) -> UIColor = { percent in
            percent >= 95.0 ? UIColor.systemRed : percent >= 80.0 ? UIColor.systemOrange : bar.accentTextColor
        }
        func ring(_ track: CAShapeLayer, _ fill: CAShapeLayer, radius: CGFloat, width: CGFloat, percent: Double?) {
            let path = UIBezierPath(arcCenter: center, radius: radius, startAngle: -.pi / 2.0, endAngle: .pi * 1.5, clockwise: true).cgPath
            track.path = path
            fill.path = path
            track.lineWidth = width
            fill.lineWidth = width
            track.strokeColor = bar.secondaryTextColor.withAlphaComponent(0.18).cgColor
            let value = max(0.0, min(100.0, percent ?? 0.0))
            fill.strokeColor = color(value).cgColor
            fill.strokeEnd = CGFloat(value / 100.0)
            fill.isHidden = percent == nil
        }
        let windows = usage?.windows ?? []
        ring(self.outerTrack, self.outer, radius: 16.0, width: 3.5, percent: windows.first?.percent)
        ring(self.innerTrack, self.inner, radius: 11.5, width: 2.0, percent: windows.dropFirst().first?.percent)

        let cost = usage?.costUsd.map { $0 >= 100.0 ? String(format: "$%.0f", $0) : $0 >= 10.0 ? String(format: "%.0f", $0) : String(format: "%.1f", $0) } ?? ""
        self.costNode.attributedText = NSAttributedString(string: cost, font: Font.with(size: 8.0, design: .regular, weight: .bold, traits: .monospacedNumbers), textColor: bar.primaryTextColor)
        let costSize = self.costNode.updateLayout(CGSize(width: 20.0, height: 12.0))
        self.costNode.frame = CGRect(x: floor(center.x - costSize.width / 2.0), y: floor(center.y - costSize.height / 2.0), width: costSize.width, height: costSize.height)
        self.accessibilityLabel = windows.map { "\($0.name) \(Int($0.percent.rounded())) percent" }.joined(separator: ", ")
    }
}
