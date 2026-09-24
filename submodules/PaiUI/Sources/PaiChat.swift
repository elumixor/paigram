import Foundation
import Postbox
import TelegramCore

/// What the Telegram screens need to know about the pai bot's chat.
public enum PaiChat {
    private static let lastThreadKey = "pai.lastThreadId"

    /// Whether a chat is the pai bot's.
    public static func isBot(_ peer: Peer?) -> Bool {
        guard let user = peer as? TelegramUser, user.botInfo != nil else { return false }
        return user.addressName?.lowercased() == PaiSecrets.botUsername.lowercased()
    }

    /// The topic the chat was on last time, so it opens there again.
    public static var lastThreadId: Int64? {
        get {
            let value = UserDefaults.standard.object(forKey: lastThreadKey) as? Int64
            return value == 0 ? nil : value
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: lastThreadKey) }
    }

    /// Posted on the main thread whenever whether any thread is running or waiting changes; `object` is that Bool.
    public static let activityChanged = Notification.Name("pai.activityChanged")
}
