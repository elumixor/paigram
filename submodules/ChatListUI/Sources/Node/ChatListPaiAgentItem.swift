import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import PaiUI

/// One of pai's agents in the chat list: its face, name, role and what it does, with whether it works or waits on the user.
final class ChatListPaiAgentItem: ListViewItem {
    let presentationData: ChatListPresentationData
    let row: PaiAgentRow
    let action: (String) -> Void

    let selectable: Bool = true

    init(presentationData: ChatListPresentationData, row: PaiAgentRow, action: @escaping (String) -> Void) {
        self.presentationData = presentationData
        self.row = row
        self.action = action
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = ChatListPaiAgentItemNode()
            let (nodeLayout, apply) = node.asyncLayout()(self, params, nextItem is ChatListPaiAgentItem)
            node.insets = nodeLayout.insets
            node.contentSize = nodeLayout.contentSize
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in
                        apply()
                    })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? ChatListPaiAgentItemNode else {
                return
            }
            let layout = nodeValue.asyncLayout()
            async {
                let (nodeLayout, apply) = layout(self, params, nextItem is ChatListPaiAgentItem)
                Queue.mainQueue().async {
                    completion(nodeLayout, { _ in
                        apply()
                    })
                }
            }
        }
    }

    func selected(listView: ListView) {
        listView.clearHighlightAnimated(true)
        self.action(self.row.slug)
    }
}

private let orange = UIColor(rgb: 0xff9500)

final class ChatListPaiAgentItemNode: ListViewItemNode {
    private static let height: CGFloat = 64.0
    private static let avatarSize: CGFloat = 44.0

    private let backgroundNode = ASDisplayNode()
    private let highlightNode = ASDisplayNode()
    private let separatorNode = ASDisplayNode()
    private let avatarBackgroundNode = ASDisplayNode()
    private let initialsNode = ImmediateTextNode()
    private let avatarNode = ASImageNode()
    private let ringNode = ASDisplayNode()
    private let nameNode = ImmediateTextNode()
    private let roleBackgroundNode = ASDisplayNode()
    private let roleNode = ImmediateTextNode()
    private let statusNode = ImmediateTextNode()
    private let jobNode = ImmediateTextNode()

    private var item: ChatListPaiAgentItem?
    private var avatarUrl: String?
    private let avatarDisposable = MetaDisposable()

    required init() {
        super.init(layerBacked: false)
        self.backgroundNode.isLayerBacked = true
        self.highlightNode.isLayerBacked = true
        self.highlightNode.alpha = 0.0
        self.separatorNode.isLayerBacked = true
        self.avatarBackgroundNode.isLayerBacked = true
        self.avatarBackgroundNode.cornerRadius = Self.avatarSize / 2.0
        self.avatarNode.isLayerBacked = true
        self.avatarNode.cornerRadius = Self.avatarSize / 2.0
        self.avatarNode.clipsToBounds = true
        self.avatarNode.contentMode = .scaleAspectFill
        self.roleBackgroundNode.isLayerBacked = true
        self.roleBackgroundNode.cornerRadius = 4.0
        self.nameNode.maximumNumberOfLines = 1
        self.jobNode.maximumNumberOfLines = 1
        self.statusNode.maximumNumberOfLines = 1
        self.roleNode.maximumNumberOfLines = 1

        for node in [self.backgroundNode, self.highlightNode, self.separatorNode, self.avatarBackgroundNode, self.initialsNode, self.avatarNode, self.ringNode, self.roleBackgroundNode, self.roleNode, self.nameNode, self.statusNode, self.jobNode] {
            self.addSubnode(node)
        }
    }

    deinit {
        self.avatarDisposable.dispose()
    }

    override func layoutForParams(_ params: ListViewItemLayoutParams, item: ListViewItem, previousItem: ListViewItem?, nextItem: ListViewItem?) {
        guard let item = item as? ChatListPaiAgentItem else {
            return
        }
        let (_, apply) = self.asyncLayout()(item, params, nextItem is ChatListPaiAgentItem)
        apply()
    }

