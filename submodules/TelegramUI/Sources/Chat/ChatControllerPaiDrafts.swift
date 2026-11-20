import Foundation
import UIKit
import Display
import ComponentFlow
import TelegramPresentationData
import PaiUI

/// The card above an agent's composer for the drafts it wrote and the user has not sent yet (pai web's DraftCard):
/// the oldest pending draft with its channel, recipient, subject and body, Send and Discard. An email reply shows
/// the thread it answers above the body: the last two messages, "N earlier messages" for the rest, each message one
/// folded line (sender · gist · how long ago) that opens its plain text on a tap; the thread scrolls inside 40% of
/// the screen. Folds live in `PaiDraftCard`, so `relayout` redraws the panel with them.
final class PaiDraftsPanelComponent: Component {
    let drafts: [PaiDraft]
    let fold: PaiDraftCard.Fold
    let theme: PresentationTheme
    let resolve: (Int, Bool) -> Void
    let relayout: () -> Void

    init(drafts: [PaiDraft], theme: PresentationTheme, resolve: @escaping (Int, Bool) -> Void, relayout: @escaping () -> Void) {
        self.drafts = drafts
        self.fold = drafts.first.map { PaiDraftCard.fold($0.id) } ?? PaiDraftCard.Fold()
        self.theme = theme
        self.resolve = resolve
        self.relayout = relayout
    }

    static func ==(lhs: PaiDraftsPanelComponent, rhs: PaiDraftsPanelComponent) -> Bool {
        return lhs.drafts == rhs.drafts && lhs.fold == rhs.fold && lhs.theme === rhs.theme
    }

