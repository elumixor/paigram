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

/// Where the bot chat's avatar would be: one ring for the limit that runs out first — the session window, or a
/// weekly one when that is further along — its percentage in the middle and the time to its reset under it.
/// Pressed and held, a card with every limit, when each resets and what the sessions cost; let go, it goes.
final class PaiUsageRingNode: ASDisplayNode {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let percentNode = ImmediateTextNode()
    private let timeNode = ImmediateTextNode()
    private var usage: PaiUsage?
    private var theme: PresentationTheme?
    private var card: UIView?
    private var clock: Timer?

    override init() {
        super.init()
        for layer in [self.track, self.fill] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineCap = .round
            self.layer.addSublayer(layer)
        }
        self.addSubnode(self.percentNode)
        self.addSubnode(self.timeNode)
    }

    override func didLoad() {
        super.didLoad()
        let press = UILongPressGestureRecognizer(target: self, action: #selector(self.pressed(_:)))
        press.minimumPressDuration = 0.25
        self.view.addGestureRecognizer(press)
        // The time to the reset counts down between usage updates.
        self.clock = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self, let theme = self.theme else { return }
            self.update(usage: self.usage, theme: theme)
        }
    }

    deinit {
        self.clock?.invalidate()
    }

    override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        return CGSize(width: 44.0, height: 44.0)
    }

    private static func color(_ percent: Double, accent: UIColor) -> UIColor {
        percent >= 95.0 ? UIColor.systemRed : percent >= 80.0 ? UIColor.systemOrange : accent
    }

    func update(usage: PaiUsage?, theme: PresentationTheme) {
        self.usage = usage
        self.theme = theme
        let size = CGSize(width: 44.0, height: 44.0)
        let bar = theme.rootController.navigationBar
        let center = CGPoint(x: size.width / 2.0, y: size.height / 2.0)
        let window = usage?.limiting
        let percent = max(0.0, min(100.0, window?.percent ?? 0.0))

        let path = UIBezierPath(arcCenter: center, radius: 18.0, startAngle: -.pi / 2.0, endAngle: .pi * 1.5, clockwise: true).cgPath
        for layer in [self.track, self.fill] {
            layer.path = path
            layer.lineWidth = 3.0
        }
        self.track.strokeColor = bar.secondaryTextColor.withAlphaComponent(0.18).cgColor
        self.fill.strokeColor = Self.color(percent, accent: bar.accentTextColor).cgColor
        self.fill.strokeEnd = CGFloat(percent / 100.0)
        self.fill.isHidden = window == nil

        let time = window?.resetsIn ?? ""
        self.percentNode.attributedText = NSAttributedString(string: window == nil ? "" : "\(Int(percent.rounded()))%", font: Font.with(size: 11.0, design: .regular, weight: .bold, traits: .monospacedNumbers), textColor: bar.primaryTextColor)
        self.timeNode.attributedText = NSAttributedString(string: time, font: Font.with(size: 7.5, design: .regular, weight: .medium, traits: .monospacedNumbers), textColor: bar.secondaryTextColor)
        let percentSize = self.percentNode.updateLayout(CGSize(width: 30.0, height: 14.0))
        let timeSize = self.timeNode.updateLayout(CGSize(width: 28.0, height: 10.0))
        let total = percentSize.height + (time.isEmpty ? 0.0 : timeSize.height - 1.0)
        let top = floor(center.y - total / 2.0)
        self.percentNode.frame = CGRect(x: floor(center.x - percentSize.width / 2.0), y: top, width: percentSize.width, height: percentSize.height)
        self.timeNode.frame = CGRect(x: floor(center.x - timeSize.width / 2.0), y: top + percentSize.height - 1.0, width: timeSize.width, height: timeSize.height)
        self.accessibilityLabel = window.map { "\($0.name) \(Int($0.percent.rounded())) percent\(time.isEmpty ? "" : ", resets in \(time)")" }
    }

    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            self.showCard()
        case .ended, .cancelled, .failed:
            self.hideCard()
        default:
            break
        }
    }

    private func showCard() {
        guard self.card == nil, let usage = self.usage, let theme = self.theme, let window = self.view.window else {
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let card = PaiUsageCard(usage: usage, theme: theme)
        let width: CGFloat = 250.0
        let height = card.preferredHeight(width: width)
        let anchor = self.view.convert(self.view.bounds, to: window)
        let x = min(window.bounds.width - width - 12.0, max(12.0, anchor.maxX - width))
        card.frame = CGRect(x: x, y: anchor.maxY + 8.0, width: width, height: height)
        card.layout(width: width)
        window.addSubview(card)
        card.alpha = 0.0
        card.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.18) {
            card.alpha = 1.0
            card.transform = .identity
        }
        self.card = card
    }

    private func hideCard() {
        guard let card = self.card else { return }
        self.card = nil
        UIView.animate(withDuration: 0.14, animations: { card.alpha = 0.0 }, completion: { _ in card.removeFromSuperview() })
    }
}

