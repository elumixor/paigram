import Foundation

/// What runs under a chat right now, for the strip above its composer: who works, who waits on the user.
public struct PaiRail: Equatable {
    public struct Face: Equatable {
        public let slug: String
        public let name: String
        public let avatar: String?
    }

    /// The strip's colour: blue while an agent writes, orange while somebody waits on the user, green while a dev
    /// session the agent waits on runs, orange while one stalls.
    public enum Tone: Equatable {
        case working, waiting, devRunning, devStalled
    }

    public let faces: [Face]
    public let title: String
    public let subtitle: String
    public let tone: Tone
    /// The agent a tap opens; nil when the strip is about this chat's own agent.
    public let target: String?

    /// Somebody waits on the user's decision.
    public var isWaiting: Bool { tone == .waiting }

    init(faces: [Face], title: String, subtitle: String, isWaiting: Bool, target: String?) {
        self.init(faces: faces, title: title, subtitle: subtitle, tone: isWaiting ? .waiting : .working, target: target)
    }

    init(faces: [Face], title: String, subtitle: String, tone: Tone, target: String?) {
        self.faces = faces
        self.title = title
        self.subtitle = subtitle
        self.tone = tone
        self.target = target
    }

    /// The strip for a topic of the bot chat (nil or pai's main topic: every agent); nil when nothing runs or waits.
    public static func state(thread: Int64?) -> PaiRail? {
        return state(agent: PaiChat.agent(thread: thread)?.slug ?? PaiChat.rootSlug)
    }

    /// The strip for an agent's chat: it and the agents under it (pai's: every agent).
    public static func state(agent scopeSlug: String) -> PaiRail? {
        let live = PaiChat.agents.filter { $0.status != "done" && $0.status != "closed" }
        let members = scopeSlug == PaiChat.rootSlug
            ? live.filter { !$0.isPai }
            : live.filter { $0.slug == scopeSlug || PaiChat.isAncestor(scopeSlug, of: $0.slug) }
        let needs = PaiChat.needs
        let waiting = members.filter { agent in agent.status == "waiting" || needs.contains { $0.agent == agent.slug } }
        let working = members.filter { agent in agent.isBusy && !waiting.contains(agent) }
        // An ask whose agent is pai itself, finished or unknown still waits on the user: the strip says so.
        if waiting.isEmpty, let need = needs.first(where: { need in
            scopeSlug == PaiChat.rootSlug || need.agent == scopeSlug || need.agent.map { PaiChat.isAncestor(scopeSlug, of: $0) } == true
        }) {
            let agent = PaiChat.agent(need.agent)
            let isSelf = (need.agent ?? PaiChat.rootSlug) == scopeSlug
            let faces = agent.map { [Face(slug: $0.slug, name: $0.name, avatar: $0.avatar)] } ?? []
            let title = isSelf ? "Waiting on you" : "\(agent?.name ?? need.from) waits on you"
            return PaiRail(faces: faces, title: title, subtitle: need.question.paiPlain, isWaiting: true, target: isSelf ? nil : need.agent)
        }
        guard !waiting.isEmpty || !working.isEmpty else {
            return dev(agent: scopeSlug)
        }
        let shown = waiting + working
        let faces = shown.prefix(3).map { Face(slug: $0.slug, name: $0.name, avatar: $0.avatar) }

        if shown.count == 1, let only = shown.first {
            let need = needs.first { $0.agent == only.slug }
            let isSelf = only.slug == scopeSlug
            let title: String
            if waiting.isEmpty {
                let queued = only.status == "queued"
                title = isSelf ? (queued ? "Queued" : "Writing…") : (queued ? "\(only.name) is queued" : "\(only.name) is writing…")
            } else {
                title = isSelf ? "Waiting on you" : "\(only.name) waits on you"
            }
            let subtitle = need?.question.paiPlain ?? only.job
            return PaiRail(faces: faces, title: title, subtitle: subtitle, isWaiting: !waiting.isEmpty, target: isSelf ? nil : only.slug)
        }

        var parts: [String] = []
        if !working.isEmpty { parts.append("\(working.count) working") }
        if !waiting.isEmpty { parts.append("\(waiting.count) waiting on you") }
        let subtitle = shown.prefix(3).map { agent -> String in
            let task = agent.taskTitle.flatMap { $0.isEmpty ? nil : $0 }
            return task.map { "\(agent.name): \($0)" } ?? agent.name
        }.joined(separator: " · ")
        let target = shown.first { $0.slug != scopeSlug }?.slug
        return PaiRail(faces: faces, title: parts.joined(separator: " · "), subtitle: subtitle, isWaiting: !waiting.isEmpty, target: target)
    }

    /// An idle agent's dev sessions at work, from the last `/agents/:slug/waiting` read: a stalled one first.
    private static func dev(agent slug: String) -> PaiRail? {
        guard let live = PaiChat.waiting[slug]?.liveDev, let agent = PaiChat.agent(slug), !agent.isBusy else {
            return nil
        }
        let face = Face(slug: agent.slug, name: agent.name, avatar: agent.avatar)
        let titles = { (sessions: [PaiWaitingOn.Dev]) in sessions.map(\.title).joined(separator: " · ") }
        let stalled = live.filter { $0.liveState == "stalled" }
        if !stalled.isEmpty {
            let title = stalled.count == 1 ? "Dev session stalled" : "\(stalled.count) dev sessions stalled"
            return PaiRail(faces: [face], title: title, subtitle: titles(stalled), tone: .devStalled, target: nil)
        }
        let running = live.filter { $0.liveState == "running" }
        if !running.isEmpty {
            let title = running.count == 1 ? "Dev session running" : "\(running.count) dev sessions running"
            return PaiRail(faces: [face], title: title, subtitle: titles(running), tone: .devRunning, target: nil)
        }
        return nil
    }
}
