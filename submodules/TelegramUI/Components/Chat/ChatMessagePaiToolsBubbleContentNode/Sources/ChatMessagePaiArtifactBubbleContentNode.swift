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

private let headingGap: CGFloat = 6.0
private let artifactGap: CGFloat = 10.0
private let expandGap: CGFloat = 4.0
private let frameRadius: CGFloat = 10.0

/// The HTML pages an agent attached to its reply (`meta.artifacts` on the log row), each live under the words: its
/// title, then the page in a sandboxed web view (`PaiArtifactView`) as tall as the page says, clamped at 560 pt with
/// Expand under it. A page's height arrives after it loads; the message is laid out again then.
public final class ChatMessagePaiArtifactBubbleContentNode: ChatMessageBubbleContentNode {
    private struct Slot {
        let heading: ASImageNode
        let frame: ASDisplayNode
        let view: PaiArtifactView
        let expand: ASImageNode
    }

    private var slots: [Slot] = []
    private var expandHits: [(CGRect, String)] = []
    private var frameRects: [CGRect] = []

    required public init() {
        super.init()
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeSlot() -> Slot {
        let heading = ASImageNode()
        heading.displaysAsynchronously = false
        heading.isLayerBacked = true
        let frame = ASDisplayNode()
        frame.isLayerBacked = true
        frame.cornerRadius = frameRadius
        frame.borderWidth = UIScreenPixel
        let view = PaiArtifactView(frame: .zero)
        view.layer.cornerRadius = frameRadius
        let expand = ASImageNode()
        expand.displaysAsynchronously = false
        expand.isLayerBacked = true
        self.addSubnode(heading)
        self.addSubnode(frame)
        self.view.addSubview(view)
        self.addSubnode(expand)
        return Slot(heading: heading, frame: frame, view: view, expand: expand)
    }

    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, CGSize?, CGFloat, (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        return { item, layoutConstants, _, _, _, _ in
            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: false, headerSpacing: 0.0, hidesBackground: .never, forceFullCorners: false, forceAlignment: .none)

            return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, { constrainedSize, _ in
                let artifacts = PaiRows.meta(item.message)?.artifacts ?? []
                let theme = item.presentationData.theme.theme
                let colors = theme.chat.message.incoming
                let base = item.presentationData.messageFont.pointSize
                let headingFont = Font.medium(floor(base * 14.0 / 17.0))
                let expandFont = Font.medium(floor(base * 13.0 / 17.0))
                let insets = layoutConstants.text.bubbleInsets
                let width = max(1.0, constrainedSize.width - insets.left - insets.right)
                let accent = colors.accentTextColor.cgColor.alpha < 0.5 ? colors.primaryTextColor : colors.accentTextColor
                let frameTheme = PaiArtifacts.Theme(
                    dark: theme.overallDarkAppearance,
                    ink: colors.primaryTextColor,
                    muted: colors.secondaryTextColor,
                    surface: colors.bubble.withoutWallpaper.fill.first ?? (theme.overallDarkAppearance ? .black : .white),
                    line: colors.secondaryTextColor.withAlphaComponent(0.25),
                    accent: accent
                )

                struct Laid {
                    let artifact: PaiArtifact
                    let heading: UIImage?
                    let frameHeight: CGFloat
                    let expand: UIImage?
                }
                let laid = artifacts.map { artifact -> Laid in
                    let (height, clamped) = PaiArtifacts.frameHeight(artifact.file)
                    let expanded = PaiArtifacts.isExpanded(artifact.file)
                    let heading = paiLineImage(symbol: "doc.richtext", text: artifact.heading, font: headingFont, color: colors.secondaryTextColor, maxWidth: width)
                    let expand = clamped ? paiLineImage(symbol: expanded ? "chevron.up" : "chevron.down", text: expanded ? "Collapse" : "Expand", font: expandFont, color: accent, maxWidth: width) : nil
                    return Laid(artifact: artifact, heading: heading, frameHeight: height, expand: expand)
                }
                var height: CGFloat = 0.0
                for (index, entry) in laid.enumerated() {
                    height += (index == 0 ? 4.0 : artifactGap) + (entry.heading.map { $0.size.height + headingGap } ?? 0.0) + entry.frameHeight
                    if let expand = entry.expand {
                        height += expandGap + expand.size.height
                    }
                }
                if !laid.isEmpty {
                    height += insets.bottom
                }

                // As wide as the bubble can be: a page needs the room.
                return (laid.isEmpty ? 0.0 : constrainedSize.width, { boundingWidth in
                    return (CGSize(width: boundingWidth, height: height), { [weak self] _, _, _ in
                        guard let self else { return }
                        self.item = item
                        while self.slots.count < laid.count {
                            self.slots.append(self.makeSlot())
                        }
                        while self.slots.count > laid.count {
                            let slot = self.slots.removeLast()
                            slot.heading.removeFromSupernode()
                            slot.frame.removeFromSupernode()
                            slot.view.removeFromSuperview()
                            slot.expand.removeFromSupernode()
                        }
                        let frameWidth = boundingWidth - insets.left - insets.right
                        let messageId = item.message.id
                        let interaction = item.controllerInteraction
                        var y: CGFloat = 0.0
                        var expandHits: [(CGRect, String)] = []
                        var frameRects: [CGRect] = []
                        for (index, (entry, slot)) in zip(laid, self.slots).enumerated() {
                            y += index == 0 ? 4.0 : artifactGap
                            slot.heading.image = entry.heading
                            if let heading = entry.heading {
                                slot.heading.frame = CGRect(origin: CGPoint(x: insets.left, y: y), size: heading.size)
                                y += heading.size.height + headingGap
                            }
                            let rect = CGRect(x: insets.left, y: y, width: frameWidth, height: entry.frameHeight)
                            slot.frame.frame = rect
                            slot.frame.backgroundColor = frameTheme.ink.withAlphaComponent(0.04)
                            slot.frame.borderColor = frameTheme.line.cgColor
                            slot.view.frame = rect
                            slot.view.onHeight = { _, _ in
                                interaction.requestMessageUpdate(messageId, false, nil)
                            }
                            slot.view.load(file: entry.artifact.file, theme: frameTheme)
                            frameRects.append(rect)
                            y += entry.frameHeight
                            slot.expand.isHidden = entry.expand == nil
                            slot.expand.image = entry.expand
                            if let expand = entry.expand {
                                y += expandGap
                                let expandFrame = CGRect(origin: CGPoint(x: insets.left + floorToScreenPixels((frameWidth - expand.size.width) / 2.0), y: y), size: expand.size)
                                slot.expand.frame = expandFrame
                                expandHits.append((expandFrame.insetBy(dx: -16.0, dy: -8.0), entry.artifact.file))
                                y += expand.size.height
                            }
                        }
                        self.expandHits = expandHits
                        self.frameRects = frameRects
                    })
                })
            })
        }
    }

    override public func tapActionAtPoint(_ point: CGPoint, gesture: TapLongTapOrDoubleTapGesture, isEstimating: Bool) -> ChatMessageBubbleContentTapAction {
        if let item = self.item, let hit = self.expandHits.first(where: { $0.0.contains(point) }) {
            let file = hit.1
            return ChatMessageBubbleContentTapAction(content: .custom({ [weak item] in
                guard let item else { return }
                PaiArtifacts.toggleExpanded(file)
                item.controllerInteraction.requestMessageUpdate(item.message.id, false, nil)
            }))
        }
        // A tap on the page is the page's own.
        if self.frameRects.contains(where: { $0.contains(point) }) {
            return ChatMessageBubbleContentTapAction(content: .ignore)
        }
        return ChatMessageBubbleContentTapAction(content: .none)
    }
}
