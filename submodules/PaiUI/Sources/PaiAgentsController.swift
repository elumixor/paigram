import AccountContext
import AsyncDisplayKit
import Display
import Foundation
import SwiftUI
import TelegramPresentationData
import UIKit

/// The agent tree, opened from the bot chat's title: every agent under pai, a tap into its chat.
@available(iOS 16.0, *)
public final class PaiAgentTreeController: PaiHostedController {
    /// Set by the chat: takes this screen away and opens the agent's chat.
    public var openAgent: ((String) -> Void)?

    public override init(context: AccountContext) {
        super.init(context: context)
        self.host(AgentTreeView(open: { [weak self] agent in self?.openAgent?(agent.slug) }, close: { [weak self] in self?.dismiss() }).environmentObject(PaiHost.store))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A sub-agent's chat. It has no topic of its own, so it is a screen of the app, pushed above its parent's chat:
/// the back swipe goes up a level, a card goes down one.
@available(iOS 16.0, *)
public final class PaiAgentChatController: PaiHostedController {
    public let slug: String
    /// Set by the chat that opened it: any other agent's chat, up or down the tree.
    public var openAgent: ((String) -> Void)?

    public init(context: AccountContext, slug: String) {
        self.slug = slug
        super.init(context: context)
        // Pushed like a chat, so the back swipe works; set before the hosted view exists.
        self.navigationPresentation = .default
        PaiHost.store.prime(slug)
        self.host(AgentChatView(slug: slug, open: { [weak self] slug in self?.openAgent?(slug) }, back: { [weak self] in
            guard let self else { return }
            let _ = (self.navigationController as? NavigationController)?.popViewController(animated: true)
        }).environmentObject(PaiHost.store))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
