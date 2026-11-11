import Foundation
import UIKit
import Display
import ComponentFlow
import SwiftSignalKit
import TelegramPresentationData
import PaiUI

/// The strip above the bot chat's composer: the faces of the agents at work or waiting on the user, how many,
/// and what they do. A tap opens the agent it names.
final class PaiRailPanelComponent: Component {
    let rail: PaiRail
    let theme: PresentationTheme
    let open: (String) -> Void

    init(rail: PaiRail, theme: PresentationTheme, open: @escaping (String) -> Void) {
        self.rail = rail
        self.theme = theme
        self.open = open
    }

    static func ==(lhs: PaiRailPanelComponent, rhs: PaiRailPanelComponent) -> Bool {
        return lhs.rail == rhs.rail && lhs.theme === rhs.theme
    }

    final class View: UIView {
        private static let faceSize: CGFloat = 28.0
        private static let height: CGFloat = 50.0

        private var faceViews: [UIImageView] = []
        private var faceDisposables: [String: Disposable] = [:]
        private let dot = UIView()
        private let titleLabel = UILabel()
        private let subtitleLabel = UILabel()
        private let chevron = UIImageView()
        private var component: PaiRailPanelComponent?

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.dot.layer.cornerRadius = 4.0
            self.titleLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
            self.subtitleLabel.font = UIFont.systemFont(ofSize: 13.0)
            self.chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold))
            self.chevron.contentMode = .center
            for view in [self.dot, self.titleLabel, self.subtitleLabel, self.chevron] as [UIView] {
                self.addSubview(view)
            }
            self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapped)))
        }

        required init?(coder: NSCoder) {
            preconditionFailure()
        }

        deinit {
            self.faceDisposables.values.forEach { $0.dispose() }
        }

        @objc private func tapped() {
            guard let component = self.component, let target = component.rail.target else {
                return
            }
            component.open(target)
        }

        private func startPulse(_ on: Bool) {
            if on {
                guard self.dot.layer.animation(forKey: "pulse") == nil else { return }
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.3
                pulse.duration = 0.9
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                self.dot.layer.add(pulse, forKey: "pulse")
            } else {
                self.dot.layer.removeAnimation(forKey: "pulse")
            }
        }

        private func setFace(_ view: UIImageView, _ face: PaiRail.Face) {
            if let url = face.avatar, let image = PaiAvatars.cached(url) {
                view.image = image
                return
            }
            view.image = PaiAvatars.placeholder(name: face.name, slug: face.slug, size: View.faceSize)
            guard let url = face.avatar, self.faceDisposables[url] == nil else {
                return
            }
            self.faceDisposables[url] = (PaiAvatars.image(url) |> deliverOnMainQueue).start(next: { [weak self] image in
                guard let self, let image else { return }
                for (index, current) in (self.component?.rail.faces ?? []).enumerated() where current.avatar == url && index < self.faceViews.count {
                    self.faceViews[index].image = image
                }
            })
        }

        func update(component: PaiRailPanelComponent, availableSize: CGSize, transition: ComponentTransition) -> CGSize {
            self.component = component
            let rail = component.rail
            let theme = component.theme

            while self.faceViews.count < rail.faces.count {
                let view = UIImageView()
                view.contentMode = .scaleAspectFill
                view.clipsToBounds = true
                view.layer.cornerRadius = View.faceSize / 2.0
                view.layer.borderWidth = 1.5
                self.insertSubview(view, at: 0)
                self.faceViews.append(view)
            }
            while self.faceViews.count > rail.faces.count {
                self.faceViews.removeLast().removeFromSuperview()
            }

            let height = View.height
            let overlap: CGFloat = 9.0
            var x: CGFloat = 14.0
            for (index, face) in rail.faces.enumerated() {
                let view = self.faceViews[index]
                view.layer.borderColor = theme.list.plainBackgroundColor.withAlphaComponent(0.8).cgColor
                view.layer.zPosition = CGFloat(rail.faces.count - index)
                self.setFace(view, face)
                view.frame = CGRect(x: x, y: (height - View.faceSize) / 2.0, width: View.faceSize, height: View.faceSize)
                x += View.faceSize - overlap
            }
            x += overlap + 10.0

            let accent = rail.isWaiting ? UIColor.systemOrange : theme.list.itemAccentColor
            self.dot.backgroundColor = accent
            self.startPulse(!rail.isWaiting)

            self.chevron.isHidden = rail.target == nil
            self.chevron.tintColor = theme.list.itemSecondaryTextColor
            let chevronWidth: CGFloat = rail.target == nil ? 0.0 : 24.0
            self.chevron.frame = CGRect(x: availableSize.width - 12.0 - chevronWidth, y: 0.0, width: chevronWidth, height: height)

            let textWidth = max(1.0, availableSize.width - x - 12.0 - chevronWidth)
            self.titleLabel.text = rail.title
            self.titleLabel.textColor = theme.list.itemPrimaryTextColor
            self.subtitleLabel.text = rail.subtitle
            self.subtitleLabel.textColor = theme.list.itemSecondaryTextColor
            self.subtitleLabel.isHidden = rail.subtitle.isEmpty

            let titleHeight: CGFloat = 19.0
            let subtitleHeight: CGFloat = rail.subtitle.isEmpty ? 0.0 : 17.0
            let top = (height - titleHeight - subtitleHeight) / 2.0
            self.dot.frame = CGRect(x: x, y: top + (titleHeight - 8.0) / 2.0, width: 8.0, height: 8.0)
            self.titleLabel.frame = CGRect(x: x + 14.0, y: top, width: textWidth - 14.0, height: titleHeight)
            self.subtitleLabel.frame = CGRect(x: x, y: top + titleHeight, width: textWidth, height: subtitleHeight)

            return CGSize(width: availableSize.width, height: height)
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, transition: transition)
    }
}
