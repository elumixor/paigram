import AsyncDisplayKit
import ChatControllerInteraction
import ChatMessageBubbleContentNode
import ChatMessageItemCommon
import Display
import Foundation
import PaiUI
import TelegramCore
import TelegramPresentationData
import UIKit

private let rowGap: CGFloat = 3.0
private let pillGap: CGFloat = 8.0
private let chevronWidth: CGFloat = 18.0
private let waitingColor = UIColor(red: 0.93, green: 0.62, blue: 0.10, alpha: 1.0)

/// A status as a small capsule: its symbol and its word, tinted.
private func pillImage(status: String, font: UIFont, color: UIColor) -> UIImage? {
    guard let content = paiLineImage(symbol: PaiAgentStatus.symbol(status), text: PaiAgentStatus.label(status), font: font, color: color, maxWidth: 200.0) else { return nil }
    let size = CGSize(width: content.size.width + 12.0, height: content.size.height + 4.0)
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreenScale
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
        color.withAlphaComponent(0.14).setFill()
        UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2.0).fill()
        content.draw(at: CGPoint(x: 6.0, y: 2.0))
    }
}

/// Work pai handed to an agent (`delegation`: the agent, the brief's first line, its live status) or what an agent
/// said back (`report`: its first line); either is a way into that agent's chat, by tap or by swiping left.
public final class ChatMessagePaiCardBubbleContentNode: ChatMessageBubbleContentNode {
    private let titleNode = ASImageNode()
    private let pillNode = ASImageNode()
    private let lineNode = ASImageNode()
    private let chevronNode = ASImageNode()

    required public init() {
        super.init()
        for node in [self.titleNode, self.pillNode, self.lineNode, self.chevronNode] {
            node.displaysAsynchronously = false
            node.isLayerBacked = true
            self.addSubnode(node)
        }
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// "↳ Hiring: Screen the new applicants" → "Screen the new applicants".
    private static func firstLine(_ text: String) -> String {
        var line = text.split(separator: "\n").first.map(String.init) ?? ""
        if line.hasPrefix("↳") || line.hasPrefix("↩"), let colon = line.range(of: ": ") {
            line = String(line[colon.upperBound...])
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, CGSize?, CGFloat, (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        return { item, layoutConstants, _, _, _, _ in
            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: true, headerSpacing: 0.0, hidesBackground: .never, forceFullCorners: false, forceAlignment: .none)

            return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, { constrainedSize, _ in
                let trailer = PaiTrailer.find(item.message)
                let meta = trailer?.meta
                let text = trailer.map { (item.message.text as NSString).substring(to: $0.textEnd) } ?? item.message.text
                let isDelegation = meta?.kind == "delegation"
                let colors = item.presentationData.theme.theme.chat.message.incoming
                let base = item.presentationData.messageFont.pointSize
                let titleFont = Font.semibold(floor(base * 15.0 / 17.0))
                let lineFont = Font.regular(floor(base * 14.0 / 17.0))
                let pillFont = Font.medium(floor(base * 12.0 / 17.0))
                let insets = layoutConstants.text.bubbleInsets
                let maxWidth = max(1.0, constrainedSize.width - insets.left - insets.right - chevronWidth)

                let status = isDelegation ? PaiAgentStatus.effective(agent: meta?.agent, posted: meta?.status) : nil
                let statusColor: UIColor
                switch status {
                case "working": statusColor = colors.accentTextColor
                case "waiting": statusColor = waitingColor
                default: statusColor = colors.secondaryTextColor
                }
                let pill = status.flatMap { pillImage(status: $0, font: pillFont, color: statusColor) }
                let name = meta?.agentName ?? PaiChat.agent(meta?.agent)?.name ?? meta?.agent ?? "Agent"
                let symbol = PaiEventIcon.symbol(event: isDelegation ? "delegation" : "report")
                let title = paiLineImage(symbol: symbol, text: name, font: titleFont, color: colors.accentTextColor, maxWidth: maxWidth - (pill.map { $0.size.width + pillGap } ?? 0.0))
                let line = paiLineImage(symbol: nil, text: Self.firstLine(text), font: lineFont, color: colors.secondaryTextColor, maxWidth: maxWidth)
                let chevron = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: lineFont.pointSize * 0.85, weight: .semibold))?.withTintColor(colors.secondaryTextColor.withAlphaComponent(0.6), renderingMode: .alwaysOriginal)

                let titleWidth = (title?.size.width ?? 0.0) + (pill.map { $0.size.width + pillGap } ?? 0.0)
                let titleHeight = max(title?.size.height ?? 0.0, pill?.size.height ?? 0.0)
                let lineHeight = line?.size.height ?? 0.0
                let contentWidth = max(titleWidth, line?.size.width ?? 0.0) + chevronWidth
                let height = insets.top + titleHeight + (line != nil ? rowGap + lineHeight : 0.0) + insets.bottom + 2.0

                return (insets.left + contentWidth + insets.right, { boundingWidth in
                    return (CGSize(width: boundingWidth, height: height), { [weak self] _, _, _ in
                        guard let self else { return }
                        self.item = item

                        let top = insets.top + 1.0
                        self.titleNode.image = title
                        if let title {
                            self.titleNode.frame = CGRect(origin: CGPoint(x: insets.left, y: top + floorToScreenPixels((titleHeight - title.size.height) / 2.0)), size: title.size)
                        }
                        self.pillNode.isHidden = pill == nil
                        self.pillNode.image = pill
                        if let pill {
                            self.pillNode.frame = CGRect(origin: CGPoint(x: insets.left + (title?.size.width ?? 0.0) + pillGap, y: top + floorToScreenPixels((titleHeight - pill.size.height) / 2.0)), size: pill.size)
                        }
                        self.lineNode.isHidden = line == nil
                        self.lineNode.image = line
                        if let line {
                            self.lineNode.frame = CGRect(origin: CGPoint(x: insets.left, y: top + titleHeight + rowGap), size: line.size)
                        }
                        self.chevronNode.image = chevron
                        if let chevron {
                            self.chevronNode.frame = CGRect(origin: CGPoint(x: boundingWidth - insets.right - chevron.size.width, y: floorToScreenPixels((height - chevron.size.height) / 2.0)), size: chevron.size)
                        }
                    })
                })
            })
        }
    }

    override public func tapActionAtPoint(_ point: CGPoint, gesture: TapLongTapOrDoubleTapGesture, isEstimating: Bool) -> ChatMessageBubbleContentTapAction {
        guard self.bounds.contains(point), let item = self.item, let meta = PaiTrailer.find(item.message)?.meta, meta.agent != nil || meta.thread != nil else {
            return ChatMessageBubbleContentTapAction(content: .none)
        }
        return ChatMessageBubbleContentTapAction(content: .custom({ [weak item] in
            item?.controllerInteraction.openPaiAgent?(meta.agent, meta.thread)
        }))
    }
}
