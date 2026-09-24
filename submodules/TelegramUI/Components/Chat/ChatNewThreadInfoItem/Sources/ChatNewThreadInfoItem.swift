import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import Postbox
import TelegramPresentationData
import TextFormat
import AccountContext
import WallpaperBackgroundNode
import ChatControllerInteraction
import ChatMessageBubbleContentNode
import TelegramStringFormatting
import ChatControllerInteraction
import ComponentFlow
import BundleIconComponent
import PaiUI

public final class ChatNewThreadInfoItem: ListViewItem {
    fileprivate let controllerInteraction: ChatControllerInteraction
    fileprivate let presentationData: ChatPresentationData
    fileprivate let context: AccountContext
    fileprivate let isPaiBot: Bool
    
    public init(
        controllerInteraction: ChatControllerInteraction,
        presentationData: ChatPresentationData,
        context: AccountContext,
        peerId: PeerId?
    ) {
        self.controllerInteraction = controllerInteraction
        self.presentationData = presentationData
        self.context = context
        self.isPaiBot = peerId != nil && peerId == PaiChat.botPeerId
    }
    
    public func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        let configure = {
            let node = ChatNewThreadInfoItemNode()
            
            let nodeLayout = node.asyncLayout()
            let (layout, apply) = nodeLayout(self, params)
            
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply(.None) })
                })
            }
        }
        if Thread.isMainThread {
            async {
                configure()
            }
        } else {
            configure()
        }
    }
    
    public func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? ChatNewThreadInfoItemNode {
                let nodeLayout = nodeValue.asyncLayout()
                
                async {
                    let (layout, apply) = nodeLayout(self, params)
                    Queue.mainQueue().async {
                        completion(layout, { _ in
                            apply(animation)
                        })
                    }
                }
            }
        }
    }
}

public final class ChatNewThreadInfoItemNode: ListViewItemNode, ASGestureRecognizerDelegate {
    public var controllerInteraction: ChatControllerInteraction?
    
    public let offsetContainer: ASDisplayNode
    public let titleNode: TextNode
    public let subtitleNode: TextNode
    /// The pai bot's chat: the project the new thread starts in.
    private let projectButton = ASDisplayNode()
    private let projectIcon = ASImageNode()
    private let projectLabel = ImmediateTextNode()
    private var projectObserver: NSObjectProtocol?
    var arrowView: UIImageView?
    let iconBackground: SimpleLayer
    var icon = ComponentView<Empty>()
    
    private var theme: ChatPresentationThemeData?
    
    private var wallpaperBackgroundNode: WallpaperBackgroundNode?
    private var backgroundContent: WallpaperBubbleBackgroundNode?
    
    private var absolutePosition: (CGRect, CGSize)?
    
    private var item: ChatNewThreadInfoItem?
    
    public init() {
        self.offsetContainer = ASDisplayNode()
        
        self.iconBackground = SimpleLayer()
        
        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.displaysAsynchronously = false
        
        self.subtitleNode = TextNode()
        self.subtitleNode.isUserInteractionEnabled = false
        self.subtitleNode.displaysAsynchronously = false
        
        super.init(layerBacked: false, rotated: true)
        
        self.transform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)
        
        self.addSubnode(self.offsetContainer)
        self.offsetContainer.addSubnode(self.titleNode)
        self.offsetContainer.addSubnode(self.subtitleNode)