    /// One thread message: a folded line, or the sender and time over the full text.
    private final class MessageView: UIView {
        let lineLabel = UILabel()
        let whenLabel = UILabel()
        let textView = UITextView()
        var index = 0
        var onTap: ((Int) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.lineLabel.lineBreakMode = .byTruncatingTail
            self.whenLabel.font = UIFont.systemFont(ofSize: 12.0)
            self.whenLabel.textAlignment = .right
            self.textView.isEditable = false
            self.textView.isSelectable = true
            self.textView.isScrollEnabled = false
            self.textView.backgroundColor = .clear
            self.textView.textContainerInset = .zero
            self.textView.textContainer.lineFragmentPadding = 0.0
            self.textView.dataDetectorTypes = []
            self.textView.font = UIFont.systemFont(ofSize: 14.0)
            for view in [self.lineLabel, self.whenLabel, self.textView] as [UIView] {
                self.addSubview(view)
            }
            self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapped)))
        }

        required init?(coder: NSCoder) {
            preconditionFailure()
        }

        @objc private func tapped() {
            self.onTap?(self.index)
        }

        func update(message: PaiDraft.ThreadMessage, open: Bool, theme: PresentationTheme, width: CGFloat) -> CGFloat {
            let name = PaiDraftCard.senderName(message.from)
            let line = NSMutableAttributedString(string: name, attributes: [
                .font: UIFont.systemFont(ofSize: 14.0, weight: .semibold),
                .foregroundColor: theme.list.itemPrimaryTextColor
            ])
            if !open {
                line.append(NSAttributedString(string: "  " + PaiDraftCard.gist(message.text), attributes: [
                    .font: UIFont.systemFont(ofSize: 14.0),
                    .foregroundColor: theme.list.itemSecondaryTextColor
                ]))
            }
            self.lineLabel.attributedText = line
            self.whenLabel.text = PaiDraftCard.ago(message.at)
            self.whenLabel.textColor = theme.list.itemSecondaryTextColor

            let lineHeight: CGFloat = 20.0
            let whenWidth = ceil(self.whenLabel.sizeThatFits(CGSize(width: width, height: lineHeight)).width)
            self.whenLabel.frame = CGRect(x: width - whenWidth, y: 0.0, width: whenWidth, height: lineHeight)
            self.lineLabel.frame = CGRect(x: 0.0, y: 0.0, width: max(1.0, width - whenWidth - 8.0), height: lineHeight)

            self.textView.isHidden = !open
            guard open else { return lineHeight }
            self.textView.text = message.text
            self.textView.textColor = theme.list.itemPrimaryTextColor
            self.textView.tintColor = theme.list.itemAccentColor
            let textHeight = ceil(self.textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            self.textView.frame = CGRect(x: 0.0, y: lineHeight + 2.0, width: width, height: textHeight)
            return lineHeight + 2.0 + textHeight
        }
    }

    final class View: UIView {
        private static let inset: CGFloat = 14.0
        private static let bodyMaxHeight: CGFloat = 160.0
        private static let buttonHeight: CGFloat = 34.0

        private let icon = UIImageView()
        private let toLabel = UILabel()
        private let countLabel = UILabel()
        private let subjectLabel = UILabel()
        private let threadScroll = UIScrollView()
        private let earlierButton = UIButton(type: .system)
        private var messageViews: [MessageView] = []
        private let threadSeparator = UIView()
        private let bodyView = UITextView()
        private let discardButton = UIButton(type: .system)
        private let sendButton = UIButton(type: .system)
        private var component: PaiDraftsPanelComponent?

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.icon.contentMode = .scaleAspectFit
            self.toLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
            self.toLabel.lineBreakMode = .byTruncatingMiddle
            self.countLabel.font = UIFont.systemFont(ofSize: 13.0)
            self.countLabel.textAlignment = .right
            self.subjectLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .medium)
            self.subjectLabel.numberOfLines = 2
            self.threadScroll.alwaysBounceVertical = false
            self.earlierButton.titleLabel?.font = UIFont.systemFont(ofSize: 13.0, weight: .medium)
            self.earlierButton.contentHorizontalAlignment = .left
            self.earlierButton.addTarget(self, action: #selector(self.earlierTapped), for: .touchUpInside)
            self.threadScroll.addSubview(self.earlierButton)
            self.bodyView.isEditable = false
            self.bodyView.isSelectable = true
            self.bodyView.backgroundColor = .clear
            self.bodyView.textContainerInset = .zero
            self.bodyView.textContainer.lineFragmentPadding = 0.0
            self.bodyView.font = UIFont.systemFont(ofSize: 15.0)
            self.discardButton.setTitle("Discard", for: .normal)
            self.discardButton.titleLabel?.font = UIFont.systemFont(ofSize: 15.0)
            self.discardButton.addTarget(self, action: #selector(self.discardTapped), for: .touchUpInside)
            self.sendButton.setTitle("Send", for: .normal)
            self.sendButton.titleLabel?.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
            self.sendButton.layer.cornerRadius = View.buttonHeight / 2.0
            self.sendButton.addTarget(self, action: #selector(self.sendTapped), for: .touchUpInside)
            for view in [self.icon, self.toLabel, self.countLabel, self.subjectLabel, self.threadScroll, self.threadSeparator, self.bodyView, self.discardButton, self.sendButton] as [UIView] {
                self.addSubview(view)
            }
        }

        required init?(coder: NSCoder) {
            preconditionFailure()
        }

        @objc private func earlierTapped() {
            guard let component = self.component, let draft = component.drafts.first else { return }
            PaiDraftCard.toggleEarlier(draft.id)
            component.relayout()
        }

        @objc private func sendTapped() {
            guard let component = self.component, let draft = component.drafts.first else { return }
            component.resolve(draft.id, true)
        }

        @objc private func discardTapped() {
            guard let component = self.component, let draft = component.drafts.first else { return }
            component.resolve(draft.id, false)
        }

        private func messageTapped(_ index: Int) {
            guard let component = self.component, let draft = component.drafts.first else { return }
            PaiDraftCard.toggle(message: index, of: draft.id)
            component.relayout()
        }

        func update(component: PaiDraftsPanelComponent, availableSize: CGSize, transition: ComponentTransition) -> CGSize {
            let previousDraft = self.component?.drafts.first?.id
            self.component = component
            guard let draft = component.drafts.first else {
                return CGSize(width: availableSize.width, height: 0.0)
            }
            let theme = component.theme
            let inset = View.inset
            let width = availableSize.width - inset * 2.0
            var y: CGFloat = 12.0

            // Channel, recipient and, with more than one waiting, which of them this is.
            self.icon.image = UIImage(systemName: PaiDraftCard.symbol(channel: draft.channel))
            self.icon.tintColor = theme.list.itemAccentColor
            self.icon.frame = CGRect(x: inset, y: y + 1.0, width: 18.0, height: 18.0)
            self.countLabel.text = component.drafts.count > 1 ? "1 of \(component.drafts.count)" : nil
            self.countLabel.textColor = theme.list.itemSecondaryTextColor
            let countWidth = ceil(self.countLabel.sizeThatFits(CGSize(width: width, height: 20.0)).width)
            self.countLabel.frame = CGRect(x: inset + width - countWidth, y: y, width: countWidth, height: 20.0)
            let to = draft.fields.to.flatMap { $0.isEmpty ? nil : $0 }
            self.toLabel.text = to.map { "To \($0)" } ?? "Draft"
            self.toLabel.textColor = theme.list.itemPrimaryTextColor
            self.toLabel.frame = CGRect(x: inset + 26.0, y: y, width: max(1.0, width - 26.0 - countWidth - 8.0), height: 20.0)
            y += 24.0

            if let subject = draft.fields.subject, !subject.isEmpty {
                self.subjectLabel.isHidden = false
                self.subjectLabel.text = subject
                self.subjectLabel.textColor = theme.list.itemPrimaryTextColor
                let height = ceil(self.subjectLabel.sizeThatFits(CGSize(width: width, height: 40.0)).height)
                self.subjectLabel.frame = CGRect(x: inset, y: y, width: width, height: height)
                y += height + 6.0
            } else {
                self.subjectLabel.isHidden = true
            }

            // The thread the reply answers, scrolling inside its cap.
            let thread = draft.threadMessages
            let fold = component.fold
            let shown = PaiDraftCard.shown(thread, fold: fold)
            while self.messageViews.count < shown.count {
                let view = MessageView()
                view.onTap = { [weak self] index in self?.messageTapped(index) }
                self.threadScroll.addSubview(view)
                self.messageViews.append(view)
            }
            while self.messageViews.count > shown.count {
                self.messageViews.removeLast().removeFromSuperview()
            }
            if thread.isEmpty {
                self.threadScroll.isHidden = true
                self.threadSeparator.isHidden = true
            } else {
                self.threadScroll.isHidden = false
                self.threadSeparator.isHidden = false
                var contentY: CGFloat = 0.0
                if let label = PaiDraftCard.earlierLabel(thread, fold: fold) {
                    self.earlierButton.isHidden = false
                    self.earlierButton.setTitle(label, for: .normal)
                    self.earlierButton.setTitleColor(theme.list.itemAccentColor, for: .normal)
                    self.earlierButton.frame = CGRect(x: 0.0, y: 0.0, width: width, height: 24.0)
                    contentY += 28.0
                } else {
                    self.earlierButton.isHidden = true
                }
                for (slot, index) in shown.enumerated() {
                    let view = self.messageViews[slot]
                    view.index = index
                    let height = view.update(message: thread[index], open: fold.open.contains(index), theme: theme, width: width)
                    view.frame = CGRect(x: 0.0, y: contentY, width: width, height: height)
                    contentY += height + 8.0
                }
                contentY -= 8.0
                let cap = floor(UIScreen.main.bounds.height * 0.4)
                let threadHeight = min(contentY, cap)
                self.threadScroll.frame = CGRect(x: inset, y: y, width: width, height: threadHeight)
                self.threadScroll.contentSize = CGSize(width: width, height: contentY)
                if previousDraft != draft.id {
                    self.threadScroll.contentOffset = CGPoint(x: 0.0, y: max(0.0, contentY - threadHeight))
                }
                y += threadHeight + 8.0
                self.threadSeparator.backgroundColor = theme.list.itemPlainSeparatorColor
                self.threadSeparator.frame = CGRect(x: inset, y: y, width: width, height: UIScreenPixel)
                y += 8.0
            }

            // The words to send, selectable; a long one scrolls.
            self.bodyView.text = draft.fields.body ?? ""
            self.bodyView.textColor = theme.list.itemPrimaryTextColor
            self.bodyView.tintColor = theme.list.itemAccentColor
            let bodyHeight = min(View.bodyMaxHeight, ceil(self.bodyView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
            self.bodyView.isScrollEnabled = bodyHeight >= View.bodyMaxHeight
            self.bodyView.frame = CGRect(x: inset, y: y, width: width, height: bodyHeight)
            y += bodyHeight + 10.0

            self.sendButton.backgroundColor = theme.list.itemCheckColors.fillColor
            self.sendButton.setTitleColor(theme.list.itemCheckColors.foregroundColor, for: .normal)
            self.discardButton.setTitleColor(theme.list.itemDestructiveColor, for: .normal)
            let sendWidth: CGFloat = 84.0
            let discardWidth: CGFloat = 84.0
            self.sendButton.frame = CGRect(x: inset + width - sendWidth, y: y, width: sendWidth, height: View.buttonHeight)
            self.discardButton.frame = CGRect(x: inset + width - sendWidth - 8.0 - discardWidth, y: y, width: discardWidth, height: View.buttonHeight)
            y += View.buttonHeight + 12.0

            return CGSize(width: availableSize.width, height: y)
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, transition: transition)
    }
}
