import Foundation

/// The other half of the notification extension's quick answers (`PaiNotification` there): what it needs to
/// reach the box, and sending the answer a tap on a notification's button picked.
public enum PaiNotificationAnswer {
    /// The app group's `pai.json`, where the notification extension reads how to reach the box.
    private static var path: String? {
        guard let bundleId = Bundle.main.bundleIdentifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.\(bundleId)")?.appendingPathComponent("pai.json").path
    }

    /// Leaves the box's address, this phone's token and the bot's user id in the app group, where the extension
    /// reads them; signed out, the file is removed. The bot's id is known once its chat has been open.
    public static func writeConfig(basePath: String, botUserId: Int64) {
        write(botUserId: String(botUserId))
    }

    /// At launch and after a sign-in or out: mail and WhatsApp pushes need the token for their senders' pictures
    /// whether or not the bot's chat was ever opened.
    static func refreshConfig() {
        write(botUserId: nil)
    }

    private static func write(botUserId: String?) {
        guard let path else { return }
        guard let token = PaiAuth.token else {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        let existing = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        var config = ["baseURL": PaiSecrets.baseURL, "token": token]
        if let botUserId = botUserId ?? existing["botUserId"] {
            config["botUserId"] = botUserId
        }
        if existing == config { return }
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Whether a notification action is one of pai's answers.
    public static func handles(_ actionIdentifier: String) -> Bool {
        actionIdentifier.hasPrefix("pai.option.") || actionIdentifier == "pai.text"
    }

    /// Sends the picked option (or the typed text) to the ask or session the notification was about.
    public static func answer(actionIdentifier: String, userText: String?, userInfo: [AnyHashable: Any], completion: @escaping () -> Void) {
        guard #available(iOS 16.0, *), let need = userInfo["paiNeed"] as? [String: Any] else {
            completion()
            return
        }
        let options = need["options"] as? [String] ?? []
        let text: String?
        if actionIdentifier == "pai.text" {
            text = userText?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let index = Int(actionIdentifier.dropFirst("pai.option.".count)) ?? -1
            text = options.indices.contains(index) ? options[index] : nil
        }
        guard let text, !text.isEmpty else {
            completion()
            return
        }
        guard let id = need["id"] as? String, !id.isEmpty else {
            completion()
            return
        }
        Task {
            try? await PaiClient().answer(need: id, text: text)
            completion()
        }
    }
}