        self.projectIcon.displaysAsynchronously = false
        self.projectIcon.contentMode = .center
        self.projectLabel.displaysAsynchronously = false
        self.projectLabel.maximumNumberOfLines = 1
        self.projectButton.cornerRadius = 10.0
        self.projectButton.isHidden = true
        self.projectButton.addSubnode(self.projectIcon)
        self.projectButton.addSubnode(self.projectLabel)
        self.projectButton.isUserInteractionEnabled = false
        self.offsetContainer.addSubnode(self.projectButton)
        self.projectObserver = NotificationCenter.default.addObserver(forName: PaiChat.projectChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateProjectButton()
        }
    }

    deinit {
        if let projectObserver = self.projectObserver {
            NotificationCenter.default.removeObserver(projectObserver)
        }
    }

    @objc private func projectPressed() {
        self.item?.controllerInteraction.selectPaiProject?()
    }

    private static let projectRowHeight: CGFloat = 34.0

    /// Relabels the row in place; its size is fixed, so no relayout is needed.
    private func updateProjectButton(width: CGFloat? = nil) {
        guard let item = self.item, !self.projectButton.isHidden else { return }
        let width = width ?? self.projectButton.frame.width
        let color = serviceMessageColorComponents(theme: item.presentationData.theme.theme, wallpaper: item.presentationData.theme.wallpaper).primaryText
        let project = PaiChat.pendingProject
        self.projectButton.backgroundColor = color.withAlphaComponent(0.14)
        self.projectIcon.image = UIImage(systemName: project.map(PaiProjectIcon.symbol) ?? PaiProjectIcon.general, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .medium))?.withTintColor(color, renderingMode: .alwaysOriginal)
        self.projectLabel.attributedText = NSAttributedString(string: project?.slug ?? "General", font: Font.medium(14.0), textColor: color)
        let labelSize = self.projectLabel.updateLayout(CGSize(width: max(1.0, width - 40.0), height: Self.projectRowHeight))
        let iconWidth: CGFloat = 20.0
        let contentWidth = iconWidth + 6.0 + labelSize.width
        let x = floor((width - contentWidth) / 2.0)
        self.projectIcon.frame = CGRect(x: x, y: floor((Self.projectRowHeight - iconWidth) / 2.0), width: iconWidth, height: iconWidth)
        self.projectLabel.frame = CGRect(origin: CGPoint(x: x + iconWidth + 6.0, y: floor((Self.projectRowHeight - labelSize.height) / 2.0)), size: labelSize)
    }
                
    override public func didLoad() {
        super.didLoad()
        
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
        tapRecognizer.delegate = self.wrappedGestureRecognizerDelegate
        self.offsetContainer.view.addGestureRecognizer(tapRecognizer)
    }
    
    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer.view === self.offsetContainer.view {
            let location = gestureRecognizer.location(in: self.offsetContainer.view)
            if let backgroundContent = self.backgroundContent, backgroundContent.frame.contains(location) {
                return true
            }
            return false
        }
        return true
    }
    
    @objc private func tapGesture(_ gestureRecognizer: UITapGestureRecognizer) {
        if !self.projectButton.isHidden, self.projectButton.frame.contains(gestureRecognizer.location(in: self.offsetContainer.view)) {
            self.projectPressed()
            return
        }
        if let item = self.item {
            item.controllerInteraction.updateInputMode { mode in
                if case .none = mode {
                    return .text
                } else {
                    return mode
                }
            }
        }
    }
    
    override public func updateAbsoluteRect(_ rect: CGRect, within containerSize: CGSize) {
        super.updateAbsoluteRect(rect, within: containerSize)
        
        self.absolutePosition = (rect, containerSize)
        if let backgroundContent = self.backgroundContent {
            var backgroundFrame = backgroundContent.frame
            backgroundFrame.origin.x += rect.minX
            backgroundFrame.origin.y += containerSize.height - rect.minY
            backgroundContent.update(rect: backgroundFrame, within: containerSize, transition: .immediate)
        }
    }
    
    public func asyncLayout() -> (_ item: ChatNewThreadInfoItem, _ width: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, (ListViewItemUpdateAnimation) -> Void) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makeSubtitleLayout = TextNode.asyncLayout(self.subtitleNode)

        let currentItem = self.item
        
        return { [weak self] item, params in
            let themeUpdated = item.presentationData.theme !== currentItem?.presentationData.theme
                            
            var backgroundSize = CGSize(width: 240.0, height: 0.0)
            
            let verticalItemInset: CGFloat = 10.0
            let horizontalInset: CGFloat = 16.0 + params.leftInset
            let horizontalContentInset: CGFloat = 16.0
            let topInset: CGFloat = 15.0
            let bottomInset: CGFloat = 21.0
            let verticalSpacing: CGFloat = 6.0
            let iconBackgroundSize: CGFloat = 80.0
            let iconTextSpacing: CGFloat = 14.0
            
            let primaryTextColor = serviceMessageColorComponents(theme: item.presentationData.theme.theme, wallpaper: item.presentationData.theme.wallpaper).primaryText
            let subtitleColor = primaryTextColor
            
            backgroundSize.height += topInset
            
            let constrainedWidth = params.width - (horizontalInset + horizontalContentInset) * 2.0
            
            let titleString = item.presentationData.strings.Chat_NewThreadInfo_Title
            let subtitleString = item.presentationData.strings.Chat_NewThreadInfo_Text
            
            backgroundSize.height += iconBackgroundSize
            backgroundSize.height += iconTextSpacing
            
            let titleConstrainedWidth = constrainedWidth
            let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: titleString, font: Font.semibold(15.0), textColor: primaryTextColor), backgroundColor: nil, maximumNumberOfLines: 3, truncationType: .end, constrainedSize: CGSize(width: titleConstrainedWidth, height: CGFloat.greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: UIEdgeInsets()))
            backgroundSize.height += titleLayout.size.height
            backgroundSize.height += verticalSpacing
            
            let (subtitleLayout, subtitleApply) = makeSubtitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: subtitleString, font: Font.regular(13.0), textColor: subtitleColor), backgroundColor: nil, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: titleConstrainedWidth, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, lineSpacing: 0.2, cutout: nil, insets: UIEdgeInsets()))
            backgroundSize.height += subtitleLayout.size.height
            backgroundSize.height += 10.0

            let showsProject = item.controllerInteraction.selectPaiProject != nil && item.isPaiBot
            if showsProject {
                backgroundSize.height += Self.projectRowHeight - 4.0
            }

            backgroundSize.width = horizontalContentInset * 2.0 + max(titleLayout.size.width, subtitleLayout.size.width, showsProject ? 200.0 : 0.0)
            
            backgroundSize.height += bottomInset
         
            let backgroundFrame = CGRect(origin: CGPoint(x: floor((params.width - backgroundSize.width) / 2.0), y: verticalItemInset + 4.0), size: backgroundSize)

            let itemLayout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: backgroundSize.height + verticalItemInset * 2.0 + 10.0), insets: UIEdgeInsets())
            return (itemLayout, { _ in
                if let strongSelf = self {
                    strongSelf.item = item
                    strongSelf.theme = item.presentationData.theme
                    
                    if themeUpdated {
                    }
                    
                    strongSelf.offsetContainer.frame = CGRect(origin: CGPoint(), size: itemLayout.contentSize)
                    
                    var contentOriginY = backgroundFrame.origin.y + topInset
                    
                    let iconBackgroundFrame = CGRect(origin: CGPoint(x: backgroundFrame.minX + floor((backgroundFrame.width - iconBackgroundSize) * 0.5), y: contentOriginY), size: CGSize(width: iconBackgroundSize, height: iconBackgroundSize))
                    strongSelf.iconBackground.frame = iconBackgroundFrame
                    strongSelf.iconBackground.cornerRadius = iconBackgroundSize * 0.5
                    strongSelf.iconBackground.backgroundColor = (item.presentationData.theme.theme.overallDarkAppearance ? UIColor(rgb: 0xffffff, alpha: 0.12) : UIColor(rgb: 0x000000, alpha: 0.12)).cgColor
                    contentOriginY += iconBackgroundSize
                    contentOriginY += iconTextSpacing
                    
                    if strongSelf.iconBackground.superlayer == nil {
                        strongSelf.offsetContainer.layer.addSublayer(strongSelf.iconBackground)
                    }
                    
                    let arrowView: UIImageView
                    if let current = self?.arrowView {
                        arrowView = current
                    } else {
                        arrowView = UIImageView()
                        strongSelf.arrowView = arrowView
                        strongSelf.offsetContainer.view.addSubview(arrowView)
                    }
                    
                    let iconComponent = AnyComponent(BundleIconComponent(
                        name: "Chat/Empty Chat/ChannelMessages",
                        tintColor: primaryTextColor
                    ))
                    let iconSize = strongSelf.icon.update(
                        transition: .immediate,
                        component: iconComponent,
                        environment: {},
                        containerSize: CGSize(width: 50.0, height: 50.0)
                    )
                    let iconFrame = CGRect(origin: CGPoint(x: iconBackgroundFrame.minX + floor((iconBackgroundFrame.width - iconSize.width) * 0.5), y: iconBackgroundFrame.minY + floor((iconBackgroundFrame.height - iconSize.height) * 0.5)), size: iconSize)
                    if let iconView = strongSelf.icon.view {
                        if iconView.superview == nil {
                            strongSelf.offsetContainer.view.addSubview(iconView)
                        }
                        iconView.frame = iconFrame
                    }
                    
                    let _ = titleApply()
                    let titleFrame = CGRect(origin: CGPoint(x: backgroundFrame.origin.x + floor((backgroundSize.width - titleLayout.size.width) / 2.0), y: contentOriginY), size: titleLayout.size)
                    strongSelf.titleNode.frame = titleFrame
                    contentOriginY += titleLayout.size.height
                    contentOriginY += verticalSpacing
                    
                    let _ = subtitleApply()
                    let subtitleFrame = CGRect(origin: CGPoint(x: backgroundFrame.origin.x + floor((backgroundSize.width - subtitleLayout.size.width) / 2.0), y: contentOriginY), size: subtitleLayout.size)
                    strongSelf.subtitleNode.frame = subtitleFrame
                    contentOriginY += subtitleLayout.size.height
                    contentOriginY += 20.0

                    strongSelf.projectButton.isHidden = !showsProject
                    if showsProject {
                        let rowWidth = backgroundSize.width - horizontalContentInset * 2.0
                        strongSelf.projectButton.frame = CGRect(x: backgroundFrame.minX + horizontalContentInset, y: contentOriginY - 6.0, width: rowWidth, height: Self.projectRowHeight)
                        strongSelf.updateProjectButton(width: rowWidth)
                        contentOriginY += Self.projectRowHeight + 12.0
                    }
                    
                    if arrowView.image == nil {
                        arrowView.image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Search/DownButton"), color: .white)?.withRenderingMode(.alwaysTemplate)
                    }
                    arrowView.tintColor = primaryTextColor.withMultipliedAlpha(0.5)
                    arrowView.isHidden = showsProject
                    if let image = arrowView.image {
                        let scaleFactor: CGFloat = 0.8
                        let imageSize = CGSize(width: floor(image.size.width * scaleFactor), height: floor(image.size.height * scaleFactor))
                        let arrowFrame = CGRect(origin: CGPoint(x: backgroundFrame.origin.x + floor((backgroundSize.width - imageSize.width) / 2.0), y: backgroundFrame.minY + backgroundFrame.height - 8.0 - imageSize.height), size: imageSize)
                        arrowView.frame = arrowFrame
                    }
                    
                    if strongSelf.backgroundContent == nil, let backgroundContent = item.controllerInteraction.presentationContext.backgroundNode?.makeBubbleBackground(for: .free) {
                        backgroundContent.clipsToBounds = true
                        strongSelf.backgroundContent = backgroundContent
                        strongSelf.offsetContainer.insertSubnode(backgroundContent, at: 0)
                    }
                    
                    if let backgroundContent = strongSelf.backgroundContent {
                        backgroundContent.cornerRadius = item.presentationData.chatBubbleCorners.mainRadius
                        backgroundContent.frame = backgroundFrame
                        if let (rect, containerSize) = strongSelf.absolutePosition {
                            var backgroundFrame = backgroundContent.frame
                            backgroundFrame.origin.x += rect.minX
                            backgroundFrame.origin.y += containerSize.height - rect.minY
                            backgroundContent.update(rect: backgroundFrame, within: containerSize, transition: .immediate)
                        }
                    }
                }
            })
        }
    }
    
    override public func updateTrailingItemSpace(_ height: CGFloat, transition: ContainedViewLayoutTransition) {
        /*if height.isLessThanOrEqualTo(0.0) {
            transition.updateFrame(node: self.offsetContainer, frame: CGRect(origin: CGPoint(), size: self.offsetContainer.bounds.size))
        } else {
            transition.updateFrame(node: self.offsetContainer, frame: CGRect(origin: CGPoint(x: 0.0, y: -floorToScreenPixels(height / 2.0)), size: self.offsetContainer.bounds.size))
        }*/
    }
    
    override public func animateAdded(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: duration * 0.5)
    }
    
    override public func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: duration * 0.5)
    }
    
    override public func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: duration * 0.5, removeOnCompletion: false)
    }
    
    override public func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let result = super.point(inside: point, with: event)
        let extra = self.offsetContainer.frame.contains(point)
        return result || extra
    }
}
