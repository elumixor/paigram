import Foundation

/// One line of the chat the draft answers, as the box reads it.
public struct PaiComposeMessage {
    public let fromMe: Bool
    public let author: String
    public let text: String
    public let at: Int32

    public init(fromMe: Bool, author: String, text: String, at: Int32) {
        self.fromMe = fromMe
        self.author = author
        self.text = text
        self.at = at
    }
}

/// Where the draft goes: the box writes in the chat's language and register from this.
public struct PaiComposeContext {
    public enum Kind: String {
        case telegram
        case email
        case whatsapp
    }

    public let kind: Kind
    public let chatTitle: String
    /// Email only: the thread's subject.
    public let subject: String?
    /// Oldest first.
    public let messages: [PaiComposeMessage]

    public init(kind: Kind, chatTitle: String, subject: String?, messages: [PaiComposeMessage]) {
        self.kind = kind
        self.chatTitle = chatTitle
        self.subject = subject
        self.messages = messages
    }
}

public struct PaiComposeQuestion: Decodable, Identifiable {
    public let question: String
    public let options: [String]

    public var id: String { self.question }

    private enum CodingKeys: String, CodingKey {
        case question, options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.question = try container.decode(String.self, forKey: .question)
        self.options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
    }
}

public struct PaiComposeAnswer {
    public let question: String
    public let answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// The rewritten message, or what the box needs to know before it can write one.
public struct PaiComposeResult: Decodable {
    public let text: String
    public let questions: [PaiComposeQuestion]
    public let notes: [String]

    private enum CodingKeys: String, CodingKey {
        case text, questions, notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.questions = try container.decodeIfPresent([PaiComposeQuestion].self, forKey: .questions) ?? []
        self.notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

@available(iOS 16.0, *)
public extension PaiClient {
    /// Turns a rough draft into the message the user would send in this chat.
    func compose(context: PaiComposeContext, draft: String, answers: [PaiComposeAnswer]) async throws -> PaiComposeResult {
        var body: [String: Any] = [
            "kind": context.kind.rawValue,
            "chatTitle": context.chatTitle,
            "draft": draft,
            "messages": context.messages.map { message -> [String: Any] in
                return ["fromMe": message.fromMe, "author": message.author, "text": message.text, "at": Int(message.at)]
            },
            // Questions come back in English whatever the chat's language: the user reads them, not the peer.
            "askIn": "English",
            // "Tomorrow" and "at 5" are his, so the box reads them against this phone's clock and zone.
            "now": Int(Date().timeIntervalSince1970),
            "timeZone": TimeZone.current.identifier
        ]
        if let subject = context.subject {
            body["subject"] = subject
        }
        if !answers.isEmpty {
            body["answers"] = answers.map { ["question": $0.question, "answer": $0.answer] }
        }
        return try await self.call(PaiComposeResult.self, "/compose", method: "POST", body: body)
    }
}
