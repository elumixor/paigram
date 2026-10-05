import AccountContext
import AsyncDisplayKit
import Display
import PresentationDataUtils
import SwiftSignalKit
import SwiftUI
import TelegramPresentationData
import UIKit

/// One store for the app's lifetime; the chat starts it and this screen reads from it.
@available(iOS 16.0, *)
@MainActor
public enum PaiHost {
    public static let store = PaiStore()
}

/// The Pai screen, opened from the bot's chat: every thread and agent by recency, a new thread.
public final class PaiHomeController: PaiHostedController {
    /// Set by the chat this screen was pushed from: it goes back there and switches to the topic.
    public var openThread: ((Int64) -> Void)?
    /// Set by the chat too: an agent has no topic of its own to switch to, so it pushes a screen instead.
    public var openAgent: ((String) -> Void)?
    /// Set by the chat too: back to it, on the view where the next message starts a thread in the project.
    public var newThread: ((PaiProject?) -> Void)?

    public override init(context: AccountContext) {
        super.init(context: context)
        if #available(iOS 16.0, *) {
            self.host(PaiRootView(store: PaiHost.store, open: { [weak self] session in self?.open(session) }, openAgent: { [weak self] agent in self?.openAgent?(agent.slug) }, newThread: { [weak self] project in self?.newThread?(project) }, close: { [weak self] in self?.dismiss() }))
        } else {
            self.host(Text("Pai needs iOS 16 or newer").foregroundColor(.secondary))
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func open(_ session: PaiSession) {
        if let threadId = session.threadId {
            self.openThread?(threadId)
            return
        }
        // Held on disk: make it live, the bot gives it a topic, then open that.
        guard #available(iOS 16.0, *) else { return }
        Task { @MainActor [weak self] in
            do {
                let live = try await PaiHost.store.adopt(session)
                guard let threadId = live.threadId else { throw PaiClientError(message: "The bot has not made a topic for it yet; try again in a moment") }
                self?.openThread?(threadId)
            } catch {
                guard let self else { return }
                self.present(textAlertController(context: self.context, title: nil, text: error.localizedDescription, actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]), in: .window(.root))
            }
        }
    }
}

@available(iOS 16.0, *)
struct PaiRootView: View {
    @ObservedObject var store: PaiStore
    let open: (PaiSession) -> Void
    let openAgent: (PaiAgent) -> Void
    let newThread: (PaiProject?) -> Void
    let close: () -> Void

    var body: some View {
        HomeView(open: open, openAgent: openAgent, newThread: newThread, close: close).environmentObject(store)
    }
}

