import AsyncDisplayKit
import ChatControllerInteraction
import ChatMessageBubbleContentNode
import ChatMessageItemCommon
import Display
import Foundation
import PaiUI
import Postbox
import TelegramCore
import TelegramPresentationData
import UIKit

private let pillInsets = UIEdgeInsets(top: 3.0, left: 10.0, bottom: 3.0, right: 10.0)
private let iconGap: CGFloat = 5.0
private let errorColor = UIColor(rgb: 0xff6961)

/// One line of the feed drawn once, off the main thread: the symbol, then the text, cut to fit.
func paiLineImage(symbol: String?, trailingSymbol: String? = nil, text: String, font: UIFont, color: UIColor, maxWidth: CGFloat) -> UIImage? {
    let configuration = UIImage.SymbolConfiguration(font: font)
    let icon = symbol.flatMap { UIImage(systemName: $0, withConfiguration: configuration) ?? UIImage(systemName: "bell", withConfiguration: configuration) }?.withTintColor(color, renderingMode: .alwaysOriginal)
    let trailing = trailingSymbol.flatMap { UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: font.pointSize * 0.75, weight: .semibold)) }?.withTintColor(color, renderingMode: .alwaysOriginal)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    let iconWidth = icon.map { $0.size.width + iconGap } ?? 0.0
    let trailingWidth = trailing.map { $0.size.width + iconGap } ?? 0.0
    let textWidth = min(ceil(string.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: font.lineHeight), options: [.usesLineFragmentOrigin], context: nil).width), max(1.0, maxWidth - iconWidth - trailingWidth))
    let size = CGSize(width: ceil(iconWidth + textWidth + trailingWidth), height: ceil(font.lineHeight))
    guard size.width > 0.0 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreenScale
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        if let icon {
            icon.draw(in: CGRect(origin: CGPoint(x: 0.0, y: floor((size.height - icon.size.height) / 2.0)), size: icon.size))
        }
        string.draw(with: CGRect(x: iconWidth, y: 0.0, width: textWidth, height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        if let trailing {
            trailing.draw(in: CGRect(origin: CGPoint(x: iconWidth + textWidth + iconGap, y: floor((size.height - trailing.size.height) / 2.0)), size: trailing.size))
        }
    }
}

/// pai's service rows, the way Telegram shows "joined the group": centered, grey, no bubble, the event's symbol
/// first. A run of them (or an `events` message) folds into "5 events: 2 routines, 3 emails" and opens on tap;
/// an event about an agent opens that agent's chat; errors are red.
public final class ChatMessagePaiEventBubbleContentNode: ChatMessageBubbleContentNode {
    private let pillNode = ASDisplayNode()
    private var lineNodes: [ASImageNode] = []
    /// What each drawn line is, top to bottom, with its frame; the header of a fold has no event.
    private var hitLines: [(CGRect, PaiEventLine?)] = []

    required public init() {
        super.init()
        self.pillNode.isLayerBacked = true
        self.addSubnode(self.pillNode)
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, CGSize?, CGFloat, (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        return { item, _, _, _, _, _ in
            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: true, headerSpacing: 0.0, hidesBackground: .always, forceFullCorners: false, forceAlignment: .center, hidesHeaders: true)

            return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, { constrainedSize, _ in
                let theme = item.presentationData.theme
                let service = serviceMessageColorComponents(theme: theme.theme, wallpaper: theme.wallpaper)
                let font = Font.regular(floor(item.presentationData.messageFont.pointSize * 13.0 / 17.0))
                let maxWidth = max(1.0, constrainedSize.width - 40.0 - pillInsets.left - pillInsets.right)

                let lines = PaiEventFold.run(item.message)
                let folded = lines.count > 1
                let expanded = folded && PaiEventFold.isExpanded(item.message.id)
                var drawn: [(UIImage?, PaiEventLine?)] = []
                if folded {
                    drawn.append((paiLineImage(symbol: "square.stack", trailingSymbol: expanded ? "chevron.up" : "chevron.down", text: PaiEventFold.summary(lines), font: font, color: service.primaryText, maxWidth: maxWidth), nil))
                }
                if !folded || expanded {
                    for line in lines {
                        drawn.append((paiLineImage(symbol: line.symbol, text: line.text, font: font, color: line.isError ? errorColor : service.primaryText, maxWidth: maxWidth), line))
                    }
                }

                let lineHeight = ceil(font.lineHeight) + 4.0
                let contentWidth = drawn.compactMap { $0.0?.size.width }.max() ?? 0.0
                let pillSize = CGSize(width: contentWidth + pillInsets.left + pillInsets.right, height: CGFloat(drawn.count) * lineHeight + pillInsets.top + pillInsets.bottom)

                return (pillSize.width, { boundingWidth in
                    let size = CGSize(width: boundingWidth, height: pillSize.height + 4.0)
                    return (size, { [weak self] _, _, _ in
                        guard let self else { return }
                        self.item = item

                        let pillFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((boundingWidth - pillSize.width) / 2.0), y: 2.0), size: pillSize)
                        self.pillNode.frame = pillFrame
                        self.pillNode.backgroundColor = service.fill
                        self.pillNode.cornerRadius = drawn.count == 1 ? pillSize.height / 2.0 : 12.0

                        while self.lineNodes.count < drawn.count {
                            let node = ASImageNode()
                            node.displaysAsynchronously = false
                            node.isLayerBacked = true
                            self.lineNodes.append(node)
                            self.addSubnode(node)
                        }
                        var hitLines: [(CGRect, PaiEventLine?)] = []
                        for (index, node) in self.lineNodes.enumerated() {
                            guard index < drawn.count, let image = drawn[index].0 else {
                                node.isHidden = true
                                continue
                            }
                            node.isHidden = false
                            node.image = image
                            let row = CGRect(x: pillFrame.minX, y: pillFrame.minY + pillInsets.top + CGFloat(index) * lineHeight, width: pillFrame.width, height: lineHeight)
                            // A fold's own lines sit left in its box; a single line is centered like any service message.
                            let x = drawn.count == 1 ? floorToScreenPixels((boundingWidth - image.size.width) / 2.0) : pillFrame.minX + pillInsets.left
                            node.frame = CGRect(origin: CGPoint(x: x, y: row.minY + floorToScreenPixels((lineHeight - image.size.height) / 2.0)), size: image.size)
                            hitLines.append((row, drawn[index].1))
                        }
                        self.hitLines = hitLines
                    })
                })
            })
        }
    }

    override public func tapActionAtPoint(_ point: CGPoint, gesture: TapLongTapOrDoubleTapGesture, isEstimating: Bool) -> ChatMessageBubbleContentTapAction {
        guard let item = self.item, let hit = self.hitLines.first(where: { $0.0.contains(point) }) else {
            return ChatMessageBubbleContentTapAction(content: .none)
        }
        let isFold = self.hitLines.count > 1 || PaiEventFold.run(item.message).count > 1
        guard let line = hit.1 else {
            // The fold's header: open or close it.
            guard isFold else { return ChatMessageBubbleContentTapAction(content: .none) }
            return ChatMessageBubbleContentTapAction(content: .custom({ [weak self] in
                guard let self, let item = self.item else { return }
                PaiEventFold.toggle(item.message.id)
                self.requestInlineUpdate?()
            }))
        }
        guard line.agent != nil || line.thread != nil else {
            return ChatMessageBubbleContentTapAction(content: .none)
        }
        return ChatMessageBubbleContentTapAction(content: .custom({ [weak item] in
            item?.controllerInteraction.openPaiAgent?(line.agent, line.thread)
        }))
    }
}
