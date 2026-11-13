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
        let close: () -> Void = { [weak self] in self?.dismiss() }
        self.host(PaiSignInGate(close: close) {
            AgentTreeView(open: { [weak self] agent in self?.openAgent?(agent.slug) }, close: close)
        }.environmentObject(PaiHost.store))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
