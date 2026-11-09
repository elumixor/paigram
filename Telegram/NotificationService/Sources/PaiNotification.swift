import Foundation
import Intents
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

    /// What the box needs to reach it again: enough for a sender's picture.
    private struct BoxConfig: Decodable {
        let baseURL: String
        let token: String
    }

    private struct Need: Decodable {
        let id: String
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
            info["paiNeed"] = ["id": need.id, "options": need.options] as [String: Any]
            mutable.userInfo = info
            // The category registers asynchronously; a moment lets the system know it before the banner shows.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                completion(mutable)
            }
        }
    }

    // MARK: Asks pushed by the box

    /// A question the box pushed itself (an ask, a session's AskUserQuestion): it carries `paiNeed` with the options,
    /// so no `/needs` round trip is needed. The buttons show on the paired watch too.
    static func isBoxNeed(_ userInfo: [AnyHashable: Any]) -> Bool {
        return userInfo["paiNeed"] is [String: Any] && userInfo["from_id"] == nil
    }

    static func decorateBoxNeed(_ content: UNNotificationContent, completion: @escaping (UNNotificationContent) -> Void) {
        guard let info = content.userInfo["paiNeed"] as? [String: Any], let id = info["id"] as? String, !id.isEmpty else {
            completion(content)
            return
        }
        let need = Need(id: id, question: info["question"] as? String ?? content.body, options: info["options"] as? [String] ?? [], freeText: info["freeText"] as? Bool, createdAt: 0)
        attach(need, to: content, completion: completion)
    }

    // MARK: Mail and WhatsApp

    /// A push the box sent itself (mail, WhatsApp), not one of Telegram's: it carries `pai` with who wrote, the chat
    /// it belongs to and where the sender's picture is.
    static func isBoxPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        return userInfo["pai"] is [String: Any]
    }

    /// Shown as a message from a person, the way Telegram's own are: their picture on the lock screen, one stack per
    /// chat. A picture that does not come in time is left out rather than holding the banner back.
    static func decorateBoxPush(_ content: UNNotificationContent, appGroupPath: String?, completion: @escaping (UNNotificationContent) -> Void) {
        guard let info = content.userInfo["pai"] as? [String: Any], let mutable = content.mutableCopy() as? UNMutableNotificationContent else {
            completion(content)
            return
        }
        let thread = info["thread"] as? String ?? content.threadIdentifier
        if !thread.isEmpty {
            mutable.threadIdentifier = thread
        }
        let config = appGroupPath
            .flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0 + "/pai.json")) }
            .flatMap { try? JSONDecoder().decode(BoxConfig.self, from: $0) }
        let base = config?.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let senderURL = (info["avatar"] as? String).flatMap { path in base.flatMap { URL(string: $0 + path) } }
        let groupURL = (info["groupAvatar"] as? String).flatMap { path in base.flatMap { URL(string: $0 + path) } }
        let pictureURL = (info["image"] as? String).flatMap { path in base.flatMap { URL(string: $0 + path) } }

        let group = DispatchGroup()
        var senderImage: INImage?
        var groupImage: INImage?
        var picture: Data?
        if let config {
            if let pictureURL {
                group.enter()
                var request = URLRequest(url: pictureURL, timeoutInterval: 5.0)
                request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
                URLSession.shared.dataTask(with: request) { data, response, _ in
                    DispatchQueue.main.async {
                        if let data, !data.isEmpty, (response as? HTTPURLResponse)?.statusCode == 200 {
                            picture = data
                        }
                        group.leave()
                    }
                }.resume()
            }
            for (url, assign) in [(senderURL, { (image: INImage) in senderImage = image }), (groupURL, { (image: INImage) in groupImage = image })] {
                guard let url else { continue }
                group.enter()
                var request = URLRequest(url: url, timeoutInterval: 5.0)
                request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
                URLSession.shared.dataTask(with: request) { data, response, _ in
                    if let data, !data.isEmpty, (response as? HTTPURLResponse)?.statusCode == 200 {
                        DispatchQueue.main.async { assign(INImage(imageData: data)) }
                    }
                    DispatchQueue.main.async { group.leave() }
                }.resume()
            }
        }
        group.notify(queue: .main) {
            let content = communication(mutable, info: info, thread: thread, senderImage: senderImage, groupImage: groupImage)
            completion(withPicture(content, picture))
        }
    }

    private static func communication(_ content: UNMutableNotificationContent, info: [String: Any], thread: String, senderImage: INImage?, groupImage: INImage?) -> UNNotificationContent {
        guard #available(iOS 15.0, *) else { return content }
        let senderName = info["name"] as? String ?? content.title
        let senderId = info["id"] as? String ?? thread
        let groupName = info["group"] as? String
        let sender = INPerson(personHandle: INPersonHandle(value: senderId, type: .unknown), nameComponents: nil, displayName: senderName, image: senderImage, contactIdentifier: nil, customIdentifier: senderId)
        let me = INPerson(personHandle: INPersonHandle(value: "0", type: .unknown), nameComponents: nil, displayName: nil, image: nil, contactIdentifier: nil, customIdentifier: nil, isMe: true, suggestionType: .none)
        // A group is drawn as one only with more than one recipient; the sender stands in as the second.
        let intent = INSendMessageIntent(
            recipients: groupName == nil ? [me] : [me, sender],
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: groupName.map { INSpeakableString(spokenPhrase: $0) },
            conversationIdentifier: info["conversation"] as? String ?? thread,
            serviceName: info["service"] as? String,
            sender: sender,
            attachments: nil
        )
        if let senderImage {
            intent.setImage(senderImage, forParameterNamed: \.sender)
        }
        if groupName != nil, let groupImage {
            intent.setImage(groupImage, forParameterNamed: \.speakableGroupName)
        }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        guard let updated = try? content.updating(from: intent), let result = updated.mutableCopy() as? UNMutableNotificationContent else { return content }
        result.threadIdentifier = thread
        return result
    }

    /// The picture a mail's summary picked, shown in the notification's preview.
    private static func withPicture(_ content: UNNotificationContent, _ data: Data?) -> UNNotificationContent {
        guard let data, let mutable = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        guard (try? data.write(to: url)) != nil, let attachment = try? UNNotificationAttachment(identifier: "picture", url: url, options: nil) else { return content }
        mutable.attachments = [attachment]
        return mutable
    }
}
