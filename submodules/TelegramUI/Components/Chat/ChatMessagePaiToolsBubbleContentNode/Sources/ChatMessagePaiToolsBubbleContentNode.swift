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
private let clockSize: CGFloat = 12.0
private let outerInsets = UIEdgeInsets(top: 3.0, left: 0.0, bottom: 3.0, right: 8.0)
private let dotsGap: CGFloat = 5.0
/// A row where pai tended its own setup (memory, staff, routines, its task list) rather than the task at hand.
private let housekeepingColor = UIColor(red: 0.55, green: 0.35, blue: 0.95, alpha: 1.0)

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

/// The thinking mark: a four-point spark that turns and breathes while a session works.
private final class SparkNode: ASImageNode {
    static let width: CGFloat = 18.0

    override init() {
        super.init()
        self.displaysAsynchronously = false
        self.contentMode = .center
    }

    func update(color: UIColor) {
        self.image = UIImage(systemName: "sparkle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12.0, weight: .semibold))?.withTintColor(color, renderingMode: .alwaysOriginal)
        if self.layer.animation(forKey: "spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0.0
            spin.toValue = Double.pi * 2.0
            spin.duration = 2.4
            spin.repeatCount = .infinity
            self.layer.add(spin, forKey: "spin")
            let breathe = CAKeyframeAnimation(keyPath: "transform.scale")
            breathe.values = [0.8, 1.15, 0.8]
            breathe.keyTimes = [0.0, 0.5, 1.0]
            breathe.duration = 1.2
            breathe.repeatCount = .infinity
            self.layer.add(breathe, forKey: "breathe")
        }
    }
}

/// A line of quiet text that stays readable on any wallpaper: a halo in the bubble's colour behind the glyphs.
private func haloed(_ node: ASDisplayNode, color: UIColor) {
    node.layer.shadowColor = color.cgColor
    node.layer.shadowOpacity = 0.9
    node.layer.shadowRadius = 2.0
    node.layer.shadowOffset = .zero
}

/// What a pai turn did, and what a running session is doing right now, as quiet lines around the bubble.
///
/// Above the bubble: "Used 3 tools" for a finished turn (a tap opens the timeline), or the spark with the
/// current tool and the elapsed time while a turn runs (its tools so far open the same way). Below the
/// bubble: a clock and "5s". A status card is nothing but the line above; no bubble, no pill.
public final class ChatMessagePaiToolsBubbleContentNode: ChatMessageBubbleContentNode {
    /// Where the bubble ends, in this node's coordinates; the item node sets it before layout applies.
    public var bubbleBottom: CGFloat = 0.0

    private let summaryNode = TextNode()
    private let footerNode = TextNode()
    private let clockNode = ASImageNode()
    private let sparkNode = SparkNode()
    private let lineNode = ASDisplayNode()
    private let stopNode = ASImageNode()
    private var rowNodes: [ToolRowNode] = []
    private var expanded = false
    private var timer: SwiftSignalKit.Timer?
    private var headerHeight: CGFloat = 0.0

    required public init() {
        super.init()
        self.addSubnode(self.summaryNode)
        self.addSubnode(self.footerNode)
        self.clockNode.displaysAsynchronously = false
        self.clockNode.isLayerBacked = true
        self.addSubnode(self.clockNode)
        self.addSubnode(self.sparkNode)
        self.addSubnode(self.lineNode)
        self.stopNode.displaysAsynchronously = false
        self.stopNode.isLayerBacked = true
        self.addSubnode(self.stopNode)
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.timer?.invalidate()
    }

    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, CGSize?, CGFloat, (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        let makeSummaryLayout = TextNode.asyncLayout(self.summaryNode)
        let makeFooterLayout = TextNode.asyncLayout(self.footerNode)
        let expanded = self.expanded
        let makeRowLayouts = self.rowNodes.map { TextNode.asyncLayout($0.textNode) }

        return { item, layoutConstants, _, _, constrainedSize, _ in
            let trailer = PaiTrailer.find(item.message)
            let meta = trailer?.meta
            let tools = meta?.tools ?? []
            let isStatus = meta?.isStatus ?? false
            let theme = item.presentationData.theme.theme
            let textColor = theme.chat.message.incoming.primaryTextColor.withAlphaComponent(0.75)
            // A row that leads somewhere (a follow-up into another thread) gets the bubble's own accent,
            // not the dimmed status tint — real contrast, the way a delegation card's title reads.
            let accentColor = theme.chat.message.incoming.accentTextColor
            let haloColor = theme.chat.message.incoming.bubble.withWallpaper.fill.first ?? theme.list.plainBackgroundColor
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
            // A turn that was entirely pai tending its own setup reads that way even collapsed, not as plain work.
            let allHousekeeping = !isStatus && !tools.isEmpty && tools.allSatisfy(PaiToolSummary.isHousekeeping)
            let soleFollowUp = !isStatus && tools.count == 1 ? PaiToolSummary.followUpTarget(tools[0]) : nil
            let summaryColor = soleFollowUp != nil ? accentColor : allHousekeeping ? housekeepingColor : textColor
            let footerText = isStatus ? "" : Self.footerText(meta)
            let clockWidth: CGFloat = footerText.isEmpty ? 0.0 : clockSize + 3.0
            let sparkWidth = showsActivity ? SparkNode.width + dotsGap : 0.0
            // A running session can be interrupted from its own status line; a finished one has nothing to stop.
            let canStop = showsActivity
            let stopWidth: CGFloat = canStop ? iconSize + dotsGap : 0.0
            let footerGap: CGFloat = 3.0

            let belowHeight: CGFloat = footerText.isEmpty ? 0.0 : footerGap + font.pointSize + 6.0
            // Metadata sits above the bubble and the footer below it; a status card is a bare line at the bubble's place.
            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: true, headerSpacing: 0.0, hidesBackground: isStatus ? .always : .never, forceFullCorners: false, forceAlignment: .none, hidesHeaders: isStatus, isDetached: !isStatus, detachedBottomHeight: belowHeight)

            return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, { constrainedSize, _ in
                let maxTextWidth = max(1.0, constrainedSize.width - leftInset - sparkWidth)
                let (summaryLayout, summaryApply) = makeSummaryLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: summaryText, font: font, textColor: summaryColor), backgroundColor: nil, maximumNumberOfLines: 2, truncationType: .end, constrainedSize: CGSize(width: maxTextWidth, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
                let (footerLayout, footerApply) = makeFooterLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: footerText, font: font, textColor: textColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(1.0, constrainedSize.width), height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))

