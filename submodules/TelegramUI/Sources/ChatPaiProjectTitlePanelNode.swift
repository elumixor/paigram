import AsyncDisplayKit
import ChatPresentationInterfaceState
import Display
import Foundation
import LegacyChatHeaderPanelComponent
import PaiUI
import TelegramPresentationData
import UIKit

/// Above the pai bot's chat before a first message: which project the new thread starts in.
final class ChatPaiProjectTitlePanelNode: ChatTitleAccessoryPanelNode {
    private let separatorNode = ASDisplayNode()
    private let buttonNode = HighlightableButtonNode()
    private let iconNode = ASImageNode()
    private let titleNode = ImmediateTextNode()
    private var observer: NSObjectProtocol?
    private var theme: PresentationTheme?

    override init() {
        self.separatorNode.isLayerBacked = true
        self.iconNode.displaysAsynchronously = false
        self.iconNode.contentMode = .center
        self.titleNode.maximumNumberOfLines = 1
        self.titleNode.displaysAsynchronously = false
        super.init()
        self.addSubnode(self.separatorNode)
        self.addSubnode(self.buttonNode)
        self.buttonNode.addSubnode(self.iconNode)
        self.buttonNode.addSubnode(self.titleNode)
        self.buttonNode.addTarget(self, action: #selector(self.pressed), forControlEvents: .touchUpInside)
        self.observer = NotificationCenter.default.addObserver(forName: PaiChat.projectChanged, object: nil, queue: .main) { [weak self] _ in
            self?.theme = nil
            self?.interfaceInteraction?.requestLayout(.animated(duration: 0.2, curve: .easeInOut))
        }
    }

    deinit {
        if let observer = self.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @objc private func pressed() {
        self.interfaceInteraction?.selectPaiProject?()
    }

    override func updateLayout(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition, interfaceState: ChatPresentationInterfaceState) -> LayoutResult {
        let panelHeight: CGFloat = 40.0
        if interfaceState.theme !== self.theme {
            self.theme = interfaceState.theme
            let accent = interfaceState.theme.rootController.navigationBar.primaryTextColor
            let project = PaiChat.pendingProject
            self.separatorNode.backgroundColor = interfaceState.theme.rootController.navigationBar.separatorColor
            self.iconNode.image = UIImage(systemName: project.map(PaiProjectIcon.symbol) ?? "folder.badge.plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14.0, weight: .medium))?.withTintColor(accent, renderingMode: .alwaysOriginal)
            self.titleNode.attributedText = NSAttributedString(string: project?.slug ?? "Select project", font: Font.medium(15.0), textColor: accent)
        }

        let titleSize = self.titleNode.updateLayout(CGSize(width: width - leftInset - rightInset - 60.0, height: panelHeight))
        let iconWidth: CGFloat = 22.0
        let contentWidth = iconWidth + 6.0 + titleSize.width
        let contentX = floor((width - contentWidth) / 2.0)
        self.buttonNode.frame = CGRect(x: 0.0, y: 0.0, width: width, height: panelHeight)
        self.iconNode.frame = CGRect(x: contentX, y: floor((panelHeight - iconWidth) / 2.0), width: iconWidth, height: iconWidth)
        self.titleNode.frame = CGRect(origin: CGPoint(x: contentX + iconWidth + 6.0, y: floor((panelHeight - titleSize.height) / 2.0)), size: titleSize)
        transition.updateFrame(node: self.separatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: width, height: UIScreenPixel)))
        return LayoutResult(backgroundHeight: panelHeight, insetHeight: panelHeight, hitTestSlop: 0.0)
    }
}
