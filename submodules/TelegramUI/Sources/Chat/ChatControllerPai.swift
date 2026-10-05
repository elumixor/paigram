import Foundation
import UIKit
import Display
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
/// the main one, "pai › <topic>" over a plain thread. Tapping it opens the hub.
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
    return .custom(title: [ChatTitleContent.TitleTextItem(id: AnyHashable(0), content: .text(crumbs.joined(separator: " › ")))], subtitle: nil, isEnabled: true)
}

/// The subscription's limits as bars under the bot chat's title, over pai's own topic: how much of the session
/// window and of the week is spent, and what the sessions cost. nil anywhere else.
func paiUsagePanel(_ interfaceState: ChatPresentationInterfaceState, open: @escaping () -> Void) -> AnyComponent<Empty>? {
    guard PaiChat.isBot(interfaceState.renderedPeer?.peer), case .standard(.default) = interfaceState.mode, let usage = PaiChat.usage, !usage.windows.isEmpty else {
        return nil
    }
    let threadId = interfaceState.chatLocation.threadId
    guard threadId == nil || threadId == PaiChat.mainThreadId else {
        return nil
    }
    return AnyComponent(PaiUsagePanelComponent(theme: interfaceState.theme, windows: Array(usage.windows.prefix(2)), cost: usage.costUsd, open: open))
}

final class PaiUsagePanelComponent: Component {
    let theme: PresentationTheme
    let windows: [PaiUsageWindow]
    let cost: Double?
    let open: () -> Void

    init(theme: PresentationTheme, windows: [PaiUsageWindow], cost: Double?, open: @escaping () -> Void) {
        self.theme = theme
        self.windows = windows
        self.cost = cost
        self.open = open
    }

    static func ==(lhs: PaiUsagePanelComponent, rhs: PaiUsagePanelComponent) -> Bool {
        return lhs.theme === rhs.theme && lhs.windows == rhs.windows && lhs.cost == rhs.cost
    }

    /// One window: its name, a bar filled to how much is used (amber past 80%, red past 95%), the percentage.
    private final class Meter: UIView {
        let label = UILabel()
        let track = UIView()
        let fill = UIView()
        let value = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.track.layer.cornerRadius = 2.5
            self.fill.layer.cornerRadius = 2.5
            self.track.addSubview(self.fill)
            for view in [self.label, self.track, self.value] {
                self.addSubview(view)
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(window: PaiUsageWindow, theme: PresentationTheme, width: CGFloat, height: CGFloat) {
            let bar = theme.rootController.navigationBar
            let percent = max(0.0, min(100.0, window.percent))
            self.label.text = window.name
            self.label.font = Font.medium(12.0)
            self.label.textColor = bar.secondaryTextColor
            self.value.text = "\(Int(percent.rounded()))%"
            self.value.font = Font.with(size: 12.0, design: .regular, weight: .semibold, traits: .monospacedNumbers)
            self.value.textColor = bar.primaryTextColor
            self.track.backgroundColor = bar.secondaryTextColor.withAlphaComponent(0.2)
            self.fill.backgroundColor = percent >= 95.0 ? UIColor.systemRed : percent >= 80.0 ? UIColor.systemOrange : bar.accentTextColor
            self.label.sizeToFit()
            self.value.sizeToFit()
            let valueWidth = max(self.value.bounds.width, 30.0)
            self.label.frame = CGRect(x: 0.0, y: floor((height - self.label.bounds.height) / 2.0), width: self.label.bounds.width, height: self.label.bounds.height)
            let trackX = self.label.frame.maxX + 6.0
            let trackWidth = max(20.0, width - trackX - valueWidth - 4.0)
            self.track.frame = CGRect(x: trackX, y: floor((height - 5.0) / 2.0), width: trackWidth, height: 5.0)
            self.fill.frame = CGRect(x: 0.0, y: 0.0, width: max(5.0, trackWidth * CGFloat(percent / 100.0)), height: 5.0)
            self.value.frame = CGRect(x: self.track.frame.maxX + 4.0, y: floor((height - self.value.bounds.height) / 2.0), width: valueWidth, height: self.value.bounds.height)
        }
    }

    final class View: UIView {
        private var meters: [Meter] = []
        private let costLabel = UILabel()
        private var component: PaiUsagePanelComponent?

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.costLabel.textAlignment = .right
            self.addSubview(self.costLabel)
            self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapped)))
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func tapped() {
            self.component?.open()
        }

        func update(component: PaiUsagePanelComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
            self.component = component
            let size = CGSize(width: availableSize.width, height: 34.0)
            let bar = component.theme.rootController.navigationBar
            let inset: CGFloat = 16.0

            self.costLabel.text = component.cost.map { String(format: "$%.2f", $0) }
            self.costLabel.font = Font.with(size: 12.0, design: .regular, weight: .semibold, traits: .monospacedNumbers)
            self.costLabel.textColor = bar.secondaryTextColor
            self.costLabel.sizeToFit()
            let costWidth = component.cost == nil ? 0.0 : self.costLabel.bounds.width + 12.0
            self.costLabel.frame = CGRect(x: size.width - inset - self.costLabel.bounds.width, y: floor((size.height - self.costLabel.bounds.height) / 2.0), width: self.costLabel.bounds.width, height: self.costLabel.bounds.height)

            while self.meters.count < component.windows.count {
                let meter = Meter()
                self.addSubview(meter)
                self.meters.append(meter)
            }
            while self.meters.count > component.windows.count {
                self.meters.removeLast().removeFromSuperview()
            }
            let gap: CGFloat = 14.0
            let count = CGFloat(max(1, component.windows.count))
            let meterWidth = floor((size.width - inset * 2.0 - costWidth - gap * (count - 1.0)) / count)
            for (index, window) in component.windows.enumerated() {
                let meter = self.meters[index]
                meter.frame = CGRect(x: inset + CGFloat(index) * (meterWidth + gap), y: 0.0, width: meterWidth, height: size.height)
                meter.update(window: window, theme: component.theme, width: meterWidth, height: size.height)
            }
            return size
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}
