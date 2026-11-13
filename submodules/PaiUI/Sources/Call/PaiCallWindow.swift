import SwiftUI
import UIKit

/// The call's own window above the app: the whole screen while it is open, a pill at the top when minimized.
/// A window of its own keeps the call out of Telegram's controller tree, so any screen can start one.
@available(iOS 16.0, *)
enum PaiCallWindow {
    private static var window: UIWindow?

    static func show() {
        if window == nil {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
            let created: UIWindow = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
            created.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
            created.backgroundColor = .clear
            let host = UIHostingController(rootView: PaiCallRoot().environmentObject(PaiCall.shared))
            host.view.backgroundColor = .clear
            created.rootViewController = host
            window = created
        }
        layout()
        window?.isHidden = false
    }

    static func hide() {
        window?.isHidden = true
        window = nil
    }

    static func layout() {
        guard let window else { return }
        let bounds = window.windowScene?.screen.bounds ?? UIScreen.main.bounds
        if PaiCall.shared.minimized {
            let top = window.windowScene?.windows.first(where: { $0 !== window })?.safeAreaInsets.top ?? 47
            window.frame = CGRect(x: 0, y: 0, width: bounds.width, height: top + 56)
        } else {
            window.frame = bounds
        }
    }
}
