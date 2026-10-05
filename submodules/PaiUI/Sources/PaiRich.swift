import Foundation
import Postbox
import TelegramCore

/// The metadata the pai bot hides in a message's trailing link (`pai/src/protocol/rich.ts`).
public struct PaiRichMeta: Decodable, Equatable {
    public struct Tool: Decodable, Equatable {
        public let name: String
        public let detail: String?
    }

    /// One row of a folded run of events.
    public struct Event: Decodable, Equatable {
        public let event: String
        public let text: String
        public let icon: String?
        public let agent: String?
    }

    public let v: Int
    public let kind: String
    public let session: String
    public let project: String?
    public let tools: [Tool]?
    public let durationMs: Double?
    public let state: String?
    public let tool: String?
    public let startedAt: Double?
    /// Rows from the message log: the agent a row is about, its name, where it sits (`pai › Hiring`).
    public let agent: String?
    public let agentName: String?
    public let breadcrumb: String?
    /// An event row: what happened and its SF Symbol; `events` is a folded run of them.
    public let event: String?
    public let icon: String?
    public let items: [Event]?
    /// A delegation card: the agent's status now (idle, queued, working, waiting, closed).
    public let status: String?
    /// An ask: its id, the options, the answer once given; asks and notices carry a priority.
    public let askId: Int?
    public let options: [String]?
    public let answer: String?
    public let priority: String?
    /// The forum topic the agent's chat is in.
    public let thread: Int64?

    public static let version = 1
    public var isStatus: Bool { kind == "status" }
    /// A service row: one event, or a folded run of them.
    public var isEvent: Bool { kind == "event" || kind == "events" }
    /// A card that leads into an agent's chat: work handed to it, or what it said back.
    public var isCard: Bool { kind == "delegation" || kind == "report" }
    /// A process coming up with a turn to answer; one revived with nothing to do is not busy.
    public var isBusy: Bool { state == "busy" || (state == "starting" && startedAt != nil) }
    public var isWaiting: Bool { state == "waiting" }
}

/// Where a message's trailer is and what it says.
public struct PaiTrailer: Equatable {
    public let meta: PaiRichMeta
    /// UTF-16 offset where the visible text ends; everything from here on is the trailer.
    public let textEnd: Int

    /// Only bot messages carry one: the last entity is a link to `/m/<payload>` ending the text.
    public static func find(text: String, entities: [MessageTextEntity]) -> PaiTrailer? {
        let nsText = text as NSString
        guard let last = entities.last(where: { if case .TextUrl = $0.type { return true } else { return false } }),
              case .TextUrl(let url) = last.type,
              last.range.upperBound >= nsText.length - 1,
              let payload = url.components(separatedBy: "/m/").last, payload != url,
              let meta = decode(payload), meta.v == PaiRichMeta.version else { return nil }
        var end = last.range.lowerBound
        while end > 0, nsText.character(at: end - 1) == 0x20 || nsText.character(at: end - 1) == 0x0A { end -= 1 }
        return PaiTrailer(meta: meta, textEnd: end)
    }

    public static func find(_ message: Message) -> PaiTrailer? {
        find(text: message.text, entities: message.textEntitiesAttribute?.entities ?? [])
    }

    private static func decode(_ payload: String) -> PaiRichMeta? {
        var base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(PaiRichMeta.self, from: data)
    }
}

/// One line that says what a turn did, the way a person would put it.
public enum PaiToolSummary {
    private enum Group: Int, CaseIterable {
        case commands, filesRead, filesChanged, codeSearch, webSearch, pagesRead, agents, other

        func phrase(_ n: Int) -> String {
            switch self {
            case .commands: return n == 1 ? "ran a command" : "ran \(n) commands"
            case .filesRead: return n == 1 ? "read a file" : "read \(n) files"
            case .filesChanged: return n == 1 ? "changed a file" : "changed \(n) files"
            case .codeSearch: return "searched the code"
            case .webSearch: return "searched the web"
            case .pagesRead: return n == 1 ? "read a page" : "read \(n) pages"
            case .agents: return n == 1 ? "ran an agent" : "ran \(n) agents"
            case .other: return n == 1 ? "used a tool" : "used \(n) tools"
            }
        }
    }

    private static func group(_ tool: PaiRichMeta.Tool) -> Group {
        switch tool.name {
        case "Bash": return .commands
        case "Read": return .filesRead
        case "Edit", "Write", "NotebookEdit": return .filesChanged
        case "Grep", "Glob": return .codeSearch
        case "WebSearch": return .webSearch
        case "WebFetch": return .pagesRead
        case "Agent", "Task": return .agents
        default: return .other
        }
    }

    public static func line(_ tools: [PaiRichMeta.Tool]) -> String {
        var counts: [Group: Int] = [:]
        for tool in tools { counts[group(tool), default: 0] += 1 }
        let parts = Group.allCases.compactMap { g in counts[g].map { g.phrase($0) } }
        guard let first = parts.first else { return "" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: ", ")
    }

    /// The SF Symbol for a tool row.
    public static func symbol(_ tool: PaiRichMeta.Tool) -> String {
        switch group(tool) {
        case .commands: return "terminal"
        case .filesRead: return "doc.text"
        case .filesChanged: return "pencil.line"
        case .codeSearch: return "magnifyingglass"
        case .webSearch: return "globe"
        case .pagesRead: return "doc.richtext"
        case .agents: return "person.2"
        case .other: return "puzzlepiece"
        }
    }

    /// What a row says: the detail without the tool name repeated.
    public static func title(_ tool: PaiRichMeta.Tool) -> String {
        guard let detail = tool.detail, !detail.isEmpty else { return tool.name }
        if detail.hasPrefix(tool.name + " ") { return String(detail.dropFirst(tool.name.count + 1)) }
        return detail
    }
}
