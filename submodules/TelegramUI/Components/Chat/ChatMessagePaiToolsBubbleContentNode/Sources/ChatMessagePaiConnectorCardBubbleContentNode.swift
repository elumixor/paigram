import AsyncDisplayKit
import ChatControllerInteraction
import ChatMessageBubbleContentNode
import ChatMessageItemCommon
import Display
import Foundation
import PaiUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

private let sectionGap: CGFloat = 8.0
private let lineGap: CGFloat = 2.0
private let buttonGap: CGFloat = 6.0
private let buttonInsets = UIEdgeInsets(top: 6.0, left: 12.0, bottom: 6.0, right: 12.0)
private let closurePadding = UIEdgeInsets(top: 2.0, left: 8.0, bottom: 2.0, right: 8.0)
private let failedColor = UIColor(rgb: 0xe5484d)
private let doneColor = UIColor(rgb: 0x2f9e5b)

/// Wrapped text drawn into an image, at most `lines` lines, the last cut with an ellipsis.
private func wrappedImage(_ text: String, font: UIFont, color: UIColor, maxWidth: CGFloat, lines: Int) -> UIImage? {
    guard !text.isEmpty, maxWidth > 1.0 else { return nil }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    let bounds = string.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil)
    let size = CGSize(width: min(maxWidth, ceil(bounds.width)), height: min(ceil(font.lineHeight * CGFloat(lines)), ceil(bounds.height)))
    guard size.width > 0.0, size.height > 0.0 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreenScale
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        string.draw(with: CGRect(origin: .zero, size: size), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}

/// A word on a tinted capsule: a row's state, or a closed card's closure.
private func capsuleImage(_ text: String, font: UIFont, color: UIColor) -> UIImage? {
    guard let content = paiLineImage(symbol: nil, text: text, font: font, color: color, maxWidth: 220.0) else { return nil }
    let size = CGSize(width: content.size.width + closurePadding.left + closurePadding.right, height: content.size.height + closurePadding.top + closurePadding.bottom)
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreenScale
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        color.withAlphaComponent(0.14).setFill()
        UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2.0).fill()
        content.draw(at: CGPoint(x: closurePadding.left, y: closurePadding.top))
    }
}

/// A card button: its symbol and label on a capsule, filled when primary.
private func buttonImage(_ button: PaiCardView.Button, font: UIFont, accent: UIColor, onAccent: UIColor, busy: Bool) -> UIImage? {
    let ink = button.primary ? onAccent : accent
    let symbol = button.url != nil ? (PaiCardView.symbol(button.icon) ?? "arrow.up.right") : PaiCardView.symbol(button.icon)
    guard let content = paiLineImage(symbol: symbol, text: busy ? "\(button.label)…" : button.label, font: font, color: ink.withAlphaComponent(busy ? 0.6 : 1.0), maxWidth: 240.0) else { return nil }
    let size = CGSize(width: content.size.width + buttonInsets.left + buttonInsets.right, height: content.size.height + buttonInsets.top + buttonInsets.bottom)
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreenScale
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        (button.primary ? accent : accent.withAlphaComponent(0.12)).setFill()
        UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2.0).fill()
        content.draw(at: CGPoint(x: buttonInsets.left, y: buttonInsets.top))
    }
}

/// Presses in flight and the last error, by card: so the button says it is working and a refusal shows.
private var pressing: Set<String> = []
private var pressErrors: [Int: String] = [:]

/// A connector's card in a chat (the dev connector's build card: Install, TestFlight, its status and Retry), drawn
/// from the log row's `meta.card.view`. A press goes to the connector (`POST /cards/:id/press`) and the card redraws
/// from the row. Once the host closes it (`view.state`: superseded by a newer card, or invalidated by him) it folds
/// to its head and the closure, and every button goes, Install and Retry with them.
public final class ChatMessagePaiConnectorCardBubbleContentNode: ChatMessageBubbleContentNode {
    private enum Action {
        case press(button: String, row: String?)
        case open(String)
    }

    private var imageNodes: [ASImageNode] = []
    private var hits: [(CGRect, Action)] = []

