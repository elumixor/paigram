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
    static func make(open: @escaping (PaiSession) -> Void) -> UIViewController {
        UIHostingController(rootView: PaiRootView(store: store, open: open))
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

    public init(context: AccountContext) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        self.title = "Pai"

        if #available(iOS 16.0, *) {
            self.hosting = PaiHost.make { [weak self] session in self?.open(session) }
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
        guard let threadId = session.threadId else {
            self.present(textAlertController(context: self.context, title: nil, text: "This thread has no Telegram topic yet", actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]), in: .window(.root))
            return
        }
        self.openThread?(threadId)
    }

    private func applyTheme() {
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.hosting.overrideUserInterfaceStyle = self.presentationData.theme.overallDarkAppearance ? .dark : .light
        self.hosting.view.tintColor = self.presentationData.theme.list.itemAccentColor
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
        // space under the navigation bar outright.
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        let bottom = max(layout.intrinsicInsets.bottom, layout.inputHeight ?? 0.0)
        transition.updateFrame(view: self.hosting.view, frame: CGRect(x: 0, y: top, width: layout.size.width, height: max(0, layout.size.height - top - bottom)))
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

    var body: some View {
        HomeView(open: open).environmentObject(store)
    }
}

