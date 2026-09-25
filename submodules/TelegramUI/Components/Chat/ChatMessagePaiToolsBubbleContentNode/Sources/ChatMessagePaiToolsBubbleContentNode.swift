import AsyncDisplayKit
import ChatMessageBubbleContentNode
import ChatMessageItemCommon
import Display
import Foundation
import PaiUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

private let iconSize: CGFloat = 18.0
private let rowHeight: CGFloat = 26.0
private let outerInsets = UIEdgeInsets(top: 3.0, left: 0.0, bottom: 3.0, right: 8.0)
private let dotsGap: CGFloat = 6.0

/// A row of the expanded timeline: the tool's icon and what it did.
private final class ToolRowNode: ASDisplayNode {
    let iconNode = ASImageNode()
    let textNode = TextNode()

    override init() {
        super.init()
        self.iconNode.displaysAsynchronously = false
        self.iconNode.contentMode = .scaleAspectFit
        self.addSubnode(self.iconNode)
        self.addSubnode(self.textNode)
    }
}

/// An ellipsis that breathes while a session works.
private final class DotsNode: ASImageNode {
    static let width: CGFloat = 20.0

    override init() {
        super.init()
        self.displaysAsynchronously = false
        self.contentMode = .center
    }

    func update(color: UIColor) {
        self.image = UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14.0, weight: .bold))?.withTintColor(color, renderingMode: .alwaysOriginal)
        if self.layer.animation(forKey: "pulse") == nil {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0.25, 1.0, 0.25]
            animation.keyTimes = [0.0, 0.5, 1.0]
            animation.duration = 1.2
            animation.repeatCount = .infinity
            self.layer.add(animation, forKey: "pulse")
        }
    }
}

/// What a pai turn did, and what a running session is doing right now, as a quiet line of text.
///
/// A message with tool metadata gets the line above its bubble, flush with the bubble's text ("Ran 3 commands,
/// read 2 files"); a tap opens the timeline under it. A status card is nothing but the line: the current tool
/// with a pulse and the elapsed time while a turn runs, one word once it is over. No bubble, no pill.
public final class ChatMessagePaiToolsBubbleContentNode: ChatMessageBubbleContentNode {
    private let summaryNode = TextNode()
    private let dotsNode = DotsNode()
    private let lineNode = ASDisplayNode()
    private var rowNodes: [ToolRowNode] = []
    private var expanded = false
    private var timer: SwiftSignalKit.Timer?

    required public init() {
        super.init()
        self.addSubnode(self.summaryNode)
        self.addSubnode(self.dotsNode)
        self.addSubnode(self.lineNode)
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.timer?.invalidate()
    }

    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, CGSize?, CGFloat, (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        let makeSummaryLayout = TextNode.asyncLayout(self.summaryNode)
        let expanded = self.expanded
        let makeRowLayouts = self.rowNodes.map { TextNode.asyncLayout($0.textNode) }

        return { item, layoutConstants, _, _, constrainedSize, _ in
            let trailer = PaiTrailer.find(item.message)
            let meta = trailer?.meta
            let tools = meta?.tools ?? []
            let isStatus = meta?.isStatus ?? false
            // Metadata sits above the bubble; a status card is a bare line at the bubble's place, no background.
            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: true, headerSpacing: 0.0, hidesBackground: isStatus ? .always : .never, forceFullCorners: false, forceAlignment: .none, hidesHeaders: isStatus, isDetached: !isStatus)
            let textColor = item.presentationData.theme.theme.chat.message.incoming.secondaryTextColor
            let baseSize = item.presentationData.messageFont.pointSize
            let font = Font.regular(floor(baseSize * 14.0 / 17.0))
            let smallFont = Font.regular(floor(baseSize * 13.0 / 17.0))
            let leftInset: CGFloat = isStatus ? layoutConstants.text.bubbleInsets.left : 0.0

            let summaryText: String
            let showsActivity: Bool
            if let meta, meta.isStatus {
                showsActivity = meta.isBusy
                summaryText = Self.statusText(meta)
            } else {
                showsActivity = false
                summaryText = PaiToolSummary.line(tools)
            }
            let dotsWidth = showsActivity ? DotsNode.width + dotsGap : 0.0

            return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, { constrainedSize, _ in
                let maxTextWidth = max(1.0, constrainedSize.width - leftInset - dotsWidth)
                let (summaryLayout, summaryApply) = makeSummaryLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: summaryText, font: font, textColor: textColor), backgroundColor: nil, maximumNumberOfLines: 2, truncationType: .end, constrainedSize: CGSize(width: maxTextWidth, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))

