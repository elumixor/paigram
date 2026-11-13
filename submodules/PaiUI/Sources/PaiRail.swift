import Foundation

/// What runs under a chat right now, for the strip above its composer: who works, who waits on the user.
public struct PaiRail: Equatable {
    public struct Face: Equatable {
        public let slug: String
        public let name: String
        public let avatar: String?
    }

    public let faces: [Face]
    public let title: String
    public let subtitle: String
    /// Somebody waits on the user's decision.
    public let isWaiting: Bool
    /// The agent a tap opens; nil when the strip is about this chat's own agent.
    public let target: String?

    /// The strip for a topic of the bot chat (nil or pai's main topic: every agent); nil when nothing runs or waits.
    public static func state(thread: Int64?) -> PaiRail? {
        return state(agent: PaiChat.agent(thread: thread)?.slug ?? PaiChat.paiSlug)
    }

    /// The strip for an agent's chat: it and the agents under it (pai's: every agent).
    public static func state(agent scopeSlug: String) -> PaiRail? {
        let live = PaiChat.agents.filter { $0.status != "done" && $0.status != "closed" }
        let members = scopeSlug == PaiChat.paiSlug
            ? live.filter { !$0.isPai }
            : live.filter { $0.slug == scopeSlug || PaiChat.isAncestor(scopeSlug, of: $0.slug) }
        let needs = PaiChat.needs
        let waiting = members.filter { agent in agent.status == "waiting" || needs.contains { $0.agent == agent.slug } }
        let working = members.filter { agent in agent.isBusy && !waiting.contains(agent) }
        guard !waiting.isEmpty || !working.isEmpty else {
            return nil
        }
        let shown = waiting + working
        let faces = shown.prefix(3).map { Face(slug: $0.slug, name: $0.name, avatar: $0.avatar) }

        if shown.count == 1, let only = shown.first {
            let need = needs.first { $0.agent == only.slug }
            let isSelf = only.slug == scopeSlug
            let title: String
            if waiting.isEmpty {
                title = isSelf ? "Working" : "\(only.name) is working"
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
}