    override func setHighlighted(_ highlighted: Bool, at point: CGPoint, animated: Bool) {
        super.setHighlighted(highlighted, at: point, animated: animated)
        let transition: ContainedViewLayoutTransition = (animated && !highlighted) ? .animated(duration: 0.3, curve: .easeInOut) : .immediate
        transition.updateAlpha(node: self.highlightNode, alpha: highlighted ? 1.0 : 0.0)
    }

    func asyncLayout() -> (_ item: ChatListPaiAgentItem, _ params: ListViewItemLayoutParams, _ separated: Bool) -> (ListViewItemNodeLayout, () -> Void) {
        return { item, params, separated in
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: Self.height), insets: UIEdgeInsets())
            return (layout, { [weak self] in
                guard let self else {
                    return
                }
                self.item = item
                self.contentSize = layout.contentSize
                self.insets = layout.insets
                self.apply(item: item, params: params, separated: separated)
            })
        }
    }

    private func apply(item: ChatListPaiAgentItem, params: ListViewItemLayoutParams, separated: Bool) {
        let theme = item.presentationData.theme
        let row = item.row
        let size = CGSize(width: params.width, height: Self.height)
        let scale = item.presentationData.fontSize.baseDisplaySize / 17.0

        self.backgroundNode.backgroundColor = theme.chatList.itemBackgroundColor
        self.highlightNode.backgroundColor = theme.chatList.itemHighlightedBackgroundColor
        self.separatorNode.backgroundColor = theme.chatList.itemSeparatorColor
        self.backgroundNode.frame = CGRect(origin: .zero, size: size)
        self.highlightNode.frame = CGRect(origin: .zero, size: size)

        let statusColor: UIColor
        switch row.state {
        case .running: statusColor = theme.list.itemAccentColor
        case .blocked, .paused: statusColor = orange
        case .idle: statusColor = theme.chatList.dateTextColor
        }

        // Face
        let avatarFrame = CGRect(x: params.leftInset + 14.0, y: floor((Self.height - Self.avatarSize) / 2.0), width: Self.avatarSize, height: Self.avatarSize)
        self.avatarBackgroundNode.frame = avatarFrame
        self.avatarBackgroundNode.backgroundColor = UIColor(hue: PaiAvatars.hue(row.slug), saturation: 0.45, brightness: 0.72, alpha: 1.0)
        self.initialsNode.attributedText = NSAttributedString(string: PaiAvatars.initials(row.name), font: Font.semibold(16.0), textColor: .white)
        let initialsSize = self.initialsNode.updateLayout(avatarFrame.size)
        self.initialsNode.frame = CGRect(origin: CGPoint(x: avatarFrame.midX - initialsSize.width / 2.0, y: avatarFrame.midY - initialsSize.height / 2.0), size: initialsSize)
        self.avatarNode.frame = avatarFrame
        self.updateAvatar(url: row.avatar)
        self.ringNode.frame = avatarFrame.insetBy(dx: -3.5, dy: -3.5)
        self.updateRing(state: row.state, color: statusColor)
        self.avatarNode.alpha = row.state == .paused ? 0.6 : 1.0

        // Text
        let textLeft = avatarFrame.maxX + 12.0
        let right = params.width - params.rightInset - 14.0

        self.statusNode.attributedText = NSAttributedString(string: row.statusText, font: Font.regular(floor(14.0 * scale)), textColor: statusColor)
        let statusSize = self.statusNode.updateLayout(CGSize(width: 140.0, height: 30.0))

        self.nameNode.attributedText = NSAttributedString(string: row.name, font: Font.semibold(floor(16.0 * scale)), textColor: row.state == .blocked ? orange : theme.chatList.titleColor)
        let nameMax = max(40.0, right - statusSize.width - 8.0 - textLeft)
        var nameSize = self.nameNode.updateLayout(CGSize(width: nameMax, height: 30.0))

        var roleSize = CGSize()
        if let role = row.role, !role.isEmpty {
            self.roleNode.isHidden = false
            self.roleBackgroundNode.isHidden = false
            self.roleNode.attributedText = NSAttributedString(string: role, font: Font.medium(11.0), textColor: theme.chatList.dateTextColor)
            let roleMax = max(0.0, nameMax - min(nameSize.width, nameMax * 0.55) - 6.0 - 10.0)
            roleSize = self.roleNode.updateLayout(CGSize(width: roleMax, height: 20.0))
            nameSize = self.nameNode.updateLayout(CGSize(width: nameMax - roleSize.width - 16.0, height: 30.0))
        } else {
            self.roleNode.isHidden = true
            self.roleBackgroundNode.isHidden = true
        }

        let jobText = row.job.isEmpty ? (row.role ?? "") : row.job
        self.jobNode.attributedText = NSAttributedString(string: jobText, font: Font.regular(floor(15.0 * scale)), textColor: theme.chatList.messageTextColor)
        let jobSize = self.jobNode.updateLayout(CGSize(width: max(0.0, right - textLeft), height: 30.0))

        let blockHeight = nameSize.height + 3.0 + jobSize.height
        let top = floor((Self.height - blockHeight) / 2.0)
        let nameFrame = CGRect(origin: CGPoint(x: textLeft, y: top), size: nameSize)
        self.nameNode.frame = nameFrame
        if !self.roleNode.isHidden {
            let pillFrame = CGRect(x: nameFrame.maxX + 6.0, y: nameFrame.midY - (roleSize.height + 3.0) / 2.0, width: roleSize.width + 10.0, height: roleSize.height + 3.0)
            self.roleBackgroundNode.frame = pillFrame
            self.roleBackgroundNode.backgroundColor = theme.chatList.dateTextColor.withAlphaComponent(0.14)
            self.roleNode.frame = CGRect(origin: CGPoint(x: pillFrame.minX + 5.0, y: pillFrame.minY + 1.5), size: roleSize)
        }
        self.statusNode.frame = CGRect(origin: CGPoint(x: right - statusSize.width, y: nameFrame.midY - statusSize.height / 2.0), size: statusSize)
        self.jobNode.frame = CGRect(origin: CGPoint(x: textLeft, y: nameFrame.maxY + 3.0), size: jobSize)

        self.separatorNode.isHidden = !separated
        self.separatorNode.frame = CGRect(x: textLeft, y: Self.height - UIScreenPixel, width: max(0.0, params.width - textLeft), height: UIScreenPixel)

        self.accessibilityLabel = [row.name, row.role, row.statusText, jobText].compactMap { $0 }.joined(separator: ", ")
        self.isAccessibilityElement = true
        self.accessibilityTraits = .button
    }

    private func updateAvatar(url: String?) {
        guard url != self.avatarUrl else {
            return
        }
        self.avatarUrl = url
        guard let url else {
            self.avatarNode.image = nil
            self.avatarDisposable.set(nil)
            return
        }
        if let image = PaiAvatars.cached(url) {
            self.avatarNode.image = image
            self.avatarDisposable.set(nil)
            return
        }
        self.avatarNode.image = nil
        self.avatarDisposable.set((PaiAvatars.image(url) |> deliverOnMainQueue).startStrict(next: { [weak self] image in
            guard let self, self.avatarUrl == url, let image else {
                return
            }
            self.avatarNode.image = image
        }))
    }

    /// A spinning arc while it works, a full ring while it waits on the user or is stopped, nothing when idle.
    private func updateRing(state: PaiAgentRow.State, color: UIColor) {
        let layer: CAShapeLayer
        if let existing = self.ringNode.layer.sublayers?.first as? CAShapeLayer {
            layer = existing
        } else {
            layer = CAShapeLayer()
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 2.0
            layer.lineCap = .round
            self.ringNode.layer.addSublayer(layer)
        }
        let bounds = self.ringNode.bounds
        layer.frame = bounds
        layer.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 1.0, dy: 1.0)).cgPath
        layer.strokeColor = color.cgColor
        switch state {
        case .running:
            layer.isHidden = false
            layer.strokeEnd = 0.72
            if layer.animation(forKey: "spin") == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0.0
                spin.toValue = Double.pi * 2.0
                spin.duration = 1.4
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                layer.add(spin, forKey: "spin")
            }
        case .blocked, .paused:
            layer.isHidden = false
            layer.strokeEnd = 1.0
            layer.removeAnimation(forKey: "spin")
        case .idle:
            layer.isHidden = true
            layer.removeAnimation(forKey: "spin")
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: duration * 0.5)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: duration * 0.5, removeOnCompletion: false)
    }
}
