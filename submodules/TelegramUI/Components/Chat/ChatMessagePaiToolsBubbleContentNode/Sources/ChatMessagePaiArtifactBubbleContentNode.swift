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
private let footGap: CGFloat = 8.0
private let footItemGap: CGFloat = 10.0
private let footButtonInsets = UIEdgeInsets(top: 7.0, left: 14.0, bottom: 7.0, right: 14.0)

/// Approve & build: a filled capsule, faded while the press is in flight or the mock's state is still unread.
private func footButtonImage(_ text: String, font: UIFont, accent: UIColor, onAccent: UIColor, enabled: Bool) -> UIImage? {
    guard let content = paiLineImage(symbol: nil, text: text, font: font, color: onAccent, maxWidth: 240.0) else { return nil }
    let size = CGSize(width: content.size.width + footButtonInsets.left + footButtonInsets.right, height: content.size.height + footButtonInsets.top + footButtonInsets.bottom)
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreenScale
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        accent.withAlphaComponent(enabled ? 1.0 : 0.6).setFill()
        UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8.0).fill()
        content.draw(at: CGPoint(x: footButtonInsets.left, y: footButtonInsets.top))
    }
}

/// The HTML pages an agent attached to its reply (`meta.artifacts` on the log row), each live under the words: its
/// title, then the page in a sandboxed web view (`PaiArtifactView`) as tall as the page says, clamped at 560 pt with
/// Expand under it. A page's height arrives after it loads; the message is laid out again then. A UI mock's page
/// (`artifact.mock`) gets a foot under a rule, as pai's web client draws it: "Mock v{n}", then Approve & build on the
/// latest version (`PaiMocks`), "Approved · building" with the session's link once approved, or "Replaced by v{m}".
public final class ChatMessagePaiArtifactBubbleContentNode: ChatMessageBubbleContentNode {
    private struct Slot {
        let heading: ASImageNode
        let frame: ASDisplayNode
        let view: PaiArtifactView
        let expand: ASImageNode
    }

    private enum FootAction {
        case approve(id: String, version: Int)
        case open(String)
    }

    /// One image of a mock's foot, its place relative to the foot's row, right-aligned ones measured from its end.
    private struct FootPiece {
        let image: UIImage
        let x: CGFloat
        let y: CGFloat
        let trailing: Bool
        let action: FootAction?
    }

    private struct Foot {
        let pieces: [FootPiece]
        let height: CGFloat
    }

