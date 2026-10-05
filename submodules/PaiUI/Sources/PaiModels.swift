import Foundation

/// What the daemon reports about one thread (`Session.summary()` / `/tasks.recent`).
public struct PaiSession: Codable, Identifiable, Equatable {
    public enum State: String, Codable {
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
    /// Where the conversation is held; needed to adopt one that is not live yet.
    public let cwd: String?

    public var id: String { sessionId }
    public var isWaiting: Bool { waiting ?? false }
    public var isRunning: Bool { state == .busy || state == .starting }
    public var lastActivityDate: Date { Date(timeIntervalSince1970: lastActivity / 1000) }
    public var displayTitle: String { title.isEmpty ? "Untitled" : title }
    public var isHeld: Bool { kind == "held" }
}

/// A conversation held on disk (this box's, or synced from another machine), from `GET /threads/all`.
public struct PaiThread: Decodable {
    public let sessionId: String
    public let shortId: String
    public let cwd: String
    public let title: String
    public let lastActivity: String
    public let project: String?

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The same shape as a live session, held on disk until it is opened.
    public var asSession: PaiSession {
        let date = Self.iso.date(from: lastActivity) ?? ISO8601DateFormatter().date(from: lastActivity) ?? Date()
        return PaiSession(sessionId: sessionId, shortId: shortId, kind: "held", title: title, project: project, state: .detached,
                          lastActivity: date.timeIntervalSince1970 * 1000, costUsd: nil, turns: nil, model: nil, lastTool: nil,
                          recentTools: nil, waiting: nil, lastResult: nil, parent: nil, threadId: nil, cwd: cwd)
    }
}

public struct PaiTasks: Decodable {
    public let live: [PaiSession]
    public let recent: [PaiSession]
}

public struct PaiProject: Codable, Identifiable, Equatable {
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

/// One thing a session is given: an instruction, a memory file, a skill, or an MCP server with its tools.
public struct PaiContextItem: Decodable, Identifiable {
    public let kind: String
    public let name: String
    public let description: String
    public let source: String
    public let editable: Bool
    public let surfaces: [String]
    public let project: String?
    public let body: String?
    public let tools: [Tool]?
    public var id: String { "\(kind)/\(name)/\(project ?? "")" }

    public struct Tool: Decodable, Identifiable {
        public let name: String
        public let description: String?
        public var id: String { name }
    }
    /// A tool server's body is one tool a line.
    public var lines: [String] { (body ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
}

public struct PaiContext: Decodable {
    public struct Session: Decodable {
        public let kind: String
        public let model: String
        public let at: String
    }
    public let items: [PaiContextItem]
    public let sessions: [Session]?
}

public struct PaiUsageWindow: Decodable, Identifiable {
    public let name: String
    public let percent: Double
    public let resetsAt: String?
    public let length: Double
    public var id: String { name }
}

public struct PaiUsage: Decodable {
    public let windows: [PaiUsageWindow]
    public let costUsd: Double?
    public let error: String?
    public let via: String?
}

public struct PaiHealth: Decodable {
    public struct Host: Decodable {
        public let hostname: String
        public let publicUrl: String?
    }
    public let version: String
    public let uptime: Double
    public let host: Host
}

/// pai or one of its agents, from `GET /agents`: where it sits in the tree, what it is doing, what it spent today.
public struct PaiAgent: Codable, Identifiable, Equatable {
    public let slug: String
    public let name: String
    /// orchestrator (pai), standing, sub, service.
    public let kind: String
    public let parent: String?
    public let brief: String?
    /// idle, queued, working, waiting, closed.
    public let status: String?
    /// The forum topic its chat is in; a sub-agent has none and posts into its parent's.
    public let threadId: Int64?
    public let turnsToday: Int?
    public let costUsd: Double?
    public let lastActive: Double?
    public let depth: Int?
    public let breadcrumb: String?
    public let openTasks: Int?
    public let queued: Int?

    public var id: String { slug }
    public var isPai: Bool { slug == PaiChat.paiSlug }
    public var isClosed: Bool { status == "closed" }
    public var briefLine: String { (brief ?? "").split(separator: "\n").first.map(String.init)?.paiPlain ?? "" }
}

/// One row of the message log (`GET /messages`): every word between the user, pai, its agents, routines and watchers.
public struct PaiLogMessage: Codable, Identifiable, Equatable {
    public struct Meta: Codable, Equatable {
        public var event: String?
        public var icon: String?
        public var askId: Int?
        public var options: [String]?
        public var breadcrumb: String?
        public var priority: String?
        public var agent: String?
        public var answer: String?

        public init() {}

        /// Every field is optional and pai adds to them over time; one that does not parse is left out, not the row.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            event = try? c.decodeIfPresent(String.self, forKey: .event)
            icon = try? c.decodeIfPresent(String.self, forKey: .icon)
            askId = try? c.decodeIfPresent(Int.self, forKey: .askId)
            options = try? c.decodeIfPresent([String].self, forKey: .options)
            breadcrumb = try? c.decodeIfPresent(String.self, forKey: .breadcrumb)
            priority = try? c.decodeIfPresent(String.self, forKey: .priority)
            agent = try? c.decodeIfPresent(String.self, forKey: .agent)
            answer = try? c.decodeIfPresent(String.self, forKey: .answer)
        }
    }

    public let id: Int
    /// "user", "pai", an agent's slug, "routine:<id>", "watcher:<source>".
    public let from: String
    public let to: String
    /// chat, delegate, report, request, response, ask, answer, notice, event.
    public let kind: String
    public let body: String
    public var meta: Meta
    public let createdAt: Double

    public init(id: Int, from: String, to: String, kind: String, body: String, meta: Meta = Meta(), createdAt: Double) {
        self.id = id
        self.from = from
        self.to = to
        self.kind = kind
        self.body = body
        self.meta = meta
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        kind = try c.decode(String.self, forKey: .kind)
        body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? ""
        meta = (try? c.decodeIfPresent(Meta.self, forKey: .meta)) ?? Meta()
        createdAt = (try? c.decodeIfPresent(Double.self, forKey: .createdAt)) ?? 0
    }

    public var date: Date { Date(timeIntervalSince1970: createdAt / 1000) }
    public var firstLine: String { body.split(separator: "\n").first.map(String.init)?.paiPlain ?? "" }

    /// Whether the row belongs in an agent's chat: what it said, what was said to it, events about it.
    public func concerns(_ slug: String) -> Bool { from == slug || to == slug || meta.agent == slug }
}
