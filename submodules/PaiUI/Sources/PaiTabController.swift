import AccountContext
import AsyncDisplayKit
import Display
import SwiftSignalKit
import SwiftUI
import TelegramPresentationData
import UIKit

/// The Pai tab: a SwiftUI screen hosted inside Telegram's controller tree.
public final class PaiTabController: ViewController {
    private let context: AccountContext
    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    private let hosting: UIViewController

    public init(context: AccountContext) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        if #available(iOS 16.0, *) {
            self.hosting = PaiHost.make()
        } else {
            self.hosting = UnsupportedController()
        }
        super.init(navigationBarPresentationData: nil)

        self.tabBarItem.title = "Pai"
        let icon = UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium))?.withRenderingMode(.alwaysTemplate)
        self.tabBarItem.image = icon
        self.tabBarItem.selectedImage = icon
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
        self.hosting.view.frame = CGRect(origin: .zero, size: layout.size)
        // Telegram's containers do not pass UIKit's safe area down, and its tab bar is not a UITabBar:
        // the status bar and the tab bar both have to be added by hand.
        let top = layout.insets(options: [.statusBar]).top
        let bottom = layout.intrinsicInsets.bottom
        self.hosting.additionalSafeAreaInsets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
    }
}

/// One store for the app's lifetime; the tab may be rebuilt when accounts switch.
@available(iOS 16.0, *)
@MainActor
enum PaiHost {
    static let settings = PaiSettings()
    static let store = PaiStore(settings: settings)
    static func make() -> UIViewController { UIHostingController(rootView: PaiRootView(store: store, settings: settings)) }
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
    @ObservedObject var settings: PaiSettings

    var body: some View {
        HomeView()
            .environmentObject(store)
            .environmentObject(settings)
    }
}