    required public init() {
        super.init()
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, CGSize?, CGFloat, (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        return { item, layoutConstants, _, _, _, _ in
            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: false, headerSpacing: 0.0, hidesBackground: .never, forceFullCorners: false, forceAlignment: .none)

            return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, { constrainedSize, _ in
                let row = PaiRows.meta(item.message)
                let colors = item.presentationData.theme.theme.chat.message.incoming
                let accent = colors.accentControlColor.cgColor.alpha < 0.5 ? colors.primaryTextColor : colors.accentControlColor
                let onAccent = colors.bubble.withoutWallpaper.fill.first ?? .white
                let base = item.presentationData.messageFont.pointSize
                let titleFont = Font.semibold(floor(base * 16.0 / 17.0))
                let rowFont = Font.medium(floor(base * 15.0 / 17.0))
                let smallFont = Font.regular(floor(base * 14.0 / 17.0))
                let capsuleFont = Font.medium(floor(base * 12.0 / 17.0))
                let buttonFont = Font.semibold(floor(base * 14.0 / 17.0))
                let insets = layoutConstants.text.bubbleInsets
                let maxWidth = max(1.0, constrainedSize.width - insets.left - insets.right)

                // Laid out top to bottom as images with their place and, for a button, what a tap does.
                var placed: [(UIImage, CGRect, Action?)] = []
                var y = insets.top
                var width: CGFloat = 0.0

                func place(_ image: UIImage?, x: CGFloat = 0.0, action: Action? = nil) {
                    guard let image else { return }
                    placed.append((image, CGRect(origin: CGPoint(x: insets.left + x, y: y), size: image.size), action))
                    width = max(width, x + image.size.width)
                    y += image.size.height
                }

                /// Buttons in a wrapping row.
                func placeButtons(_ buttons: [PaiCardView.Button], card: Int, row rowId: String?) {
                    guard !buttons.isEmpty else { return }
                    y += sectionGap
                    var x: CGFloat = 0.0
                    var lineHeight: CGFloat = 0.0
                    for button in buttons {
                        let busy = pressing.contains("\(card):\(rowId ?? ""):\(button.id)")
                        guard let image = buttonImage(button, font: buttonFont, accent: accent, onAccent: onAccent, busy: busy) else { continue }
                        if x > 0.0, x + image.size.width > maxWidth {
                            x = 0.0
                            y += lineHeight + buttonGap
                            lineHeight = 0.0
                        }
                        let action: Action = button.url.map { .open($0) } ?? .press(button: button.id, row: rowId)
                        placed.append((image, CGRect(origin: CGPoint(x: insets.left + x, y: y), size: image.size), action))
                        width = max(width, x + image.size.width)
                        x += image.size.width + buttonGap
                        lineHeight = max(lineHeight, image.size.height)
                    }
                    y += lineHeight
                }

                if let row, let card = row.card {
                    let closure = PaiCardView.closure(card.state, by: card.supersededBy)
                    let closureImage = closure.flatMap { capsuleImage($0, font: capsuleFont, color: colors.secondaryTextColor) }
                    let headWidth = maxWidth - (closureImage.map { $0.size.width + 8.0 } ?? 0.0)
                    let head = paiLineImage(symbol: PaiCardView.symbol(card.icon) ?? "square.stack", text: card.title.paiNonEmpty ?? "Card", font: titleFont, color: colors.primaryTextColor, maxWidth: headWidth)
                    let headHeight = max(head?.size.height ?? 0.0, closureImage?.size.height ?? 0.0)
                    if let head {
                        placed.append((head, CGRect(origin: CGPoint(x: insets.left, y: y + floorToScreenPixels((headHeight - head.size.height) / 2.0)), size: head.size), nil))
                        width = max(width, head.size.width)
                    }
                    if let closureImage {
                        let x = (head?.size.width ?? 0.0) + 8.0
                        placed.append((closureImage, CGRect(origin: CGPoint(x: insets.left + x, y: y + floorToScreenPixels((headHeight - closureImage.size.height) / 2.0)), size: closureImage.size), nil))
                        width = max(width, x + closureImage.size.width)
                    }
                    y += headHeight

                    if let subtitle = card.subtitle?.paiNonEmpty {
                        y += lineGap
                        place(wrappedImage(subtitle, font: smallFont, color: colors.secondaryTextColor, maxWidth: maxWidth, lines: card.isClosed ? 1 : 3))
                    }

                    // Closed: the head and the closure only, no rows, no buttons.
                    if !card.isClosed {
                        for cardRow in card.rows.map({ PaiPressed.shown($0, card: row.id) }) {
                            y += sectionGap
                            let stateText = cardRow.isClosed ? PaiCardView.closure(cardRow.state, by: cardRow.supersededBy) : PaiCardView.label(cardRow.state)
                            let stateColor: UIColor
                            switch cardRow.state {
                            case "failed", "interrupted": stateColor = failedColor
                            case "succeeded": stateColor = doneColor
                            case "pending", "running": stateColor = accent
                            default: stateColor = colors.secondaryTextColor
                            }
                            let stateImage = stateText.flatMap { capsuleImage($0, font: capsuleFont, color: stateColor) }
                            let titleWidth = maxWidth - (stateImage.map { $0.size.width + 8.0 } ?? 0.0)
                            let title = wrappedImage(cardRow.title, font: cardRow.title.hasPrefix("$ ") ? Font.monospace(floor(base * 14.0 / 17.0)) : rowFont, color: colors.primaryTextColor, maxWidth: titleWidth, lines: 2)
                            let lineHeight = max(title?.size.height ?? 0.0, stateImage?.size.height ?? 0.0)
                            if let title {
                                placed.append((title, CGRect(origin: CGPoint(x: insets.left, y: y), size: title.size), cardRow.url.map { .open($0) }))
                                width = max(width, title.size.width)
                            }
                            if let stateImage {
                                let x = (title?.size.width ?? 0.0) + 8.0
                                placed.append((stateImage, CGRect(origin: CGPoint(x: insets.left + x, y: y + floorToScreenPixels(((title.map { min($0.size.height, rowFont.lineHeight) } ?? stateImage.size.height) - stateImage.size.height) / 2.0)), size: stateImage.size), nil))
                                width = max(width, x + stateImage.size.width)
                            }
                            y += lineHeight
                            if !cardRow.isClosed, let message = cardRow.message?.paiNonEmpty {
                                y += lineGap
                                place(wrappedImage(message, font: smallFont, color: colors.secondaryTextColor, maxWidth: maxWidth, lines: 3))
                            }
                            if !cardRow.isClosed {
                                placeButtons(cardRow.buttons, card: row.id, row: cardRow.id)
                            }
                        }
                        placeButtons(card.buttons, card: row.id, row: nil)
                    }
                    if let error = pressErrors[row.id] {
                        y += lineGap
                        place(wrappedImage(error, font: smallFont, color: failedColor, maxWidth: maxWidth, lines: 2))
                    }
                }
                let height = placed.isEmpty ? 0.0 : y + insets.bottom

                return (insets.left + width + insets.right, { boundingWidth in
                    return (CGSize(width: boundingWidth, height: height), { [weak self] _, _, _ in
                        guard let self else { return }
                        self.item = item
                        while self.imageNodes.count < placed.count {
                            let node = ASImageNode()
                            node.displaysAsynchronously = false
                            node.isLayerBacked = true
                            self.addSubnode(node)
                            self.imageNodes.append(node)
                        }
                        while self.imageNodes.count > placed.count {
                            self.imageNodes.removeLast().removeFromSupernode()
                        }
                        var hits: [(CGRect, Action)] = []
                        for ((image, frame, action), node) in zip(placed, self.imageNodes) {
                            node.image = image
                            node.frame = frame
                            if let action {
                                hits.append((frame.insetBy(dx: -4.0, dy: -4.0), action))
                            }
                        }
                        self.hits = hits
                    })
                })
            })
        }
    }

    override public func tapActionAtPoint(_ point: CGPoint, gesture: TapLongTapOrDoubleTapGesture, isEstimating: Bool) -> ChatMessageBubbleContentTapAction {
        guard let item = self.item, let hit = self.hits.last(where: { $0.0.contains(point) }) else {
            return ChatMessageBubbleContentTapAction(content: .none)
        }
        switch hit.1 {
        case let .open(url):
            return ChatMessageBubbleContentTapAction(content: .url(ChatMessageBubbleContentTapAction.Url(url: url, concealed: false)))
        case let .press(button, row):
            guard let meta = PaiRows.meta(item.message), let trailer = PaiTrailer.find(item.message)?.meta, let slug = trailer.agent ?? trailer.session.paiNonEmpty else {
                return ChatMessageBubbleContentTapAction(content: .none)
            }
            return ChatMessageBubbleContentTapAction(content: .custom({ [weak item] in
                guard let item else { return }
                let key = "\(meta.id):\(row ?? ""):\(button)"
                guard !pressing.contains(key), #available(iOS 16.0, *) else { return }
                let messageId = item.message.id
                let interaction = item.controllerInteraction
                pressing.insert(key)
                pressErrors[meta.id] = nil
                // The row draws running and the card leaves every "waiting on you" at once; a refusal takes both back.
                let need = "card:\(meta.id)"
                if let row { PaiPressed.press(card: meta.id, row: row, was: meta.card?.rows.first { $0.id == row }?.state) }
                PaiSettled.add(need)
                interaction.requestMessageUpdate(messageId, false, nil)
                Task { @MainActor in
                    let error = await PaiRows.press(card: meta.id, button: button, row: row, slug: slug)
                    pressing.remove(key)
                    pressErrors[meta.id] = error
                    if error != nil {
                        if let row { PaiPressed.release(card: meta.id, row: row) }
                        PaiHost.store.unsettle(need)
                    }
                    interaction.requestMessageUpdate(messageId, false, nil)
                }
            }))
        }
    }
}
