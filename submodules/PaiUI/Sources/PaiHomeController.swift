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
    static func make(open: @escaping (PaiSession) -> Void, newThread: @escaping (PaiProject?) -> Void, close: @escaping () -> Void) -> UIViewController {
        UIHostingController(rootView: PaiRootView(store: store, open: open, newThread: newThread, close: close))
    }
}

/// The Pai screen, pushed from the bot's chat: threads and their state, projects, a new thread.
public final class PaiHomeController: ViewController {
    private let context: AccountContext
    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    private var hosting: UIViewController!

    /// Set by the chat this screen was pushed from: it goes back there and switches to the topic.
    public var openThread: ((Int64) -> Void)?
    /// Set by the chat too: back to it, on the view where the next message starts a thread in the project.
    public var newThread: ((PaiProject?) -> Void)?

    public init(context: AccountContext) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: nil)
        // Slides up from the bottom and goes away with a drag down.
        self.navigationPresentation = .modal

        if #available(iOS 16.0, *) {
            self.hosting = PaiHost.make(open: { [weak self] session in self?.open(session) }, newThread: { [weak self] project in self?.newThread?(project) }, close: { [weak self] in self?.dismiss() })
        } else {
            self.hosting = UnsupportedController()
        }
        self.applyTheme()

        self.presentationDataDisposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            guard let self else { return }
            self.presentationData = presentationData
            self.applyTheme()
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.presentationDataDisposable?.dispose()
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

    private func applyTheme() {
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.hosting.overrideUserInterfaceStyle = self.presentationData.theme.overallDarkAppearance ? .dark : .light
        self.hosting.view.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
    }

    override public func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
        self.addChild(self.hosting)
        self.displayNode.view.addSubview(self.hosting.view)
        self.hosting.didMove(toParent: self)
        self.displayNodeDidLoad()
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        // Telegram's containers do not pass UIKit's safe area down, so the hosted screen gets the
        // space under the status bar outright.
        let top = layout.insets(options: [.statusBar]).top
        let bottom = max(layout.intrinsicInsets.bottom, layout.inputHeight ?? 0.0)
        transition.updateFrame(view: self.hosting.view, frame: CGRect(x: 0, y: top, width: layout.size.width, height: max(0, layout.size.height - top)))
        self.hosting.additionalSafeAreaInsets = UIEdgeInsets(top: 0.0, left: 0.0, bottom: bottom, right: 0.0)
    }
}

/// The oldest iOS the app runs on cannot show the SwiftUI screen; say so instead of crashing.
private final class UnsupportedController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let label = UILabel()
        label.text = "Pai needs iOS 16 or newer"
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.frame = view.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }
}

@available(iOS 16.0, *)
struct PaiRootView: View {
    @ObservedObject var store: PaiStore
    let open: (PaiSession) -> Void
    let newThread: (PaiProject?) -> Void
    let close: () -> Void

    var body: some View {
        HomeView(open: open, newThread: newThread, close: close).environmentObject(store)
    }
}

