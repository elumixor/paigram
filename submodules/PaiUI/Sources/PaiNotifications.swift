import Foundation

/// The other half of the notification extension's quick answers (`PaiNotification` there): what it needs to
/// reach the box, and sending the answer a tap on a notification's button picked.
public enum PaiNotificationAnswer {
    /// Leaves the box's address, token and the bot's user id in the app group, where the extension reads them.
    /// `basePath` is Telegram's data directory inside the app group.
    public static func writeConfig(basePath: String, botUserId: Int64) {
        let path = (basePath as NSString).deletingLastPathComponent + "/pai.json"
        let config = ["baseURL": PaiSecrets.baseURL, "token": PaiSecrets.token, "botUserId": String(botUserId)]
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return }
        if (try? Data(contentsOf: URL(fileURLWithPath: path))) == data { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
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
