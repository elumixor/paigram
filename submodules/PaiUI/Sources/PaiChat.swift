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

    /// The bot's peer id, learned when its history is first built; lets list items tell the chat apart.
    public static var botPeerId: PeerId?

    /// The topic the chat was on last time, so it opens there again.
    public static var lastThreadId: Int64? {
        get {
            let value = UserDefaults.standard.object(forKey: lastThreadKey) as? Int64
            return value == 0 ? nil : value
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: lastThreadKey) }
    }

    private static let pinnedKey = "pai.pinnedProjects"

    /// Projects pinned to the top of the list, in the order they were pinned.
    public static var pinnedProjects: [String] {
        get { UserDefaults.standard.stringArray(forKey: pinnedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: pinnedKey) }
    }

    /// Posted on the main thread whenever whether any thread is running or waiting changes; `object` is that Bool.
    public static let activityChanged = Notification.Name("pai.activityChanged")
}

// MARK: Starting a thread in a project

extension PaiChat {
    private static let prefixPattern = try! NSRegularExpression(pattern: "^/project[ \\t]+([A-Za-z0-9._-]+)[ \\t]*\\n?")

    /// The project the next new thread should start in; nil is the general workspace.
    public static var pendingProject: PaiProject? {
        didSet { NotificationCenter.default.post(name: projectChanged, object: nil) }
    }
    public static let projectChanged = Notification.Name("pai.projectChanged")

    /// The first line the bot reads to start the thread in a project (`pai-telegram` strips it too).
    public static func prefixed(_ text: String, project: PaiProject?) -> String {
        guard let project else { return text }
        return "/project \(project.slug)\n\(text)"
    }

    /// UTF-16 length of a leading `/project <slug>` line, or 0.
    public static func prefixLength(in text: String) -> Int {
        prefixPattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.range.length ?? 0
    }
}
