import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore

/// The app's half of the email chats (TelegramCore holds the rest): pointing TelegramCore at the box, keeping the
/// box's mailboxes and addresses at hand for titles, and telling the box where to push.
public enum EmailChats {
    private static let state = Atomic<EmailState>(value: .empty)
    private static var engine: TelegramEngine?
    private static let stateDisposable = MetaDisposable()
    private static var activeObserver: NSObjectProtocol?
    
    private static var pushToken: Data?
    private static var authObserver: NSObjectProtocol?

    /// Before any account starts: email and WhatsApp sync and send through the box, once this phone is signed in to
    /// pai; a sign-in later configures them then and registers for pushes.
    public static func configure() {
        PaiPerf.first("app.configure")
        PaiChat.preload()
        PaiAuth.apply()
        if self.authObserver == nil {
            self.authObserver = NotificationCenter.default.addObserver(forName: PaiAuth.didChange, object: nil, queue: .main, using: { _ in
                if let pushToken = self.pushToken {
                    self.register(pushToken: pushToken)
                }
                self.syncNow()
            })
        }
    }
    
    /// The account whose chats sync now: its state is followed, and each return to the app syncs.
    public static func attach(engine: TelegramEngine?) {
        self.engine = engine
        self.stateDisposable.set(engine?.email.state().start(next: { value in
            let _ = self.state.swap(value)
        }))
        if self.activeObserver == nil {
            self.activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: { _ in
                self.syncNow()
            })
        }
    }
    
    public static func syncNow() {
        self.engine?.email.syncNow()
    }
    
    /// Under an email chat's title: the correspondent's address.
    public static func subtitle(peerId: EnginePeer.Id) -> String? {
        guard peerId.isEmail else {
            return nil
        }
        return self.state.with { $0.contact(id: peerId.id._internalGetInt64Value())?.address }
    }
    
    /// The mailboxes as the user's mail client names them, for the settings screen.
    public static var accounts: [EmailAccountData] {
        return self.state.with { $0.accounts }
    }
    
    public static var chatCount: Int {
        return self.state.with { $0.contacts.count }
    }
    
    /// Whether a notification is one of the box's email pushes.
    public static func isEmailPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        return userInfo["email"] != nil
    }
    
    /// The device token, so the box can push new mail here (production APNs unless this is a debug build).
    public static func register(pushToken: Data) {
        self.pushToken = pushToken
        guard let token = PaiAuth.token, let url = URL(string: PaiSecrets.baseURL + "/push/devices") else {
            return
        }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let body: [String: String] = [
            "token": pushToken.map { String(format: "%02x", $0) }.joined(),
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "env": environment
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request, completionHandler: { _, response, error in
            if let error {
                Logger.shared.log("Email", "push registration failed: \(error)")
            } else if let status = (response as? HTTPURLResponse)?.statusCode, status >= 300 {
                Logger.shared.log("Email", "push registration failed: \(status)")
            }
        }).resume()
    }
}
