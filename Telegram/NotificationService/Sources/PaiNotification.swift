import Foundation
import UserNotifications

/// pai's questions answered from the notification itself — and from the watch, which mirrors its buttons. A
/// message from the pai bot that comes with an open question gets the question's options as one-tap actions
/// and a field for anything else; the app sends the answer (`AppDelegate`, `PaiNotificationAnswer`).
///
/// The app leaves the box's address, its token and the bot's user id in `pai.json` in the app group; nothing
/// happens until it has.
enum PaiNotification {
    private struct Config: Decodable {
        let baseURL: String
        let token: String
        let botUserId: String
    }

    private struct Need: Decodable {
        let id: String
        let askId: Int?
        let session: String?
        let question: String
        let options: [String]
        let freeText: Bool?
        let createdAt: Double
    }

    private static let categoryPrefix = "pai.need."
    /// Older categories are dropped past this many, so the set does not grow forever.
    private static let keptCategories = 12

    static func decorate(_ content: UNNotificationContent, appGroupPath: String?, completion: @escaping (UNNotificationContent) -> Void) {
        guard let appGroupPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: appGroupPath + "/pai.json")),
              let config = try? JSONDecoder().decode(Config.self, from: data),
              (content.userInfo["from_id"] as? String) == config.botUserId,
              let url = URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/needs") else {
            completion(content)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 6.0)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let needs = try? JSONDecoder().decode([Need].self, from: data), let need = match(needs, body: content.body) else {
                completion(content)
                return
            }
            attach(need, to: content, completion: completion)
        }.resume()
    }

    /// The question this message is: the one whose text it shows, else one opened in the last two minutes.
    private static func match(_ needs: [Need], body: String) -> Need? {
        let now = Date().timeIntervalSince1970 * 1000.0
        let flatBody = body.replacingOccurrences(of: "\n", with: " ")
        if let shown = needs.first(where: { need in
            let head = String(need.question.replacingOccurrences(of: "\n", with: " ").prefix(40))
            return !head.isEmpty && flatBody.contains(head)
        }) {
            return shown
        }
        return needs.first { now - $0.createdAt < 120_000 }
    }

    private static func attach(_ need: Need, to content: UNNotificationContent, completion: @escaping (UNNotificationContent) -> Void) {
        var actions: [UNNotificationAction] = need.options.prefix(4).enumerated().map { index, option in
            UNNotificationAction(identifier: "pai.option.\(index)", title: option, options: [])
        }
        if need.freeText ?? true {
            actions.append(UNTextInputNotificationAction(identifier: "pai.text", title: need.options.isEmpty ? "Answer" : "Something else…", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Your answer"))
        }
        let identifier = categoryPrefix + need.id
        let category = UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [], options: [])
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            let others = existing.filter { !$0.identifier.hasPrefix(categoryPrefix) }
            let ours = existing.filter { $0.identifier.hasPrefix(categoryPrefix) && $0.identifier != identifier }.sorted { $0.identifier > $1.identifier }.prefix(keptCategories)
            center.setNotificationCategories(others.union(ours).union([category]))

            guard let mutable = content.mutableCopy() as? UNMutableNotificationContent else {
                completion(content)
                return
            }
            mutable.categoryIdentifier = identifier
            var info = mutable.userInfo
            info["paiNeed"] = ["askId": need.askId ?? 0, "session": need.session ?? "", "options": need.options] as [String: Any]
            mutable.userInfo = info
            // The category registers asynchronously; a moment lets the system know it before the banner shows.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                completion(mutable)
            }
        }
    }
}
