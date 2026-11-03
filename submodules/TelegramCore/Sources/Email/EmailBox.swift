import Foundation

/// Paigram's mail comes from the pai box's email connector (`/gmail/…`): every correspondent of the user's
/// mailboxes is an email chat, and the box is where their history, search, sends and read marks go.
public enum EmailBox {
    /// Where an attachment downloads from.
    static func attachmentURL(account: String, message: String, part: String) -> String? {
        return PaiBox.url(path: "/gmail/attachment", query: ["account": account, "message": message, "part": part], includingToken: true)?.absoluteString
    }
    
    /// A chat's picture: named by its hash, so a new picture is a new url and the media box never serves a stale one.
    static func avatarURL(hash: String) -> String? {
        return PaiBox.url(path: "/gmail/avatar", query: ["v": hash], includingToken: true)?.absoluteString
    }
    
    /// Whether a link is one of the box's pages of a whole email, which open in the app's own browser.
    public static func isEmailPage(_ url: String) -> Bool {
        guard let baseURL = PaiBox.configuration?.baseURL else {
            return false
        }
        return url.hasPrefix(baseURL.appendingPathComponent("/m/email/view/").absoluteString)
    }
    
    /// The picture an automated mail's summary picked.
    static func heroURL(account: String, message: String) -> String? {
        return PaiBox.url(path: "/gmail/image", query: ["account": account, "id": message], includingToken: true)?.absoluteString
    }
}

// MARK: - What the box sends

public struct EmailAddress: Codable, Equatable {
    public let name: String
    public let address: String
    
    public var displayName: String {
        return self.name.isEmpty ? self.address : self.name
    }
}

public struct EmailAttachmentData: Codable, Equatable {
    public let part: String
    public let name: String
    public let mimeType: String
    public let size: Int64
}

/// A span of a message's text the box styled: `bold`, `italic`, or a `link` to `url`, in UTF-16 units.
public struct EmailTextEntityData: Codable, Equatable {
    public let type: String
    public let offset: Int
    public let length: Int
    public let url: String?
}

/// Text the box wrote for a chat bubble, with its spans.
public struct EmailRichTextData: Codable, Equatable {
    public let text: String
    public let entities: [EmailTextEntityData]
}

public struct EmailHeroData: Codable, Equatable {
    public let width: Int32
    public let height: Int32
}

public struct EmailMessageData: Codable, Equatable {
    public let account: String
    public let id: String
    public let threadId: String
    /// Milliseconds since 1970.
    public let date: Int64
    public let from: EmailAddress
    public let to: [EmailAddress]
    public let cc: [EmailAddress]
    public let subject: String
    public let snippet: String
    public let unread: Bool
    public let outgoing: Bool
    /// The message's own words; absent in a summary (the contact list's latest message).
    public let text: String?
    public let entities: [EmailTextEntityData]?
    public let attachments: [EmailAttachmentData]?
    /// `personal` (a person's words, shown as they are) or `automated` (shown as `digest`).
    public let kind: String?
    /// What an automated mail says, written for the chat; nil for a person's mail or when it could not be written.
    public let digest: EmailRichTextData?
    public let hero: EmailHeroData?
    /// Answers the user might give to a mail that asks him something (button labels); gone once he wrote back.
    public let replies: [String]?
    /// The whole email as its sender made it, a signed page on the box.
    public let viewUrl: String?
}

public struct EmailContactData: Codable, Equatable {
    public let id: Int64
    public let address: String
    public let name: String
    public let included: Bool
    public let muted: Bool
    /// The hash of its picture on the box; nil while it has none.
    public let avatar: String?
    public let lastDate: Int64
    public let unread: Int32
    public let oldestUnread: Int64?
    public let last: EmailMessageData?
}

public struct EmailAccountData: Codable, Equatable {
    public let label: String
    public let email: String
    public let title: String
    public let color: String
}

struct EmailContactsResponse: Decodable {
    let seq: Int64
    let accounts: [EmailAccountData]
    let contacts: [EmailContactData]
}

struct EmailChange: Decodable {
    struct Payload: Decodable {
        let contact: EmailContactData?
        let message: EmailMessageData?
        let account: String?
        let id: String?
    }
    
    let seq: Int64
    let kind: String
    let payload: Payload
}

struct EmailChangesResponse: Decodable {
    let reset: Bool
    let seq: Int64
    let changes: [EmailChange]
    let more: Bool?
}

struct EmailConversationResponse: Decodable {
    let contact: EmailContactData
    let messages: [EmailMessageData]
    let more: Bool
}

struct EmailSearchResponse: Decodable {
    struct Result: Decodable {
        let contact: EmailContactData?
        let message: EmailMessageData
    }
    
    let results: [Result]
}

struct EmailMessageResponse: Decodable {
    let contact: EmailContactData
    let message: EmailMessageData
}

struct EmailReadResponse: Decodable {
    let contact: EmailContactData
}
