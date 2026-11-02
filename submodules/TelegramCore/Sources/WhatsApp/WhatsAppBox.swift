import Foundation

/// Paigram's WhatsApp comes from the box's WhatsApp connector (`/whatsapp/…`): his own number, linked there, every
/// chat a chat here. A person is one peer (namespace `WhatsApp`) whether a DM is with them or they write in a
/// group; a group is a basic group (namespace `WhatsAppGroup`).
enum WhatsAppBox {
    static func mediaURL(chatKind: String, chat: Int64, message: String) -> String? {
        return PaiBox.url(path: "/whatsapp/media", query: ["chatKind": chatKind, "chat": "\(chat)", "id": message], includingToken: true)?.absoluteString
    }

    /// A person's or a group's picture: named by its hash, so a new picture is a new url.
    static func avatarURL(person: Int64, hash: String) -> String? {
        return PaiBox.url(path: "/whatsapp/avatar", query: ["person": "\(person)", "v": hash], includingToken: true)?.absoluteString
    }

    static func avatarURL(group: Int64, hash: String) -> String? {
        return PaiBox.url(path: "/whatsapp/avatar", query: ["group": "\(group)", "v": hash], includingToken: true)?.absoluteString
    }
}

public struct WhatsAppPersonData: Codable, Equatable {
    public let id: Int64
    public let jid: String
    public let phone: String?
    public let name: String
    public let avatar: String?
}

/// A span WhatsApp's own markup made: `bold`, `italic`, `strike` or `code`, in UTF-16 units.
public struct WhatsAppEntityData: Codable, Equatable {
    public let type: String
    public let offset: Int
    public let length: Int
}

public struct WhatsAppMediaData: Codable, Equatable {
    /// `photo`, `video`, `voice`, `audio`, `document`, `sticker` or `gif`.
    public let kind: String
    public let mime: String
    public let size: Int64?
    public let width: Int32?
    public let height: Int32?
    public let duration: Double?
    public let fileName: String?
    /// A small JPEG, base64.
    public let thumbnail: String?
}

public struct WhatsAppMessageData: Codable, Equatable {
    public let id: String
    /// `dm` or `group`.
    public let chatKind: String
    public let chat: Int64
    /// Milliseconds since 1970.
    public let at: Int64
    public let fromMe: Bool
    /// A person id; 0 when the box could not tell who wrote it.
    public let author: Int64
    public let text: String
    public let entities: [WhatsAppEntityData]
    public let media: WhatsAppMediaData?
    /// The id of the message this one answers.
    public let quoted: String?
    public let edited: Bool
}

public struct WhatsAppChatData: Codable, Equatable {
    public let id: Int64
    public let kind: String
    public let jid: String
    public let title: String
    public let unread: Int32
    public let muted: Bool
    public let archived: Bool
    public let pinned: Bool
    public let at: Int64
    public let participants: [Int64]?
    public let avatar: String?
    public let last: WhatsAppMessageData?

    var isGroup: Bool {
        return self.kind == "group"
    }
}

struct WhatsAppChatsResponse: Decodable {
    let me: WhatsAppPersonData?
    let people: [WhatsAppPersonData]
    let chats: [WhatsAppChatData]
    let seq: Int64
}

struct WhatsAppChange: Decodable {
    let seq: Int64
    /// `chat`, `person`, `message`, `delete`, `read` or `removeChat`.
    let kind: String
    let payload: Payload

    /// Every kind's payload in one shape: a chat, a person, a message, or a chat's key with a message id or unread count.
    struct Payload: Decodable {
        let id: AnyId?
        let kind: String?
        let jid: String?
        let title: String?
        let unread: Int32?
        let muted: Bool?
        let archived: Bool?
        let pinned: Bool?
        let at: Int64?
        let participants: [Int64]?
        let avatar: String?
        let last: WhatsAppMessageData?
        let phone: String?
        let name: String?
        let chatKind: String?
        let chat: Int64?
        let fromMe: Bool?
        let author: Int64?
        let text: String?
        let entities: [WhatsAppEntityData]?
        let media: WhatsAppMediaData?
        let quoted: String?
        let edited: Bool?
    }

    /// A chat's or a person's id is a number, a message's is WhatsApp's string.
    enum AnyId: Decodable {
        case number(Int64)
        case string(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int64.self) {
                self = .number(number)
            } else {
                self = .string(try container.decode(String.self))
            }
        }
    }

    var chatData: WhatsAppChatData? {
        guard self.kind == "chat", case let .number(id)? = self.payload.id, let kind = self.payload.kind else {
            return nil
        }
        let p = self.payload
        return WhatsAppChatData(id: id, kind: kind, jid: p.jid ?? "", title: p.title ?? "", unread: p.unread ?? 0, muted: p.muted ?? false, archived: p.archived ?? false, pinned: p.pinned ?? false, at: p.at ?? 0, participants: p.participants, avatar: p.avatar, last: p.last)
    }

    var personData: WhatsAppPersonData? {
        guard self.kind == "person", case let .number(id)? = self.payload.id else {
            return nil
        }
        return WhatsAppPersonData(id: id, jid: self.payload.jid ?? "", phone: self.payload.phone, name: self.payload.name ?? "", avatar: self.payload.avatar)
    }

    var messageData: WhatsAppMessageData? {
        let p = self.payload
        guard self.kind == "message", case let .string(id)? = p.id, let chatKind = p.chatKind, let chat = p.chat else {
            return nil
        }
        return WhatsAppMessageData(id: id, chatKind: chatKind, chat: chat, at: p.at ?? 0, fromMe: p.fromMe ?? false, author: p.author ?? 0, text: p.text ?? "", entities: p.entities ?? [], media: p.media, quoted: p.quoted, edited: p.edited ?? false)
    }
}

struct WhatsAppChangesResponse: Decodable {
    let reset: Bool?
    let changes: [WhatsAppChange]
    let seq: Int64
    let more: Bool
}

struct WhatsAppPageResponse: Decodable {
    let messages: [WhatsAppMessageData]
    let people: [WhatsAppPersonData]
    let more: Bool?
}

struct WhatsAppSendResponse: Decodable {
    /// `verified`, `unverified` (taken, not seen back: may have arrived) or `not_sent`.
    let state: String
    let id: String?
    let at: Int64?
    let note: String?
}

struct WhatsAppReadResponse: Decodable {
    let chat: WhatsAppChatData
}
