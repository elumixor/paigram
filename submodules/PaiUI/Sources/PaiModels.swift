import Foundation

/// What the daemon reports about one thread (`Session.summary()` / `/tasks.recent`).
public struct PaiSession: Decodable, Identifiable, Equatable {
    public enum State: String, Decodable {
        case starting, idle, busy, dead, detached
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .dead
        }
    }

    public let sessionId: String
    public let shortId: String
    public let kind: String
    public let title: String
    public let project: String?
    public let state: State
    public let lastActivity: Double
    public let costUsd: Double?
    public let turns: Int?
    public let model: String?
    public let lastTool: String?
    public let recentTools: [String]?
    public let waiting: Bool?
    public let lastResult: String?
    public let parent: String?
    /// The Telegram topic this thread lives in, when the bot has made one.
    public let threadId: Int64?

    public var id: String { sessionId }
    public var isWaiting: Bool { waiting ?? false }
    public var isRunning: Bool { state == .busy || state == .starting }
    public var lastActivityDate: Date { Date(timeIntervalSince1970: lastActivity / 1000) }
    public var displayTitle: String { title.isEmpty ? "Untitled" : title }
}

public struct PaiTasks: Decodable {
    public let live: [PaiSession]
    public let recent: [PaiSession]
}

public struct PaiProject: Decodable, Identifiable, Equatable {
    public let slug: String
    public let path: String
    public let summary: String?
    public let kind: String
    public var id: String { slug }
}

public struct PaiQuestionOption: Decodable, Equatable {
    public let label: String
    public let description: String?
}

public struct PaiQuestion: Decodable, Equatable {
    public let question: String
    public let header: String?
    public let options: [PaiQuestionOption]
    public let multiSelect: Bool?
}

/// One item of `GET /transcript`.
public struct PaiTranscriptMessage: Decodable {
    public struct Tool: Decodable {
        public let id: String
        public let name: String
        public let input: String?
        public let result: String?
    }
    public let role: String
    public let ts: String?
    public let text: String?
    public let thinking: String?
    public let meta: Bool?
    public let tools: [Tool]?
}

/// One event of the SSE stream; `payload` is decoded per `kind` by the consumer.
public struct PaiEvent: Decodable {
    public let kind: String
    public let sessionId: String?
    public let payload: JSONValue
    public let ts: Double?
}

/// A minimal JSON tree, enough to pick fields out of event payloads.
public enum JSONValue: Decodable, Equatable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    /// Re-encodes a subtree so typed models can be decoded from it.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}

extension JSONValue: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
