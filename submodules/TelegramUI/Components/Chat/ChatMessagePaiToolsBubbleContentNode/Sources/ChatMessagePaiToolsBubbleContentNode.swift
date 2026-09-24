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
private let pillInsets = UIEdgeInsets(top: 5.0, left: 12.0, bottom: 5.0, right: 12.0)
private let outerInsets = UIEdgeInsets(top: 2.0, left: 8.0, bottom: 2.0, right: 8.0)
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

/// What a pai turn did, and what a running session is doing right now, as a service-style pill.
///
/// A message with tool metadata gets the pill above its bubble ("Ran 3 commands, read 2 files"); a tap
/// opens the timeline. A status card is nothing but the pill: the current tool with a pulse and the
/// elapsed time while a turn runs, one word once it is over.
public final class ChatMessagePaiToolsBubbleContentNode: ChatMessageBubbleContentNode {
    private let pillNode = ASDisplayNode()
    private let summaryNode = TextNode()
    private let dotsNode = DotsNode()
    private let lineNode = ASDisplayNode()
    private var rowNodes: [ToolRowNode] = []
    private var expanded = false
    private var timer: SwiftSignalKit.Timer?

    required public init() {
        super.init()
        self.addSubnode(self.pillNode)
        self.pillNode.addSubnode(self.summaryNode)
        self.pillNode.addSubnode(self.dotsNode)
        self.pillNode.addSubnode(self.lineNode)
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
            // Metadata sits above the bubble; a status card has no bubble at all.
            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: true, headerSpacing: 0.0, hidesBackground: isStatus ? .always : .never, forceFullCorners: false, forceAlignment: isStatus ? .center : .none, hidesHeaders: isStatus, isDetached: !isStatus)
            let colors = serviceMessageColorComponents(theme: item.presentationData.theme.theme, wallpaper: item.presentationData.theme.wallpaper)
            let baseSize = item.presentationData.messageFont.pointSize
            let font = Font.regular(floor(baseSize * 13.0 / 17.0))
            let smallFont = Font.regular(floor(baseSize * 12.0 / 17.0))

            let summaryText: String
            let showsActivity: Bool
            if let meta, meta.isStatus {
                showsActivity = meta.isBusy
                summaryText = Self.statusText(meta)
            } else {
                showsActivity = false
                summaryText = PaiToolSummary.line(tools)
            }

            return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, { constrainedSize, _ in
                let maxTextWidth = max(1.0, constrainedSize.width - outerInsets.left - outerInsets.right - pillInsets.left - pillInsets.right - (showsActivity ? DotsNode.width + dotsGap : 0.0))
                let (summaryLayout, summaryApply) = makeSummaryLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: summaryText, font: font, textColor: colors.primaryText), backgroundColor: nil, maximumNumberOfLines: 2, truncationType: .end, constrainedSize: CGSize(width: maxTextWidth, height: CGFloat.greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: UIEdgeInsets()))

                var rowLayouts: [(TextNodeLayout, () -> TextNode)] = []
                if expanded {
                    for (index, tool) in tools.enumerated() where index < makeRowLayouts.count {
                        rowLayouts.append(makeRowLayouts[index](TextNodeLayoutArguments(attributedString: NSAttributedString(string: PaiToolSummary.title(tool), font: smallFont, textColor: colors.primaryText), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .middle, constrainedSize: CGSize(width: max(1.0, maxTextWidth - iconSize - 8.0), height: rowHeight), alignment: .natural, cutout: nil, insets: UIEdgeInsets())))
                    }
                }

                let headerWidth = summaryLayout.size.width + (showsActivity ? DotsNode.width + dotsGap : 0.0)
                let rowsWidth = rowLayouts.map { $0.0.size.width + iconSize + 8.0 }.max() ?? 0.0
                let pillWidth = max(headerWidth, rowsWidth) + pillInsets.left + pillInsets.right
                let headerHeight = max(summaryLayout.size.height, showsActivity ? 18.0 : 0.0)
                let rowsHeight = rowLayouts.isEmpty ? 0.0 : 6.0 + CGFloat(rowLayouts.count) * rowHeight
                let pillHeight = pillInsets.top + headerHeight + rowsHeight + pillInsets.bottom
                let size = CGSize(width: pillWidth + outerInsets.left + outerInsets.right, height: pillHeight + outerInsets.top + outerInsets.bottom)

                return (size.width, { boundingWidth in
                    return (CGSize(width: boundingWidth, height: size.height), { [weak self] _, _, _ in
                        guard let strongSelf = self else { return }
                        strongSelf.item = item

                        let pillFrame = CGRect(x: floor((boundingWidth - pillWidth) / 2.0), y: outerInsets.top, width: pillWidth, height: pillHeight)
                        strongSelf.pillNode.frame = pillFrame
                        strongSelf.pillNode.backgroundColor = colors.fill
                        strongSelf.pillNode.cornerRadius = min(14.0, pillHeight / 2.0)

                        let contentLeft = pillInsets.left + (pillWidth - pillInsets.left - pillInsets.right - headerWidth) / 2.0
                        let summaryNode = summaryApply()
                        summaryNode.frame = CGRect(origin: CGPoint(x: contentLeft + (showsActivity ? DotsNode.width + dotsGap : 0.0), y: pillInsets.top + (headerHeight - summaryLayout.size.height) / 2.0), size: summaryLayout.size)

                        strongSelf.dotsNode.isHidden = !showsActivity
                        if showsActivity {
                            strongSelf.dotsNode.frame = CGRect(x: contentLeft, y: pillInsets.top, width: DotsNode.width, height: headerHeight)
                            strongSelf.dotsNode.update(color: colors.primaryText)
                        }
                        strongSelf.updateTicking(meta: meta)

                        strongSelf.lineNode.backgroundColor = colors.primaryText.withAlphaComponent(0.25)
                        strongSelf.lineNode.isHidden = rowLayouts.count < 2
                        var y = pillInsets.top + headerHeight + 6.0
                        for (index, (rowLayout, rowApply)) in rowLayouts.enumerated() {
                            let row = strongSelf.rowNodes[index]
                            row.frame = CGRect(x: pillInsets.left, y: y, width: pillWidth - pillInsets.left - pillInsets.right, height: rowHeight)
                            row.iconNode.image = UIImage(systemName: PaiToolSummary.symbol(tools[index]), withConfiguration: UIImage.SymbolConfiguration(pointSize: 12.0, weight: .regular))?.withTintColor(colors.primaryText, renderingMode: .alwaysOriginal)
                            row.iconNode.frame = CGRect(x: 0.0, y: (rowHeight - iconSize) / 2.0, width: iconSize, height: iconSize)
                            let textNode = rowApply()
                            textNode.frame = CGRect(origin: CGPoint(x: iconSize + 8.0, y: (rowHeight - rowLayout.size.height) / 2.0), size: rowLayout.size)
                            y += rowHeight
                        }
                        if rowLayouts.count >= 2 {
                            let top = pillInsets.top + headerHeight + 6.0 + rowHeight / 2.0
                            strongSelf.lineNode.frame = CGRect(x: pillInsets.left + iconSize / 2.0 - 0.5, y: top, width: 1.0, height: CGFloat(rowLayouts.count - 1) * rowHeight)
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
            return "\(doing)… · \(Self.elapsed(meta))"
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
            self.pillNode.addSubnode(row)
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
