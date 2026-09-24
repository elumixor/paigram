import AccountContext
import AsyncDisplayKit
import Display
import SwiftSignalKit
import SwiftUI
import TelegramPresentationData
import UIKit

/// What the hosted screen has to keep clear at the bottom; UIKit's safe area does not reach it here.
public final class PaiInsets: ObservableObject {
    @Published public var bottom: CGFloat = 0
}

/// A SwiftUI screen inside Telegram's controller tree: themed, laid out under the status bar and
/// above the home indicator, presented from the bottom.
open class PaiHostedController: ViewController {
    public let insets = PaiInsets()
    public let context: AccountContext
    public private(set) var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    private var hosting: UIViewController?

    public init(context: AccountContext) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: nil)
        self.navigationPresentation = .modal
        self.presentationDataDisposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            guard let self else { return }
            self.presentationData = presentationData
            self.applyTheme()
        })
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.presentationDataDisposable?.dispose()
    }

    /// Subclasses hand over the screen once; it is themed, placed, and told about the insets from then on.
    public func host<Content: View>(_ view: Content) {
        self.hosting = UIHostingController(rootView: view.environmentObject(self.insets))
        self.applyTheme()
    }

    private func applyTheme() {
        guard let hosting = self.hosting else { return }
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        hosting.overrideUserInterfaceStyle = self.presentationData.theme.overallDarkAppearance ? .dark : .light
        hosting.view.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
    }

    override open func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
        if let hosting = self.hosting {
            self.addChild(hosting)
            self.displayNode.view.addSubview(hosting.view)
            hosting.didMove(toParent: self)
        }
        self.displayNodeDidLoad()
    }

    override open func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        guard let hosting = self.hosting else { return }
        // Telegram's containers do not pass UIKit's safe area down, and the modal layout reports no
        // bottom inset of its own, so the window's is the floor.
        let top = layout.insets(options: [.statusBar]).top
        let deviceBottom = layout.deviceMetrics.onScreenNavigationHeight(inLandscape: layout.size.width > layout.size.height, systemOnScreenNavigationHeight: nil) ?? 0.0
        let bottom = max(layout.intrinsicInsets.bottom, layout.safeInsets.bottom, deviceBottom, layout.inputHeight ?? 0.0)
        transition.updateFrame(view: hosting.view, frame: CGRect(x: 0, y: top, width: layout.size.width, height: max(0, layout.size.height - top)))
        if self.insets.bottom != bottom {
            self.insets.bottom = bottom
        }
    }
}