                var rowLayouts: [(TextNodeLayout, () -> TextNode)] = []
                if expanded {
                    for (index, tool) in tools.enumerated() where index < makeRowLayouts.count {
                        rowLayouts.append(makeRowLayouts[index](TextNodeLayoutArguments(attributedString: NSAttributedString(string: PaiToolSummary.title(tool), font: smallFont, textColor: textColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .middle, constrainedSize: CGSize(width: max(1.0, maxTextWidth - iconSize - 8.0), height: rowHeight), alignment: .natural, cutout: nil, insets: UIEdgeInsets())))
                    }
                }

                let headerWidth = summaryLayout.size.width + dotsWidth
                let rowsWidth = rowLayouts.map { $0.0.size.width + iconSize + 8.0 }.max() ?? 0.0
                let headerHeight = max(summaryLayout.size.height, showsActivity ? 18.0 : 0.0)
                let rowsHeight = rowLayouts.isEmpty ? 0.0 : 6.0 + CGFloat(rowLayouts.count) * rowHeight
                let size = CGSize(width: leftInset + max(headerWidth, rowsWidth) + outerInsets.right, height: outerInsets.top + headerHeight + rowsHeight + outerInsets.bottom)

                return (size.width, { _ in
                    return (size, { [weak self] _, _, _ in
                        guard let strongSelf = self else { return }
                        strongSelf.item = item

                        let summaryNode = summaryApply()
                        summaryNode.frame = CGRect(origin: CGPoint(x: leftInset + dotsWidth, y: outerInsets.top + (headerHeight - summaryLayout.size.height) / 2.0), size: summaryLayout.size)

                        strongSelf.dotsNode.isHidden = !showsActivity
                        if showsActivity {
                            strongSelf.dotsNode.frame = CGRect(x: leftInset, y: outerInsets.top, width: DotsNode.width, height: headerHeight)
                            strongSelf.dotsNode.update(color: textColor)
                        }
                        strongSelf.updateTicking(meta: meta)

                        strongSelf.lineNode.backgroundColor = textColor.withAlphaComponent(0.25)
                        strongSelf.lineNode.isHidden = rowLayouts.count < 2
                        var y = outerInsets.top + headerHeight + 6.0
                        for (index, (rowLayout, rowApply)) in rowLayouts.enumerated() {
                            let row = strongSelf.rowNodes[index]
                            row.frame = CGRect(x: leftInset, y: y, width: size.width - leftInset, height: rowHeight)
                            row.iconNode.image = UIImage(systemName: PaiToolSummary.symbol(tools[index]), withConfiguration: UIImage.SymbolConfiguration(pointSize: 12.0, weight: .regular))?.withTintColor(textColor, renderingMode: .alwaysOriginal)
                            row.iconNode.frame = CGRect(x: 0.0, y: (rowHeight - iconSize) / 2.0, width: iconSize, height: iconSize)
                            let textNode = rowApply()
                            textNode.frame = CGRect(origin: CGPoint(x: iconSize + 8.0, y: (rowHeight - rowLayout.size.height) / 2.0), size: rowLayout.size)
                            y += rowHeight
                        }
                        if rowLayouts.count >= 2 {
                            let top = outerInsets.top + headerHeight + 6.0 + rowHeight / 2.0
                            strongSelf.lineNode.frame = CGRect(x: leftInset + iconSize / 2.0 - 0.5, y: top, width: 1.0, height: CGFloat(rowLayouts.count - 1) * rowHeight)
                        }
                    })
                })
            })
        }
    }

    private static func statusText(_ meta: PaiRichMeta) -> String {
        if meta.isWaiting { return "Waiting for your answer" }
        if meta.isBusy {
            let doing = meta.tool.map { $0.hasPrefix("$ ") ? "Running \($0.dropFirst(2))" : $0 } ?? "Thinking"
            let elapsed = Self.elapsed(meta)
            return elapsed.isEmpty ? "\(doing)…" : "\(doing)… · \(elapsed)"
        }
        switch meta.state {
        case "dead": return "Ended"
        case "error": return "Failed"
        default: return "Done"
        }
    }

    private static func elapsed(_ meta: PaiRichMeta) -> String {
        guard let startedAt = meta.startedAt else { return "" }
        let seconds = max(0, Int(Date().timeIntervalSince1970 - startedAt / 1000))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    /// While a session is busy the elapsed time keeps counting, so the line is relaid out every second.
    private func updateTicking(meta: PaiRichMeta?) {
        if let meta, meta.isStatus, meta.isBusy, meta.startedAt != nil {
            if self.timer == nil {
                let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: true, completion: { [weak self] in
                    self?.requestInlineUpdate?()
                }, queue: Queue.mainQueue())
                self.timer = timer
                timer.start()
            }
        } else {
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    /// Row nodes are created here, before layout, so `asyncLayoutContent` can prepare their text layouts.
    override public func didLoad() {
        super.didLoad()
        self.ensureRows()
    }

    private func ensureRows() {
        let count = self.item.flatMap { PaiTrailer.find($0.message)?.meta.tools?.count } ?? 0
        while self.rowNodes.count < count {
            let row = ToolRowNode()
            self.rowNodes.append(row)
            self.addSubnode(row)
        }
        for (index, row) in self.rowNodes.enumerated() { row.isHidden = !self.expanded || index >= count }
    }

    override public func tapActionAtPoint(_ point: CGPoint, gesture: TapLongTapOrDoubleTapGesture, isEstimating: Bool) -> ChatMessageBubbleContentTapAction {
        guard self.bounds.contains(point), let item = self.item, let meta = PaiTrailer.find(item.message)?.meta, !meta.isStatus, !(meta.tools ?? []).isEmpty else {
            return ChatMessageBubbleContentTapAction(content: .none)
        }
        return ChatMessageBubbleContentTapAction(content: .custom({ [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.expanded.toggle()
            strongSelf.ensureRows()
            strongSelf.requestInlineUpdate?()
        }))
    }
}
