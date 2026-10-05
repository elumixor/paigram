import Foundation
import Postbox
import TelegramCore

/// One line of pai's service feed: what happened, the symbol it is drawn with, who it is about.
public struct PaiEventLine: Equatable {
    public let event: String
    public let text: String
    public let symbol: String
    public let agent: String?
    public let thread: Int64?

    public var isError: Bool { event == "error" }
}

/// The SF Symbols of the feed, the same set pai's `EVENT_ICONS` names (src/protocol/rich.ts).
public enum PaiEventIcon {
    private static let symbols: [String: String] = [
        "agent.created": "person.crop.circle.badge.plus",
        "agent.spawned": "arrow.triangle.branch",
        "delegate": "arrow.turn.down.right",
        "delegation": "arrow.turn.down.right",
        "request": "arrow.turn.down.right",
        "report": "arrow.turn.up.left",
        "response": "arrow.turn.up.left",
        "agent.woken": "bolt",
        "routine.fired": "clock.arrow.circlepath",
        "item.arrived": "envelope",
        "item.telegram": "bubble.left",
        "item.linkedin": "bubble.left",
        "calendar.upcoming": "calendar",
        "ask": "questionmark.bubble",
        "approval": "hand.raised",
        "answered": "checkmark.bubble",
        "sent": "paperplane",
        "notice": "bell",
        "error": "exclamationmark.triangle",
        "agent.closed": "archivebox",
    ]

    /// The trailer's own icon wins; an event pai has not named yet gets the bell.
    public static func symbol(event: String?, icon: String? = nil) -> String {
        if let icon, !icon.isEmpty { return icon }
        return event.flatMap { symbols[$0] } ?? "bell"
    }
}

/// How an agent's status reads: the symbol (shared with the event rows) and a word or two.
public enum PaiAgentStatus {
    public static func symbol(_ status: String?) -> String {
        switch status {
        case "working": return "bolt"
        case "waiting": return "questionmark.bubble"
        case "queued": return "clock"
        case "closed": return "archivebox"
        default: return "moon.zzz"
        }
    }

    public static func label(_ status: String?) -> String {
        switch status {
        case "working": return "Working"
        case "waiting": return "Waiting on you"
        case "queued": return "Queued"
        case "closed": return "Done"
        default: return "Idle"
        }
    }
}

/// Consecutive event rows fold into one line. The chat's history builder finds the runs and tells the last
/// row of each what it stands for; that row's node draws the fold and opens it on tap.
public enum PaiEventFold {
    private static let lock = NSLock()
    private static var runs: [MessageId: [PaiEventLine]] = [:]
    private static var expanded = Set<MessageId>()

    /// The lines a message carries itself: one for an `event`, the run for an `events`; nil for anything else.
    public static func lines(_ message: Message) -> [PaiEventLine]? {
        guard let trailer = PaiTrailer.find(message), trailer.meta.isEvent else { return nil }
        let meta = trailer.meta
        if meta.kind == "events" {
            return (meta.items ?? []).map { PaiEventLine(event: $0.event, text: $0.text, symbol: PaiEventIcon.symbol(event: $0.event, icon: $0.icon), agent: $0.agent, thread: nil) }
        }
        let text = (message.text as NSString).substring(to: trailer.textEnd).trimmingCharacters(in: .whitespacesAndNewlines)
        return [PaiEventLine(event: meta.event ?? "notice", text: text, symbol: PaiEventIcon.symbol(event: meta.event, icon: meta.icon), agent: meta.agent, thread: meta.thread)]
    }

    /// The runs the history builder found, keyed by the row that shows each; `single` rows show only themselves.
    public static func update(_ folded: [MessageId: [PaiEventLine]], single: [MessageId]) {
        lock.lock()
        defer { lock.unlock() }
        for id in single { runs.removeValue(forKey: id) }
        runs.merge(folded) { _, new in new }
    }

    /// What a row shows: the run it closes, else its own lines.
    public static func run(_ message: Message) -> [PaiEventLine] {
        lock.lock()
        let run = runs[message.id]
        lock.unlock()
        return run ?? lines(message) ?? []
    }

    public static func isExpanded(_ id: MessageId) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return expanded.contains(id)
    }

    public static func toggle(_ id: MessageId) {
        lock.lock()
        defer { lock.unlock() }
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// "5 events: 2 routines, 3 emails".
    public static func summary(_ lines: [PaiEventLine]) -> String {
        var order: [String] = []
        var counts: [String: (Int, String, String)] = [:]
        for line in lines {
            let (one, many) = noun(line)
            if let current = counts[one] {
                counts[one] = (current.0 + 1, one, many)
            } else {
                counts[one] = (1, one, many)
                order.append(one)
            }
        }
        let parts = order.compactMap { counts[$0] }.map { n, one, many in "\(n) \(n == 1 ? one : many)" }
        return "\(lines.count) events: " + parts.joined(separator: ", ")
    }

    private static func noun(_ line: PaiEventLine) -> (String, String) {
        switch line.event {
        case "routine.fired": return ("routine", "routines")
        case "item.arrived": return line.symbol == "envelope" ? ("email", "emails") : ("message", "messages")
        case "item.telegram", "item.linkedin": return ("message", "messages")
        case "calendar.upcoming": return ("meeting", "meetings")
        case "agent.created": return ("new agent", "new agents")
        case "agent.spawned": return ("sub-agent", "sub-agents")
        case "agent.woken": return ("wake-up", "wake-ups")
        case "agent.closed": return ("agent done", "agents done")
        case "answered": return ("answer", "answers")
        case "sent": return ("sent", "sent")
        case "error": return ("error", "errors")
        case "notice": return ("notice", "notices")
        default: return ("other", "other")
        }
    }
}
