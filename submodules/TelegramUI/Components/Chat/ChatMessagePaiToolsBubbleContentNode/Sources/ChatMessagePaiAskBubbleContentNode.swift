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
    let configuration = UIImage.SymbolConfiguration(pointSize: checkSize - 2.0, weight: .regular)
    return UIImage(systemName: ticked ? "checkmark.circle.fill" : "circle", withConfiguration: configuration)?.withTintColor(ticked ? color : color.withAlphaComponent(0.5), renderingMode: .alwaysOriginal)
}

/// An ask's options drawn as rows when they carry details: a picture, the label, a line under it, the page's domain.
/// Tapping the domain opens the page; tapping anywhere else on the row answers (or ticks, on a multi-select ask) with
/// the same callback the option's button sends.
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

    private struct Hit {
        let frame: CGRect
        let domainFrame: CGRect?
        let row: PaiAsk.Row
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
                let rows = PaiAsk.rows(item.message) ?? []
                let colors = item.presentationData.theme.theme.chat.message.incoming
                let base = item.presentationData.messageFont.pointSize
                let labelFont = Font.medium(floor(base * 16.0 / 17.0))
                let subtitleFont = Font.regular(floor(base * 14.0 / 17.0))
                let domainFont = Font.regular(floor(base * 13.0 / 17.0))
                let insets = layoutConstants.text.bubbleInsets
                let rowWidth = max(1.0, constrainedSize.width - insets.left - insets.right)

                struct Laid {
                    let row: PaiAsk.Row
                    let check: UIImage?
                    let thumb: String?
                    let label: UIImage?
                    let subtitle: UIImage?
                    let domain: UIImage?
                    let width: CGFloat
                    let height: CGFloat
                    let textHeight: CGFloat
                }
                let laid = rows.map { row -> Laid in
                    let check = row.isMulti ? checkImage(ticked: row.ticked, color: colors.accentTextColor) : nil
                    let thumb = row.detail?.image.flatMap { failedThumbs.contains($0) ? nil : $0 }
                    let leading = (check != nil ? checkSize + thumbGap : 0.0) + (thumb != nil ? thumbSize + thumbGap : 0.0)
                    let textWidth = rowWidth - rowPadding.left - rowPadding.right - leading
                    let label = textImage(row.label, font: labelFont, color: colors.primaryTextColor, maxWidth: textWidth, lines: 1)
                    let subtitle = row.detail?.subtitle.flatMap { textImage($0, font: subtitleFont, color: colors.secondaryTextColor, maxWidth: textWidth, lines: 2) }
                    let domain = row.detail?.domain.flatMap { textImage("\($0) ↗", font: domainFont, color: colors.accentTextColor, maxWidth: textWidth, lines: 1) }
                    let parts = [label, subtitle, domain].compactMap { $0 }
                    let textHeight = parts.reduce(0.0) { $0 + $1.size.height } + CGFloat(max(0, parts.count - 1)) * lineGap
                    let contentHeight = max(textHeight, thumb != nil ? thumbSize : 0.0, check != nil ? checkSize : 0.0)
                    let width = rowPadding.left + leading + (parts.map { $0.size.width }.max() ?? 0.0) + rowPadding.right
                    return Laid(row: row, check: check, thumb: thumb, label: label, subtitle: subtitle, domain: domain, width: width, height: rowPadding.top + contentHeight + rowPadding.bottom, textHeight: textHeight)
                }
                let contentWidth = laid.map { $0.width }.max() ?? 0.0
                let rowsHeight = laid.reduce(0.0) { $0 + $1.height } + CGFloat(max(0, laid.count - 1)) * rowGap
                let height = laid.isEmpty ? 0.0 : rowsHeight + 4.0 + insets.bottom

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
                        var y: CGFloat = 4.0
                        let width = boundingWidth - insets.left - insets.right
                        for (laid, node) in zip(laid, self.rowNodes) {
                            let frame = CGRect(x: insets.left, y: y, width: width, height: laid.height)
                            node.background.frame = frame
                            node.background.backgroundColor = colors.accentTextColor.withAlphaComponent(laid.row.ticked ? 0.16 : 0.08)

                            var x = frame.minX + rowPadding.left
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
                            hits.append(Hit(frame: frame, domainFrame: domainFrame, row: laid.row))
                            y += laid.height + rowGap
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
        if let domainFrame = hit.domainFrame, domainFrame.contains(point), let url = hit.row.detail?.url {
            return ChatMessageBubbleContentTapAction(content: .url(ChatMessageBubbleContentTapAction.Url(url: url, concealed: false)))
        }
        let data = hit.row.data
        return ChatMessageBubbleContentTapAction(content: .custom({ [weak item] in
            guard let item else { return }
            item.controllerInteraction.requestMessageActionCallback(item.message, data, false, false, nil)
        }))
    }
}