/// Every limit with its bar and reset, and the cost so far: what holding the usage ring shows.
private final class PaiUsageCard: UIView {
    private let usage: PaiUsage
    private let theme: PresentationTheme
    private var rows: [(label: UILabel, value: UILabel, track: UIView, fill: UIView, reset: UILabel)] = []
    private let costLabel = UILabel()
    private let background: UIVisualEffectView

    init(usage: PaiUsage, theme: PresentationTheme) {
        self.usage = usage
        self.theme = theme
        self.background = UIVisualEffectView(effect: UIBlurEffect(style: theme.overallDarkAppearance ? .systemMaterialDark : .systemMaterialLight))
        super.init(frame: .zero)
        self.isUserInteractionEnabled = false
        self.layer.cornerRadius = 16.0
        self.layer.shadowColor = UIColor.black.cgColor
        self.layer.shadowOpacity = 0.18
        self.layer.shadowRadius = 14.0
        self.layer.shadowOffset = CGSize(width: 0.0, height: 6.0)
        self.background.layer.cornerRadius = 16.0
        self.background.clipsToBounds = true
        self.addSubview(self.background)

        let bar = theme.rootController.navigationBar
        for window in usage.windows {
            let label = UILabel()
            label.text = window.name
            label.font = Font.semibold(13.0)
            label.textColor = bar.primaryTextColor
            let value = UILabel()
            value.text = "\(Int(window.percent.rounded()))%"
            value.font = Font.with(size: 13.0, design: .regular, weight: .semibold, traits: .monospacedNumbers)
            value.textColor = bar.primaryTextColor
            value.textAlignment = .right
            let track = UIView()
            track.backgroundColor = bar.secondaryTextColor.withAlphaComponent(0.2)
            track.layer.cornerRadius = 2.5
            let fill = UIView()
            fill.backgroundColor = window.percent >= 95.0 ? .systemRed : window.percent >= 80.0 ? .systemOrange : bar.accentTextColor
            fill.layer.cornerRadius = 2.5
            track.addSubview(fill)
            let reset = UILabel()
            reset.text = window.resetsIn.map { "resets in \($0)" } ?? ""
            reset.font = Font.regular(11.0)
            reset.textColor = bar.secondaryTextColor
            for view in [label, value, track, reset] {
                self.addSubview(view)
            }
            self.rows.append((label, value, track, fill, reset))
        }
        self.costLabel.text = usage.costUsd.map { String(format: "Sessions cost $%.2f", $0) }
        self.costLabel.font = Font.medium(12.0)
        self.costLabel.textColor = bar.secondaryTextColor
        self.addSubview(self.costLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static let rowHeight: CGFloat = 44.0

    func preferredHeight(width: CGFloat) -> CGFloat {
        return 12.0 + CGFloat(self.rows.count) * Self.rowHeight + (self.usage.costUsd == nil ? 0.0 : 24.0) + 8.0
    }

    func layout(width: CGFloat) {
        self.background.frame = self.bounds
        let inset: CGFloat = 14.0
        var y: CGFloat = 12.0
        for (index, row) in self.rows.enumerated() {
            let percent = max(0.0, min(100.0, self.usage.windows[index].percent))
            row.label.frame = CGRect(x: inset, y: y, width: width - inset * 2.0 - 50.0, height: 17.0)
            row.value.frame = CGRect(x: width - inset - 50.0, y: y, width: 50.0, height: 17.0)
            row.track.frame = CGRect(x: inset, y: y + 21.0, width: width - inset * 2.0, height: 5.0)
            row.fill.frame = CGRect(x: 0.0, y: 0.0, width: max(5.0, (width - inset * 2.0) * CGFloat(percent / 100.0)), height: 5.0)
            row.reset.frame = CGRect(x: inset, y: y + 28.0, width: width - inset * 2.0, height: 14.0)
            y += Self.rowHeight
        }
        self.costLabel.frame = CGRect(x: inset, y: y + 2.0, width: width - inset * 2.0, height: 16.0)
    }
}
