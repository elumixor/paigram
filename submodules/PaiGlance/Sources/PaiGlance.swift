import Foundation

/// What the widget, the watch and the usage alerts show at a glance: how much of the plan's limits is used,
/// what today cost, who spent it, how many agents are running and what waits on the user.
public struct PaiGlance: Codable, Equatable {
    public struct Window: Codable, Equatable, Identifiable {
        /// "Session" (the 5-hour window) or "Weekly".
        public let name: String
        public let percent: Double
        public let resetsAt: Date?
        public var id: String { name }

        public init(name: String, percent: Double, resetsAt: Date?) {
            self.name = name
            self.percent = percent
            self.resetsAt = resetsAt
        }

        /// Time to the reset, short: "2h14", "45m", "3d".
        public func resetsIn(now: Date = Date()) -> String? {
            guard let resetsAt else { return nil }
            let seconds = max(0, resetsAt.timeIntervalSince(now))
            let minutes = Int(seconds / 60)
            if minutes < 60 { return "\(minutes)m" }
            let hours = minutes / 60
            if hours < 24 { return String(format: "%dh%02d", hours, minutes % 60) }
            return "\(hours / 24)d"
        }
    }

    public struct AgentSpend: Codable, Equatable, Identifiable {
        public let slug: String
        public let name: String
        public let usd: Double
        public var id: String { slug }

        public init(slug: String, name: String, usd: Double) {
            self.slug = slug
            self.name = name
            self.usd = usd
        }
    }

    /// A question or ask waiting on the user.
    public struct Need: Codable, Equatable, Identifiable {
        public let id: String
        public let agent: String?
        public let from: String
        public let question: String
        public let options: [String]
        public let freeText: Bool
        public let createdAt: Date

        public init(id: String, agent: String?, from: String, question: String, options: [String], freeText: Bool, createdAt: Date) {
            self.id = id
            self.agent = agent
            self.from = from
            self.question = question
            self.options = options
            self.freeText = freeText
            self.createdAt = createdAt
        }

        /// The question as one plain line: markdown emphasis and the trailing URNs dropped, for small surfaces.
        public var plainQuestion: String {
            var text = question.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            text = text.replacingOccurrences(of: #"\s*\b[a-z]+:[a-z]+/[0-9a-f-]{8,}\b"#, with: "", options: .regularExpression)
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return lines.joined(separator: " ")
        }
    }

    public let at: Date
    public let todayUsd: Double
    public let usdPerHour: Double?
    public let windows: [Window]
    /// Today's spend per agent, the biggest first.
    public let agents: [AgentSpend]
    public let running: Int
    public let needsCount: Int
    /// The newest few needs, oldest first (the watch lists them; the widget shows the first).
    public let needs: [Need]

    public init(at: Date, todayUsd: Double, usdPerHour: Double?, windows: [Window], agents: [AgentSpend], running: Int, needsCount: Int, needs: [Need]) {
        self.at = at
        self.todayUsd = todayUsd
        self.usdPerHour = usdPerHour
        self.windows = windows
        self.agents = agents
        self.running = running
        self.needsCount = needsCount
        self.needs = needs
    }

    public var session: Window? { windows.first { $0.name == "Session" } ?? windows.first }
    public var weekly: Window? { windows.first { $0.name == "Weekly" } }

    /// The window that runs out first.
    public var limiting: Window? { windows.max { $0.percent < $1.percent } }

    public var oldestNeed: Need? { needs.first }

    /// A glance without windows means the box could not read the plan, not that nothing is used: the previous
    /// glance's windows stay until they reset.
    public func keepingWindows(of previous: PaiGlance?, now: Date = Date()) -> PaiGlance {
        guard windows.isEmpty, let previous else { return self }
        let held = previous.windows.filter { ($0.resetsAt ?? .distantFuture) > now }
        guard !held.isEmpty else { return self }
        return PaiGlance(at: at, todayUsd: todayUsd, usdPerHour: usdPerHour, windows: held, agents: agents, running: running, needsCount: needsCount, needs: needs)
    }
}

public extension PaiGlance {
    /// What the widget gallery and previews show.
    static let sample = PaiGlance(
        at: Date(),
        todayUsd: 41.2,
        usdPerHour: 6.3,
        windows: [
            Window(name: "Session", percent: 46, resetsAt: Date().addingTimeInterval(2 * 3600 + 14 * 60)),
            Window(name: "Weekly", percent: 71, resetsAt: Date().addingTimeInterval(2 * 86400))
        ],
        agents: [
            AgentSpend(slug: "pai", name: "Ari", usd: 18.4),
            AgentSpend(slug: "tomas", name: "Tomas", usd: 9.1),
            AgentSpend(slug: "lena", name: "Lena", usd: 5.6)
        ],
        running: 4,
        needsCount: 2,
        needs: [
            Need(id: "ask:1", agent: "lena", from: "Lena", question: "Send the invoice to Acme now?", options: ["Send", "Wait"], freeText: true, createdAt: Date().addingTimeInterval(-3600)),
            Need(id: "ask:2", agent: "tomas", from: "Tomas", question: "Ship 0.4.1 to TestFlight?", options: ["Ship", "Hold"], freeText: false, createdAt: Date().addingTimeInterval(-600))
        ]
    )
}

/// Links back into the app from the widget and the watch.
public enum PaiGlanceLink {
    public static let scheme = "paigram"

    /// An agent's chat.
    public static func agent(_ slug: String) -> URL {
        URL(string: "\(scheme)://agent/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)")!
    }

    /// The usage screen.
    public static let usage = URL(string: "\(scheme)://usage")!

    public enum Target: Equatable {
        case agent(String)
        case usage
    }

    public static func parse(_ url: URL) -> Target? {
        guard url.scheme == scheme else { return nil }
        switch url.host {
        case "agent":
            let slug = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return slug.isEmpty ? nil : .agent(slug.removingPercentEncoding ?? slug)
        case "usage":
            return .usage
        default:
            return nil
        }
    }
}