                var rowLayouts: [(TextNodeLayout, () -> TextNode)] = []
                if expanded {
                    for (index, tool) in tools.enumerated() where index < makeRowLayouts.count {
                        let rowColor = PaiToolSummary.followUpTarget(tool) != nil ? accentColor : PaiToolSummary.isHousekeeping(tool) ? housekeepingColor : textColor
                        rowLayouts.append(makeRowLayouts[index](TextNodeLayoutArguments(attributedString: NSAttributedString(string: PaiToolSummary.title(tool), font: smallFont, textColor: rowColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .middle, constrainedSize: CGSize(width: max(1.0, maxTextWidth - iconSize - 8.0), height: rowHeight), alignment: .natural, cutout: nil, insets: UIEdgeInsets())))
                    }
                }

                let hasHeader = !summaryText.isEmpty
                let headerWidth = summaryLayout.size.width + sparkWidth + stopWidth
                let rowsWidth = rowLayouts.map { $0.0.size.width + iconSize + 8.0 }.max() ?? 0.0
                let headerHeight = hasHeader ? max(summaryLayout.size.height, showsActivity ? 18.0 : 0.0) : 0.0
                let rowsHeight = rowLayouts.isEmpty ? 0.0 : 6.0 + CGFloat(rowLayouts.count) * rowHeight
                let aboveHeight = hasHeader ? outerInsets.top + headerHeight + rowsHeight + outerInsets.bottom : 0.0
                let size = CGSize(width: leftInset + max(headerWidth, rowsWidth, clockWidth + footerLayout.size.width) + outerInsets.right, height: aboveHeight + belowHeight)

                return (size.width, { _ in
                    return (size, { [weak self] _, _, _ in
                        guard let strongSelf = self else { return }
                        strongSelf.item = item
                        strongSelf.headerHeight = aboveHeight

                        let summaryNode = summaryApply()
                        summaryNode.isHidden = !hasHeader
                        summaryNode.frame = CGRect(origin: CGPoint(x: leftInset + sparkWidth, y: outerInsets.top + (headerHeight - summaryLayout.size.height) / 2.0), size: summaryLayout.size)
                        haloed(summaryNode, color: haloColor)

                        let footerNode = footerApply()
                        footerNode.isHidden = footerText.isEmpty
                        footerNode.frame = CGRect(origin: CGPoint(x: leftInset + clockWidth, y: strongSelf.bubbleBottom + footerGap), size: footerLayout.size)
                        haloed(footerNode, color: haloColor)
                        strongSelf.clockNode.isHidden = footerText.isEmpty
                        if !footerText.isEmpty {
                            strongSelf.clockNode.image = UIImage(systemName: "clock", withConfiguration: UIImage.SymbolConfiguration(pointSize: clockSize - 1.0, weight: .medium))?.withTintColor(textColor, renderingMode: .alwaysOriginal)
                            strongSelf.clockNode.frame = CGRect(x: leftInset, y: footerNode.frame.midY - clockSize / 2.0, width: clockSize, height: clockSize)
                        }

                        strongSelf.sparkNode.isHidden = !showsActivity
                        if showsActivity {
                            strongSelf.sparkNode.frame = CGRect(x: leftInset, y: outerInsets.top, width: SparkNode.width, height: headerHeight)
                            strongSelf.sparkNode.update(color: textColor)
                        } else {
                            strongSelf.sparkNode.layer.removeAllAnimations()
                        }
                        strongSelf.updateTicking(meta: meta)

                        strongSelf.stopNode.isHidden = !canStop
                        if canStop {
                            let stopColor = UIColor(red: 0.96, green: 0.29, blue: 0.27, alpha: 1.0)
                            strongSelf.stopNode.image = UIImage(systemName: "stop.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .regular))?.withTintColor(stopColor, renderingMode: .alwaysOriginal)
                            strongSelf.stopNode.frame = CGRect(x: leftInset + sparkWidth + summaryLayout.size.width + dotsGap, y: outerInsets.top + (headerHeight - iconSize) / 2.0, width: iconSize, height: iconSize)
                            haloed(strongSelf.stopNode, color: haloColor)
                        }

                        strongSelf.lineNode.backgroundColor = textColor.withAlphaComponent(0.25)
                        strongSelf.lineNode.isHidden = rowLayouts.count < 2
                        var y = outerInsets.top + headerHeight + 6.0
                        for (index, (rowLayout, rowApply)) in rowLayouts.enumerated() {
                            let row = strongSelf.rowNodes[index]
                            row.frame = CGRect(x: leftInset, y: y, width: size.width - leftInset, height: rowHeight)
                            let rowColor = PaiToolSummary.followUpTarget(tools[index]) != nil ? accentColor : PaiToolSummary.isHousekeeping(tools[index]) ? housekeepingColor : textColor
                            row.iconNode.image = UIImage(systemName: PaiToolSummary.symbol(tools[index]), withConfiguration: UIImage.SymbolConfiguration(pointSize: 12.0, weight: .regular))?.withTintColor(rowColor, renderingMode: .alwaysOriginal)
                            row.iconNode.frame = CGRect(x: 0.0, y: (rowHeight - iconSize) / 2.0, width: iconSize, height: iconSize)
                            let textNode = rowApply()
                            textNode.frame = CGRect(origin: CGPoint(x: iconSize + 8.0, y: (rowHeight - rowLayout.size.height) / 2.0), size: rowLayout.size)
                            haloed(row, color: haloColor)
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
            let doing = meta.tool.map(Self.doing) ?? "Thinking"
            let elapsed = Self.elapsed(meta)
            return elapsed.isEmpty ? "\(doing)…" : "\(doing)… · \(elapsed)"
        }
        switch meta.state {
        case "dead": return "Ended"
        case "error": return "Failed"
        default:
            let tools = PaiToolSummary.line(meta.tools ?? [])
            let baked = meta.durationMs.map { "Baked for \(Self.duration($0))" } ?? "Done"
            return tools.isEmpty ? baked : "\(baked) · \(tools.prefix(1).lowercased() + tools.dropFirst())"
        }
    }

    /// The current tool as a present participle: "$ ls" → "Running ls", "Read ~/x.ts" → "Reading ~/x.ts".
    private static func doing(_ tool: String) -> String {
        if tool.hasPrefix("$ ") { return "Running \(tool.dropFirst(2))" }
        let verbs = ["Read": "Reading", "Edit": "Editing", "Write": "Writing", "Grep": "Searching", "Glob": "Finding", "WebSearch": "Searching", "WebFetch": "Fetching", "Agent": "Delegating", "Task": "Delegating"]
        for (name, verb) in verbs where tool == name || tool.hasPrefix(name + " ") {
            let rest = tool.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? verb : "\(verb) \(rest)"
        }
        return "Using \(tool)"
    }

    /// How long the turn took; when it finished is the bubble's own timestamp.
    private static func footerText(_ meta: PaiRichMeta?) -> String {
        guard let durationMs = meta?.durationMs else { return "" }
        return "\(max(1, Int(durationMs / 1000)))s"
    }

    private static func duration(_ ms: Double) -> String {
        let seconds = max(1, Int(ms / 1000))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
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
        guard self.bounds.contains(point), let item = self.item, let meta = PaiTrailer.find(item.message)?.meta else {
            return ChatMessageBubbleContentTapAction(content: .none)
        }
        if !self.stopNode.isHidden, self.stopNode.frame.insetBy(dx: -6.0, dy: -6.0).contains(point) {
            return ChatMessageBubbleContentTapAction(content: .custom({ [weak item] in
                item?.controllerInteraction.stopPaiSession?(meta.session)
            }))
        }
        let tools = meta.tools ?? []
        // A send_to_thread row — expanded, or the whole header when it is the turn's only tool — leads
        // into that thread, the way a delegation card does, instead of toggling the timeline.
        if self.expanded {
            for (index, row) in self.rowNodes.enumerated() where index < tools.count && !row.isHidden {
                if row.frame.contains(point), let shortId = PaiToolSummary.followUpTarget(tools[index]) {
                    return ChatMessageBubbleContentTapAction(content: .custom({ [weak item] in
                        item?.controllerInteraction.openPaiThread?(shortId)
                    }))
                }
            }
        } else if point.y <= self.headerHeight, tools.count == 1, let shortId = PaiToolSummary.followUpTarget(tools[0]) {
            return ChatMessageBubbleContentTapAction(content: .custom({ [weak item] in
                item?.controllerInteraction.openPaiThread?(shortId)
            }))
        }
        guard point.y <= self.headerHeight, !tools.isEmpty else {
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
