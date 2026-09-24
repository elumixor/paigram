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

private let iconSize: CGFloat = 20.0
private let rowHeight: CGFloat = 28.0
private let insets = UIEdgeInsets(top: 6.0, left: 12.0, bottom: 4.0, right: 12.0)

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

/// Three dots that pulse one after another while a session works.
private final class DotsNode: ASDisplayNode {
    private let dots = (0..<3).map { _ in ASDisplayNode() }
    private static let dotSize: CGFloat = 5.0
    private static let spacing: CGFloat = 3.0
    static let width = dotSize * 3.0 + spacing * 2.0

    override init() {
        super.init()
        for dot in self.dots {
            dot.cornerRadius = Self.dotSize / 2.0
            self.addSubnode(dot)
        }
    }

    func update(color: UIColor, height: CGFloat) {
        for (index, dot) in self.dots.enumerated() {
            dot.backgroundColor = color
            dot.frame = CGRect(x: CGFloat(index) * (Self.dotSize + Self.spacing), y: (height - Self.dotSize) / 2.0, width: Self.dotSize, height: Self.dotSize)
            if dot.layer.animation(forKey: "pulse") == nil {
                let animation = CAKeyframeAnimation(keyPath: "opacity")
                animation.values = [0.3, 1.0, 0.3]
                animation.keyTimes = [0.0, 0.5, 1.0]
                animation.duration = 0.9
                animation.repeatCount = .infinity
                animation.timeOffset = Double(index) * 0.3
                dot.layer.add(animation, forKey: "pulse")
            }
        }
    }
}

/// What a pai turn did, above its answer, and what a running session is doing right now.
///
/// A message with tool metadata gets one grey line ("Ran 3 commands, read 2 files"); a tap opens
/// the timeline. A status card shows the current tool with typing dots and the elapsed time.
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
            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: false, headerSpacing: 4.0, hidesBackground: .never, forceFullCorners: false, forceAlignment: .none)
            let trailer = PaiTrailer.find(item.message)
            let meta = trailer?.meta
            let tools = meta?.tools ?? []
            let theme = item.presentationData.theme.theme
            let incoming = item.message.effectivelyIncoming(item.context.account.peerId)
            let colors = incoming ? theme.chat.message.incoming : theme.chat.message.outgoing
            let secondary = colors.secondaryTextColor
            let baseSize = item.presentationData.messageFont.pointSize
            let font = Font.regular(floor(baseSize * 14.0 / 17.0))
            let smallFont = Font.regular(floor(baseSize * 13.0 / 17.0))

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
                let textWidth = max(1.0, constrainedSize.width - insets.left - insets.right - (showsActivity ? 30.0 : 0.0))
                let (summaryLayout, summaryApply) = makeSummaryLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: summaryText, font: font, textColor: secondary), backgroundColor: nil, maximumNumberOfLines: 2, truncationType: .end, constrainedSize: CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))

                var rowLayouts: [(TextNodeLayout, () -> TextNode)] = []
                if expanded {
                    for (index, tool) in tools.enumerated() where index < makeRowLayouts.count {
                        rowLayouts.append(makeRowLayouts[index](TextNodeLayoutArguments(attributedString: NSAttributedString(string: PaiToolSummary.title(tool), font: smallFont, textColor: colors.primaryTextColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .middle, constrainedSize: CGSize(width: max(1.0, constrainedSize.width - insets.left - insets.right - iconSize - 10.0), height: rowHeight), alignment: .natural, cutout: nil, insets: UIEdgeInsets())))
                    }
                }

                let width = constrainedSize.width
                return (width, { boundingWidth in
                    let summaryHeight = summaryLayout.size.height
                    let rowsHeight = CGFloat(rowLayouts.count) * rowHeight
                    let size = CGSize(width: boundingWidth, height: insets.top + max(summaryHeight, showsActivity ? 20.0 : 0.0) + (rowLayouts.isEmpty ? 0.0 : 6.0 + rowsHeight) + insets.bottom)

                    return (size, { [weak self] _, _, _ in
                        guard let strongSelf = self else { return }
                        strongSelf.item = item
                        let summaryNode = summaryApply()
                        let summaryX = insets.left + (showsActivity ? 30.0 : 0.0)
                        summaryNode.frame = CGRect(origin: CGPoint(x: summaryX, y: insets.top + (showsActivity ? max(0.0, (20.0 - summaryHeight) / 2.0) : 0.0)), size: summaryLayout.size)

                        strongSelf.dotsNode.isHidden = !showsActivity
                        if showsActivity {
                            strongSelf.dotsNode.frame = CGRect(x: insets.left, y: insets.top, width: DotsNode.width, height: 20.0)
                            strongSelf.dotsNode.update(color: colors.primaryTextColor.withAlphaComponent(0.8), height: 20.0)
                        }
                        strongSelf.updateTicking(meta: meta)

                        strongSelf.lineNode.backgroundColor = secondary.withAlphaComponent(0.25)
                        strongSelf.lineNode.isHidden = rowLayouts.count < 2
                        var y = insets.top + summaryHeight + 6.0
                        for (index, (rowLayout, rowApply)) in rowLayouts.enumerated() {
                            let row = strongSelf.rowNodes[index]
                            row.frame = CGRect(x: insets.left, y: y, width: boundingWidth - insets.left - insets.right, height: rowHeight)
                            row.iconNode.image = UIImage(systemName: PaiToolSummary.symbol(tools[index]), withConfiguration: UIImage.SymbolConfiguration(pointSize: 14.0, weight: .regular))?.withTintColor(secondary, renderingMode: .alwaysOriginal)
                            row.iconNode.frame = CGRect(x: 0.0, y: (rowHeight - iconSize) / 2.0, width: iconSize, height: iconSize)
                            let textNode = rowApply()
                            textNode.frame = CGRect(origin: CGPoint(x: iconSize + 10.0, y: (rowHeight - rowLayout.size.height) / 2.0), size: rowLayout.size)
                            y += rowHeight
                        }
                        if rowLayouts.count >= 2 {
                            let top = insets.top + summaryHeight + 6.0 + rowHeight / 2.0
                            strongSelf.lineNode.frame = CGRect(x: insets.left + iconSize / 2.0 - 0.5, y: top, width: 1.0, height: CGFloat(rowLayouts.count - 1) * rowHeight)
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
