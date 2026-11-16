import AsyncDisplayKit
import ChatControllerInteraction
import ChatMessageBubbleContentNode
import ChatMessageItemCommon
import Display
import Foundation
import PaiUI
import PromptUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

private let thumbSize: CGFloat = 44.0
private let thumbGap: CGFloat = 10.0
private let checkSize: CGFloat = 22.0
private let rowPadding = UIEdgeInsets(top: 7.0, left: 9.0, bottom: 7.0, right: 9.0)
private let rowGap: CGFloat = 4.0
private let lineGap: CGFloat = 1.0

/// Pictures that did not load: their rows are laid out without one.
private var failedThumbs = Set<String>()

/// Text drawn into an image, at most `lines` lines, the last one cut with an ellipsis.
private func textImage(_ text: String, font: UIFont, color: UIColor, maxWidth: CGFloat, lines: Int) -> UIImage? {
    guard !text.isEmpty, maxWidth > 1.0 else { return nil }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    let maxHeight = ceil(font.lineHeight * CGFloat(lines))
    let bounds = string.boundingRect(with: CGSize(width: maxWidth, height: lines == 1 ? font.lineHeight : .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil)
    let size = CGSize(width: min(maxWidth, ceil(bounds.width)), height: min(maxHeight, ceil(bounds.height)))
    guard size.width > 0.0, size.height > 0.0 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreenScale
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        string.draw(with: CGRect(origin: .zero, size: size), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}

private func checkImage(ticked: Bool, color: UIColor) -> UIImage? {
    symbolImage(ticked ? "checkmark.circle.fill" : "circle", color: ticked ? color : color.withAlphaComponent(0.5))
}

/// Drawn into a bitmap: a layer-backed image node shows a symbol's raw template, black, not its tint.
private func symbolImage(_ name: String, color: UIColor) -> UIImage? {
    let configuration = UIImage.SymbolConfiguration(pointSize: checkSize - 2.0, weight: .regular)
    guard let symbol = UIImage(systemName: name, withConfiguration: configuration)?.withTintColor(color, renderingMode: .alwaysOriginal) else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreenScale
    return UIGraphicsImageRenderer(size: symbol.size, format: format).image { _ in
        symbol.draw(at: .zero)
    }
}

/// An ask's options drawn as rows when they carry details: a picture, the label, a line under it, the page's domain.
/// Tapping the domain opens the page; tapping anywhere else on the row answers (or ticks, on a multi-select ask) with
/// the same callback the option's button sends.
///
/// An ask holding several questions is drawn whole instead: each question with its options (ticked here, not on
/// pai's side), a row to answer it in words when it takes them, and one Send for every answer, which goes to pai as
/// one JSON answer. A question left blank stays open there.
public final class ChatMessagePaiAskBubbleContentNode: ChatMessageBubbleContentNode {
    private final class RowNode {
        let background = ASDisplayNode()
        let check = ASImageNode()
        let thumb = ASImageNode()
        let label = ASImageNode()
        let subtitle = ASImageNode()
        let domain = ASImageNode()
        let disposable = MetaDisposable()
        var thumbUrl: String?

        init() {
            self.background.isLayerBacked = true
            self.background.cornerRadius = 10.0
            self.thumb.cornerRadius = 6.0
            self.thumb.clipsToBounds = true
            self.thumb.contentMode = .scaleAspectFill
            for node in [self.check, self.thumb, self.label, self.subtitle, self.domain] {
                node.displaysAsynchronously = false
                node.isLayerBacked = true
            }
        }

        var nodes: [ASDisplayNode] { [self.background, self.check, self.thumb, self.label, self.subtitle, self.domain] }
    }

    private enum Tap {
        /// The option's own button callback.
        case callback(EngineMemoryBuffer)
        case pick(card: PaiAsk.Card, question: Int, option: Int)
        case type(card: PaiAsk.Card, question: Int)
        case send(card: PaiAsk.Card)
    }

    private enum Style {
        /// Text on the bubble: a question, its header, an error.
        case plain
        case option(ticked: Bool)
        case send(enabled: Bool)
    }

    private struct Hit {
        let frame: CGRect
        let domainFrame: CGRect?
        let url: String?
        let tap: Tap
    }

    private var rowNodes: [RowNode] = []
    private var hits: [Hit] = []

    required public init() {
        super.init()
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for row in self.rowNodes {
            row.disposable.dispose()
        }
    }

    private func updateThumb(_ row: RowNode, url: String?, fill: UIColor, item: ChatMessageBubbleContentItem) {
        row.thumb.backgroundColor = fill
        if url == row.thumbUrl, row.thumb.image != nil {
            return
        }
        row.thumbUrl = url
        guard let url else {
            row.disposable.set(nil)
            row.thumb.image = nil
            return
        }
        if let cached = PaiAvatars.cached(url) {
            row.disposable.set(nil)
            row.thumb.image = cached
            return
        }
        row.thumb.image = nil
        let messageId = item.message.id
        row.disposable.set((PaiAvatars.image(url) |> deliverOnMainQueue).startStrict(next: { [weak row, weak item] image in
            guard let row, row.thumbUrl == url else { return }
            if let image {
                row.thumb.image = image
            } else {
                failedThumbs.insert(url)
                item?.controllerInteraction.requestMessageUpdate(messageId, false, nil)
            }
        }))
    }

    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, CGSize?, CGFloat, (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        return { item, layoutConstants, _, _, _, _ in
            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: true, headerSpacing: 0.0, hidesBackground: .never, forceFullCorners: false, forceAlignment: .none)

            return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, { constrainedSize, _ in
                let colors = item.presentationData.theme.theme.chat.message.incoming
                let base = item.presentationData.messageFont.pointSize
                let labelFont = Font.medium(floor(base * 16.0 / 17.0))
                let subtitleFont = Font.regular(floor(base * 14.0 / 17.0))
                let domainFont = Font.regular(floor(base * 13.0 / 17.0))
                let headerFont = Font.semibold(floor(base * 12.0 / 17.0))
                let questionFont = Font.semibold(floor(base * 16.0 / 17.0))
                let insets = layoutConstants.text.bubbleInsets
                let rowWidth = max(1.0, constrainedSize.width - insets.left - insets.right)

                struct Laid {
                    let style: Style
                    let tap: Tap?
                    let gap: CGFloat
                    var check: UIImage? = nil
                    var thumb: String? = nil
                    var label: UIImage? = nil
                    var subtitle: UIImage? = nil
                    var domain: UIImage? = nil
                    var url: String? = nil
                    var width: CGFloat = 0.0
                    var height: CGFloat = 0.0
                    var textHeight: CGFloat = 0.0
                }

                func option(label: String, labelColor: UIColor? = nil, detail: PaiOptionDetail?, check: UIImage?, ticked: Bool, tap: Tap, gap: CGFloat) -> Laid {
                    let thumb = detail?.image.flatMap { failedThumbs.contains($0) ? nil : $0 }
                    let leading = (check != nil ? checkSize + thumbGap : 0.0) + (thumb != nil ? thumbSize + thumbGap : 0.0)
                    let textWidth = rowWidth - rowPadding.left - rowPadding.right - leading
                    var laid = Laid(style: .option(ticked: ticked), tap: tap, gap: gap, check: check, thumb: thumb, url: detail?.url)
                    laid.label = textImage(label, font: labelFont, color: labelColor ?? colors.primaryTextColor, maxWidth: textWidth, lines: 1)
                    laid.subtitle = detail?.subtitle.flatMap { textImage($0, font: subtitleFont, color: colors.secondaryTextColor, maxWidth: textWidth, lines: 2) }
                    laid.domain = detail?.domain.flatMap { textImage("\($0) ↗", font: domainFont, color: colors.accentTextColor, maxWidth: textWidth, lines: 1) }
                    let parts = [laid.label, laid.subtitle, laid.domain].compactMap { $0 }
                    laid.textHeight = parts.reduce(0.0) { $0 + $1.size.height } + CGFloat(max(0, parts.count - 1)) * lineGap
                    let contentHeight = max(laid.textHeight, thumb != nil ? thumbSize : 0.0, check != nil ? checkSize : 0.0)
                    laid.width = rowPadding.left + leading + (parts.map { $0.size.width }.max() ?? 0.0) + rowPadding.right
                    laid.height = rowPadding.top + contentHeight + rowPadding.bottom
                    return laid
                }

                func plain(_ text: String, font: UIFont, color: UIColor, lines: Int, gap: CGFloat) -> Laid? {
                    guard let image = textImage(text, font: font, color: color, maxWidth: rowWidth, lines: lines) else { return nil }
                    return Laid(style: .plain, tap: nil, gap: gap, label: image, width: image.size.width, height: image.size.height, textHeight: image.size.height)
                }

                var laid: [Laid] = []
                if let card = PaiAsk.card(item.message) {
                    let draft = PaiAsk.draft(card.askId)
                    for (q, question) in card.questions.enumerated() {
                        let gap: CGFloat = q == 0 ? 2.0 : 14.0
                        var questionGap = gap
                        if let header = question.header, !header.isEmpty, header != question.question,
                           let headerRow = plain(header.uppercased(), font: headerFont, color: colors.secondaryTextColor, lines: 1, gap: gap) {
                            laid.append(headerRow)
                            questionGap = 2.0
                        }
                        if let text = plain(question.question, font: questionFont, color: colors.primaryTextColor, lines: 8, gap: questionGap) {
                            laid.append(text)
                        }
                        let typed = draft.typed[q]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                        let takesWords = question.freeText || question.options.isEmpty
                        let details = PaiOptionDetail.aligned(question.details, count: question.options.count)
                        let picks = typed != nil && takesWords ? [] : (draft.picked[q] ?? [])
                        for (i, label) in question.options.enumerated() {
                            let ticked = picks.contains(i)
                            laid.append(option(label: label, detail: details?[i], check: checkImage(ticked: ticked, color: colors.accentTextColor), ticked: ticked, tap: .pick(card: card, question: q, option: i), gap: i == 0 ? 6.0 : rowGap))
                        }
                        if takesWords {
                            let prompt = question.options.isEmpty ? "Your answer…" : "Type something…"
                            laid.append(option(label: typed ?? prompt, labelColor: typed != nil ? colors.primaryTextColor : colors.accentTextColor, detail: nil, check: symbolImage(typed != nil ? "checkmark.circle.fill" : "square.and.pencil", color: colors.accentTextColor), ticked: typed != nil, tap: .type(card: card, question: q), gap: question.options.isEmpty ? 6.0 : rowGap))
                        }
                    }
                    let answered = draft.answered(card)
                    let count = card.questions.count
                    let title = draft.sent ? "Sent" : draft.sending ? "Sending…" : answered > 0 && answered < count ? "Send \(answered) of \(count)" : "Send answers"
                    let enabled = answered > 0 && !draft.sending && !draft.sent
                    if let image = textImage(title, font: Font.semibold(floor(base * 16.0 / 17.0)), color: .white, maxWidth: rowWidth, lines: 1) {
                        laid.append(Laid(style: .send(enabled: enabled), tap: enabled ? .send(card: card) : nil, gap: 12.0, label: image, width: image.size.width + 32.0, height: 38.0, textHeight: image.size.height))
                    }
                    if let error = draft.error, let text = plain(error, font: subtitleFont, color: colors.scamColor, lines: 3, gap: 6.0) {
                        laid.append(text)
                    }
                } else {
                    for row in PaiAsk.rows(item.message) ?? [] {
                        let check = row.isMulti ? checkImage(ticked: row.ticked, color: colors.accentTextColor) : nil
                        laid.append(option(label: row.label, detail: row.detail, check: check, ticked: row.ticked, tap: .callback(row.data), gap: laid.isEmpty ? 4.0 : rowGap))
                    }
                }
                let contentWidth = laid.map { $0.width }.max() ?? 0.0
                let height = laid.isEmpty ? 0.0 : laid.reduce(0.0) { $0 + $1.gap + $1.height } + insets.bottom

                return (insets.left + contentWidth + insets.right, { boundingWidth in
                    return (CGSize(width: boundingWidth, height: height), { [weak self] _, _, _ in
                        guard let self else { return }
                        self.item = item

                        while self.rowNodes.count < laid.count {
                            let row = RowNode()
                            for node in row.nodes {
                                self.addSubnode(node)
                            }
                            self.rowNodes.append(row)
                        }
                        while self.rowNodes.count > laid.count {
                            let row = self.rowNodes.removeLast()
                            row.disposable.dispose()
                            for node in row.nodes {
                                node.removeFromSupernode()
                            }
                        }

                        var hits: [Hit] = []
                        var y: CGFloat = 0.0
                        let width = boundingWidth - insets.left - insets.right
                        for (laid, node) in zip(laid, self.rowNodes) {
                            y += laid.gap
                            let frame = CGRect(x: insets.left, y: y, width: width, height: laid.height)
                            node.background.frame = frame
                            let padding: UIEdgeInsets
                            switch laid.style {
                            case .plain:
                                node.background.backgroundColor = .clear
                                padding = .zero
                            case let .option(ticked):
                                node.background.backgroundColor = colors.accentTextColor.withAlphaComponent(ticked ? 0.16 : 0.08)
                                padding = rowPadding
                            case let .send(enabled):
                                node.background.backgroundColor = colors.accentTextColor.withAlphaComponent(enabled ? 1.0 : 0.4)
                                padding = UIEdgeInsets(top: 0.0, left: floorToScreenPixels((width - (laid.label?.size.width ?? 0.0)) / 2.0), bottom: 0.0, right: 0.0)
                            }

                            var x = frame.minX + padding.left
                            node.check.isHidden = laid.check == nil
                            node.check.image = laid.check
                            if let check = laid.check {
                                node.check.frame = CGRect(origin: CGPoint(x: x + floorToScreenPixels((checkSize - check.size.width) / 2.0), y: frame.minY + floorToScreenPixels((frame.height - check.size.height) / 2.0)), size: check.size)
                                x += checkSize + thumbGap
                            }
                            node.thumb.isHidden = laid.thumb == nil
                            self.updateThumb(node, url: laid.thumb, fill: colors.secondaryTextColor.withAlphaComponent(0.12), item: item)
                            if laid.thumb != nil {
                                node.thumb.frame = CGRect(x: x, y: frame.minY + floorToScreenPixels((frame.height - thumbSize) / 2.0), width: thumbSize, height: thumbSize)
                                x += thumbSize + thumbGap
                            }

                            var textY = frame.minY + floorToScreenPixels((frame.height - laid.textHeight) / 2.0)
                            var domainFrame: CGRect?
                            for (imageNode, image) in [(node.label, laid.label), (node.subtitle, laid.subtitle), (node.domain, laid.domain)] {
                                imageNode.isHidden = image == nil
                                imageNode.image = image
                                guard let image else { continue }
                                imageNode.frame = CGRect(origin: CGPoint(x: x, y: textY), size: image.size)
                                if imageNode === node.domain {
                                    domainFrame = imageNode.frame.insetBy(dx: -6.0, dy: -6.0)
                                }
                                textY += image.size.height + lineGap
                            }
                            if let tap = laid.tap {
                                hits.append(Hit(frame: frame, domainFrame: domainFrame, url: laid.url, tap: tap))
                            }
                            y += laid.height
                        }
                        self.hits = hits
                    })
                })
            })
        }
    }

    override public func tapActionAtPoint(_ point: CGPoint, gesture: TapLongTapOrDoubleTapGesture, isEstimating: Bool) -> ChatMessageBubbleContentTapAction {
        guard let item = self.item, let hit = self.hits.first(where: { $0.frame.contains(point) }) else {
            return ChatMessageBubbleContentTapAction(content: .none)
        }
        if let domainFrame = hit.domainFrame, domainFrame.contains(point), let url = hit.url {
            return ChatMessageBubbleContentTapAction(content: .url(ChatMessageBubbleContentTapAction.Url(url: url, concealed: false)))
        }
        let tap = hit.tap
        return ChatMessageBubbleContentTapAction(content: .custom({ [weak item] in
            guard let item else { return }
            ChatMessagePaiAskBubbleContentNode.perform(tap, item: item)
        }))
    }

    private static func perform(_ tap: Tap, item: ChatMessageBubbleContentItem) {
        let messageId = item.message.id
        let interaction = item.controllerInteraction
        let refresh = { [weak interaction] in
            interaction?.requestMessageUpdate(messageId, false, nil)
        }
        switch tap {
        case let .callback(data):
            interaction.requestMessageActionCallback(item.message, data, false, false, nil)
        case let .pick(card, q, i):
            let multi = card.questions[q].multiSelect
            PaiAsk.updateDraft(card.askId) { draft in
                var set = draft.picked[q] ?? []
                if multi {
                    if set.contains(i) { set.remove(i) } else { set.insert(i) }
                } else {
                    set = set == [i] ? [] : [i]
                }
                draft.picked[q] = set
                draft.typed[q] = nil
                draft.error = nil
            }
            refresh()
        case let .type(card, q):
            let question = card.questions[q]
            let controller = promptController(context: item.context, text: question.question, value: PaiAsk.draft(card.askId).typed[q], placeholder: "Your answer", apply: { value in
                guard let value else { return }
                PaiAsk.updateDraft(card.askId) { draft in
                    draft.typed[q] = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                    draft.error = nil
                }
                refresh()
            })
            interaction.presentController(controller, nil)
        case let .send(card):
            let draft = PaiAsk.draft(card.askId)
            guard !draft.sending, !draft.sent, draft.answered(card) > 0, let text = draft.text(card) else { return }
            PaiAsk.updateDraft(card.askId) { draft in
                draft.sending = true
                draft.error = nil
            }
            refresh()
            guard #available(iOS 16.0, *) else { return }
            Task { @MainActor in
                do {
                    try await PaiClient().answer(ask: card.askId, text: text)
                    PaiAsk.updateDraft(card.askId) { draft in
                        draft.sending = false
                        draft.sent = true
                    }
                } catch {
                    PaiAsk.updateDraft(card.askId) { draft in
                        draft.sending = false
                        draft.error = error.localizedDescription
                    }
                }
                refresh()
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
