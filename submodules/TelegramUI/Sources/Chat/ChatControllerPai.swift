import Foundation
import UIKit
import Display
import ComponentFlow
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ChatPresentationInterfaceState
import PaiUI

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

    /// The agent tree, from the chat's title: every agent with its status, a tap into its chat.
    func openPaiTree() {
        guard #available(iOS 16.0, *), let navigationController = self.effectiveNavigationController else {
            return
        }
        let tree = PaiAgentTreeController(context: self.context)
        tree.openAgent = { [weak self] slug in
            self?.openPaiAgent(slug: slug, thread: nil)
        }
        navigationController.pushViewController(tree)
    }
}

/// The breadcrumb over an agent's topic (pai › Hiring › Screener); nil anywhere else.
func paiBreadcrumbPanel(_ interfaceState: ChatPresentationInterfaceState, open: @escaping (String) -> Void) -> AnyComponent<Empty>? {
    guard PaiChat.isBot(interfaceState.renderedPeer?.peer), let agent = PaiChat.agent(thread: interfaceState.chatLocation.threadId), !agent.isPai else {
        return nil
    }
    var crumbs = PaiChat.chain(to: agent.slug).map { PaiBreadcrumbPanelComponent.Crumb(slug: $0.slug, name: $0.name) }
    if crumbs.first?.slug != PaiChat.paiSlug {
        crumbs.insert(PaiBreadcrumbPanelComponent.Crumb(slug: PaiChat.paiSlug, name: "pai"), at: 0)
    }
    return AnyComponent(PaiBreadcrumbPanelComponent(theme: interfaceState.theme, crumbs: crumbs, open: open))
}

/// A row of crumbs under the chat's bar; every level above this one is a button back up to it.
final class PaiBreadcrumbPanelComponent: Component {
    struct Crumb: Equatable {
        let slug: String
        let name: String
    }

    let theme: PresentationTheme
    let crumbs: [Crumb]
    let open: (String) -> Void

    init(theme: PresentationTheme, crumbs: [Crumb], open: @escaping (String) -> Void) {
        self.theme = theme
        self.crumbs = crumbs
        self.open = open
    }

    static func ==(lhs: PaiBreadcrumbPanelComponent, rhs: PaiBreadcrumbPanelComponent) -> Bool {
        return lhs.theme === rhs.theme && lhs.crumbs == rhs.crumbs
    }

    final class View: UIView {
        private let scrollView = UIScrollView()
        private var items: [UIView] = []
        private var component: PaiBreadcrumbPanelComponent?

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.scrollView.showsHorizontalScrollIndicator = false
            self.scrollView.alwaysBounceHorizontal = false
            self.addSubview(self.scrollView)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func crumbPressed(_ sender: UIButton) {
            guard let component = self.component, sender.tag < component.crumbs.count else {
                return
            }
            component.open(component.crumbs[sender.tag].slug)
        }

        func update(component: PaiBreadcrumbPanelComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
            let previous = self.component
            self.component = component
            let size = CGSize(width: availableSize.width, height: 40.0)
            self.scrollView.frame = CGRect(origin: CGPoint(), size: size)
            if let previous, previous == component {
                return size
            }

            for item in self.items {
                item.removeFromSuperview()
            }
            self.items.removeAll()

            let bar = component.theme.rootController.navigationBar
            let chevron = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10.0, weight: .semibold))?.withTintColor(bar.secondaryTextColor, renderingMode: .alwaysOriginal)
            var x: CGFloat = 14.0
            for (index, crumb) in component.crumbs.enumerated() {
                if index > 0, let chevron {
                    let view = UIImageView(image: chevron)
                    view.frame = CGRect(origin: CGPoint(x: x, y: floor((size.height - chevron.size.height) / 2.0)), size: chevron.size)
                    self.scrollView.addSubview(view)
                    self.items.append(view)
                    x += chevron.size.width + 6.0
                }
                let isCurrent = index == component.crumbs.count - 1
                let button = UIButton(type: .system)
                button.tag = index
                button.setTitle(crumb.name, for: .normal)
                button.titleLabel?.font = isCurrent ? Font.semibold(15.0) : Font.regular(15.0)
                button.setTitleColor(isCurrent ? bar.primaryTextColor : bar.accentTextColor, for: .normal)
                button.isUserInteractionEnabled = !isCurrent
                button.addTarget(self, action: #selector(self.crumbPressed(_:)), for: .touchUpInside)
                button.sizeToFit()
                button.frame = CGRect(x: x, y: 0.0, width: button.bounds.width, height: size.height)
                self.scrollView.addSubview(button)
                self.items.append(button)
                x += button.bounds.width + 6.0
            }
            self.scrollView.contentSize = CGSize(width: x + 8.0, height: size.height)
            // The current level is the one that matters; when the trail is long it is the end that shows.
            self.scrollView.contentOffset = CGPoint(x: max(0.0, self.scrollView.contentSize.width - size.width), y: 0.0)
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
