import AccountContext
import AsyncDisplayKit
import Display
import SwiftUI
import UIKit

/// One store for the app's lifetime; the chat starts it and this screen reads from it.
@available(iOS 16.0, *)
@MainActor
public enum PaiHost {
    public static let store = PaiStore()
}

/// pai's hub, opened from the bot chat's title: what needs the user, the agents with their threads, the task
/// board, routines, memory, tools and skills.
public final class PaiHubController: PaiHostedController {
    /// Set by the chat this screen was pushed from: it goes back there and switches to the topic.
    public var openThread: ((Int64) -> Void)?
    /// Set by the chat too: into an agent's chat, its topic or (a sub-agent) a screen of its own.
    public var openAgent: ((String) -> Void)?

    public override init(context: AccountContext) {
        super.init(context: context)
        if #available(iOS 16.0, *) {
            self.host(HubView(
                openAgent: { [weak self] agent in self?.openAgent?(agent.slug) },
                openThread: { [weak self] threadId in self?.openThread?(threadId) },
                close: { [weak self] in self?.dismiss() }
            ).environmentObject(PaiHost.store))
        } else {
            self.host(Text("Pai needs iOS 16 or newer").foregroundColor(.secondary))
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
