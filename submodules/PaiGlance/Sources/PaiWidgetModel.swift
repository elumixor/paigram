import Foundation

/// What the home-screen widget shows, worked out from a glance: the asks waiting on the user, the agents most
/// recently at work, and one weekly bar with the 5-hour window inside it. No money: spend stays in the app.
public struct PaiWidgetModel: Equatable {
    /// The weekly window as a bar, with the 5-hour window drawn inside it.
    public struct Bar: Equatable {
        /// How full the weekly window is, 0...1; nil when unknown.
        public let weekly: Double?
        /// How full the 5-hour window is, 0...1; nil when unknown.
        public let session: Double?
        public let weeklyLabel: String
        public let sessionLabel: String
        /// The weekly reset, short ("3d", "2h14"); nil when unknown.
        public let weeklyResetsIn: String?
        /// The higher of the two readings in percent, for the bar's tint; nil when both are unknown.
        public let peakPercent: Double?

        public static let unknownLabel = "—"

        init(weekly: PaiGlance.Window?, session: PaiGlance.Window?, now: Date) {
            self.weekly = weekly.map { Bar.fraction($0.percent) }
            self.session = session.map { Bar.fraction($0.percent) }
            weeklyLabel = weekly.map { Bar.percent($0.percent) } ?? Bar.unknownLabel
            sessionLabel = session.map { Bar.percent($0.percent) } ?? Bar.unknownLabel
            weeklyResetsIn = weekly?.resetsIn(now: now)
            peakPercent = [weekly?.percent, session?.percent].compactMap { $0 }.max()
        }

        static func fraction(_ percent: Double) -> Double {
            guard percent.isFinite else { return 0 }
            return min(max(percent / 100, 0), 1)
        }

        static func percent(_ value: Double) -> String {
            "\(Int(value.isFinite ? value.rounded() : 0))%"
        }
    }

    public struct Ask: Equatable, Identifiable {
        public let id: String
        public let agent: String?
        public let from: String
        public let question: String
        /// How long it has waited, short ("5m", "2h", "3d").
        public let age: String
    }

    public struct Agent: Equatable, Identifiable {
        public let slug: String
        public let name: String
        public let working: Bool
        /// The agent's last line, without its trailing age.
        public let line: String
        /// How long since it was last active, short; nil when unknown.
        public let age: String?
        public var id: String { slug }
    }

    public let asksCount: Int
    /// The open asks, oldest first.
    public let asks: [Ask]
    /// The agents with something to say, the most recently active first.
    public let agents: [Agent]
    public let bar: Bar
    /// "Background held · weekly ≥90% · until 3d" while a weekly hold is in force.
    public let holdLine: String?

    public var oldestAsk: Ask? { asks.first }

    public init(glance: PaiGlance, now: Date = Date()) {
        asksCount = max(glance.needsCount, glance.needs.count)
        asks = glance.needs.sorted { $0.createdAt < $1.createdAt }.map {
            Ask(id: $0.id, agent: $0.agent, from: $0.from, question: $0.plainQuestion, age: PaiWidgetModel.age($0.createdAt, now: now))
        }
        agents = PaiWidgetModel.recentAgents(glance.team, now: now)
        // Names are exact: the glance's `session` falls back to any first window, which would show the weekly twice.
        bar = Bar(weekly: glance.windows.first { $0.name == "Weekly" }, session: glance.windows.first { $0.name == "Session" }, now: now)
        holdLine = glance.hold.map { hold in
            var parts = ["Background held", "weekly ≥\(hold.level)%"]
            if let until = hold.until {
                parts.append("until \(PaiGlance.Window(name: "", percent: 0, resetsAt: until).resetsIn(now: now) ?? "")")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// The agents that have a line, the most recently active first. Agents without a known time follow, working
    /// before idle, in the team's order.
    static func recentAgents(_ team: [PaiGlance.Member], now: Date) -> [Agent] {
        let indexed = team.enumerated().filter { !($0.element.doing ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        let sorted = indexed.sorted { a, b in
            switch (a.element.activeAt, b.element.activeAt) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                if a.element.working != b.element.working { return a.element.working }
                return a.offset < b.offset
            }
        }
        return sorted.map { _, member in
            Agent(slug: member.slug, name: member.name, working: member.working, line: stripAge(member.doing ?? ""), age: member.activeAt.map { age($0, now: now) })
        }
    }

    /// "Release build running · 5m ago" without " · 5m ago": the widget shows the age on its own.
    static func stripAge(_ line: String) -> String {
        line.replacingOccurrences(of: #"\s*·\s*(just now|\d+[mhd] ago)\s*$"#, with: "", options: .regularExpression)
    }

    static func age(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }
}