    private var slots: [Slot] = []
    private var expandHits: [(CGRect, String)] = []
    private var frameRects: [CGRect] = []
    private var footNodes: [ASImageNode] = []
    private var footRules: [ASDisplayNode] = []
    private var footHits: [(CGRect, FootAction)] = []

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
                    let foot: Foot?
                }
                let footFont = Font.regular(floor(base * 13.0 / 17.0))
                let footVersionFont = Font.medium(floor(base * 13.0 / 17.0))
                let footButtonFont = Font.semibold(floor(base * 13.0 / 17.0))
                let onAccent = colors.bubble.withoutWallpaper.fill.first ?? .white
                let failedColor = UIColor(rgb: 0xe5484d)

                /// The foot's row: the version and the note on the left, the button or link on the right, a refusal
                /// under it.
                func makeFoot(_ ref: PaiMockRef) -> Foot {
                    let state = PaiMocks.state(ref.id)
                    var pieces: [FootPiece] = []
                    let version = paiLineImage(symbol: nil, text: "Mock v\(ref.version)", font: footVersionFont, color: colors.primaryTextColor, maxWidth: width)
                    var trailing: (UIImage, FootAction?)?
                    let note: (String, String?)
                    var error: String?
                    switch PaiMockFoot.of(ref, state: state) {
                    case let .approved(sessionUrl):
                        note = ("Approved · building", "hammer")
                        if let sessionUrl, let link = paiLineImage(symbol: nil, text: "Open session", font: footVersionFont, color: accent, maxWidth: width) {
                            trailing = (link, .open(sessionUrl))
                        }
                    case let .approvable(ready):
                        note = ("Write in the chat to change it", nil)
                        let busy = PaiMocks.isApproving(ref.id)
                        if let button = footButtonImage(busy ? "Starting…" : "Approve & build", font: footButtonFont, accent: accent, onAccent: onAccent, enabled: ready && !busy) {
                            trailing = (button, ready && !busy ? .approve(id: ref.id, version: ref.version) : nil)
                        }
                        error = PaiMocks.error(ref.id)
                    case let .replaced(latest):
                        note = ("Replaced by v\(latest)", nil)
                    }
                    let versionWidth = version.map { $0.size.width + footItemGap } ?? 0.0
                    let trailingWidth = trailing.map { $0.0.size.width + footItemGap } ?? 0.0
                    let noteImage = paiLineImage(symbol: note.1, text: note.0, font: footFont, color: colors.secondaryTextColor, maxWidth: max(1.0, width - versionWidth - trailingWidth))
                    let rowHeight = max(version?.size.height ?? 0.0, noteImage?.size.height ?? 0.0, trailing?.0.size.height ?? 0.0, 30.0)
                    if let version {
                        pieces.append(FootPiece(image: version, x: 0.0, y: floor((rowHeight - version.size.height) / 2.0), trailing: false, action: nil))
                    }
                    if let noteImage {
                        pieces.append(FootPiece(image: noteImage, x: versionWidth, y: floor((rowHeight - noteImage.size.height) / 2.0), trailing: false, action: nil))
                    }
                    if let trailing {
                        let image = trailing.0
                        pieces.append(FootPiece(image: image, x: image.size.width, y: floor((rowHeight - image.size.height) / 2.0), trailing: true, action: trailing.1))
                    }
                    var height = rowHeight
                    if let error, let errorImage = paiLineImage(symbol: "exclamationmark.triangle", text: error, font: footFont, color: failedColor, maxWidth: width) {
                        height += 4.0
                        pieces.append(FootPiece(image: errorImage, x: errorImage.size.width, y: height, trailing: true, action: nil))
                        height += errorImage.size.height
                    }
                    return Foot(pieces: pieces, height: height)
                }
                let laid = artifacts.map { artifact -> Laid in
                    let (height, clamped) = PaiArtifacts.frameHeight(artifact.file)
                    let expanded = PaiArtifacts.isExpanded(artifact.file)
                    let heading = paiLineImage(symbol: "doc.richtext", text: artifact.heading, font: headingFont, color: colors.secondaryTextColor, maxWidth: width)
                    let expand = clamped ? paiLineImage(symbol: expanded ? "chevron.up" : "chevron.down", text: expanded ? "Collapse" : "Expand", font: expandFont, color: accent, maxWidth: width) : nil
                    return Laid(artifact: artifact, heading: heading, frameHeight: height, expand: expand, foot: artifact.mock.map(makeFoot))
                }
                var height: CGFloat = 0.0
                for (index, entry) in laid.enumerated() {
                    height += (index == 0 ? 4.0 : artifactGap) + (entry.heading.map { $0.size.height + headingGap } ?? 0.0) + entry.frameHeight
                    if let expand = entry.expand {
                        height += expandGap + expand.size.height
                    }
                    if let foot = entry.foot {
                        height += footGap * 2.0 + foot.height
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
                        var footHits: [(CGRect, FootAction)] = []
                        var footPlaced: [(UIImage, CGRect)] = []
                        var footRuleRects: [CGRect] = []
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
                            if let foot = entry.foot {
                                y += footGap
                                footRuleRects.append(CGRect(x: insets.left, y: y, width: frameWidth, height: UIScreenPixel))
                                y += footGap
                                for piece in foot.pieces {
                                    let x = piece.trailing ? insets.left + frameWidth - piece.x : insets.left + piece.x
                                    let rect = CGRect(origin: CGPoint(x: x, y: y + piece.y), size: piece.image.size)
                                    footPlaced.append((piece.image, rect))
                                    if let action = piece.action {
                                        footHits.append((rect.insetBy(dx: -6.0, dy: -6.0), action))
                                    }
                                }
                                y += foot.height
                            }
                        }
                        while self.footNodes.count < footPlaced.count {
                            let node = ASImageNode()
                            node.displaysAsynchronously = false
                            node.isLayerBacked = true
                            self.addSubnode(node)
                            self.footNodes.append(node)
                        }
                        while self.footNodes.count > footPlaced.count {
                            self.footNodes.removeLast().removeFromSupernode()
                        }
                        for ((image, rect), node) in zip(footPlaced, self.footNodes) {
                            node.image = image
                            node.frame = rect
                        }
                        while self.footRules.count < footRuleRects.count {
                            let node = ASDisplayNode()
                            node.isLayerBacked = true
                            self.addSubnode(node)
                            self.footRules.append(node)
                        }
                        while self.footRules.count > footRuleRects.count {
                            self.footRules.removeLast().removeFromSupernode()
                        }
                        for (rect, node) in zip(footRuleRects, self.footRules) {
                            node.frame = rect
                            node.backgroundColor = frameTheme.line
                        }
                        self.footHits = footHits
                        self.expandHits = expandHits
                        self.frameRects = frameRects
                    })
                })
            })
        }
    }

    override public func tapActionAtPoint(_ point: CGPoint, gesture: TapLongTapOrDoubleTapGesture, isEstimating: Bool) -> ChatMessageBubbleContentTapAction {
        if let item = self.item, let hit = self.footHits.first(where: { $0.0.contains(point) }) {
            switch hit.1 {
            case let .open(url):
                return ChatMessageBubbleContentTapAction(content: .url(ChatMessageBubbleContentTapAction.Url(url: url, concealed: false)))
            case let .approve(id, version):
                return ChatMessageBubbleContentTapAction(content: .custom({ [weak item] in
                    guard let item else { return }
                    let messageId = item.message.id
                    let interaction = item.controllerInteraction
                    Task { @MainActor in
                        await PaiMocks.approve(id, version: version)
                        interaction.requestMessageUpdate(messageId, false, nil)
                    }
                    DispatchQueue.main.async { interaction.requestMessageUpdate(messageId, false, nil) }
                }))
            }
        }
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
