import Foundation
import Postbox
import TelegramCore

/// What the Telegram screens need to know about the pai bot's chat.
public enum PaiChat {
    private static let lastThreadKey = "pai.lastThreadId"

    /// Whether a chat is the pai bot's.
    public static func isBot(_ peer: Peer?) -> Bool {
        guard let user = peer as? TelegramUser, user.botInfo != nil else { return false }
        return user.addressName?.lowercased() == PaiSecrets.botUsername.lowercased()
    }

    /// The bot's peer id, learned when its history is first built; lets list items tell the chat apart.
    public static var botPeerId: PeerId?

    /// The topic the chat was on last time, so it opens there again.
    public static var lastThreadId: Int64? {
        get {
            let value = UserDefaults.standard.object(forKey: lastThreadKey) as? Int64
            return value == 0 ? nil : value
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: lastThreadKey) }
    }

    private static let pinnedKey = "pai.pinnedProjects"

    /// Projects pinned to the top of the list, in the order they were pinned.
    public static var pinnedProjects: [String] {
        get { UserDefaults.standard.stringArray(forKey: pinnedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: pinnedKey) }
    }

    /// Posted on the main thread whenever whether any thread is running or waiting changes; `object` is that Bool.
    public static let activityChanged = Notification.Name("pai.activityChanged")
}

// MARK: Starting a thread in a project

extension PaiChat {
    private static let prefixPattern = try! NSRegularExpression(pattern: "^/project[ \\t]+([A-Za-z0-9._-]+)[ \\t]*\\n?")

    /// The project the next new thread should start in; nil is the general workspace.
    public static var pendingProject: PaiProject? {
        didSet { NotificationCenter.default.post(name: projectChanged, object: nil) }
    }
    public static let projectChanged = Notification.Name("pai.projectChanged")

    /// The first line the bot reads to start the thread in a project (`pai-telegram` strips it too).
    public static func prefixed(_ text: String, project: PaiProject?) -> String {
        guard let project else { return text }
        return "/project \(project.slug)\n\(text)"
    }

    /// UTF-16 length of a leading `/project <slug>` line, or 0.
    public static func prefixLength(in text: String) -> Int {
        prefixPattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.range.length ?? 0
    }
}

// MARK: pai and its agents

extension PaiChat {
    /// pai's own slug in the agent tree; its chat is the bot chat's main topic.
    public static let paiSlug = "pai"

    private static let mainThreadKey = "pai.mainThreadId"
    private static let agentsCache = PaiCachedValue<[PaiAgent]>("agents", legacyKey: "pai.agents", empty: [])

    /// The topic pai's chat is in (`/m/telegram/info`), so the bot chat opens there without asking first.
    public static var mainThreadId: Int64? {
        get {
            let value = UserDefaults.standard.object(forKey: mainThreadKey) as? Int64
            return value == 0 ? nil : value
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: mainThreadKey) }
    }

    /// Posted on the main thread when the agent list changes.
    public static let agentsChanged = Notification.Name("pai.agentsChanged")

    /// Posted on the main thread when `usage` changes.
    public static let usageChanged = Notification.Name("pai.usageChanged")
    /// Posted on the main thread when `needs` changes.
    public static let needsChanged = Notification.Name("pai.needsChanged")
    private static let needsCache = PaiCachedValue<[PaiNeed]>("needs", empty: [])

    /// What waits on the user's decision now: the chat's title counts them, the hub lists them, agents wear a badge.
    /// The last list seen shows until the daemon answers.
    public static var needs: [PaiNeed] {
        get { needsCache.current }
        set {
            if needsCache.set(newValue) { DispatchQueue.main.async { NotificationCenter.default.post(name: needsChanged, object: nil) } }
        }
    }

    /// How many decisions an agent waits on.
    public static func needs(of slug: String) -> Int { needs.filter { $0.agent == slug }.count }

    /// Posted on the main thread when anything the daemon tracks moved: an agent, a task, an ask, a turn.
    public static let changed = Notification.Name("pai.changed")
    private static let usageCache = PaiCachedValue<PaiUsage?>("usage", legacyKey: "pai.usage", empty: nil)

    /// The subscription's windows and what the sessions cost, last seen; the chat draws them as bars under its title.
    /// A reading without windows means the box could not read the plan, not that nothing is used: the last
    /// windows stay until they reset.
    public static var usage: PaiUsage? {
        get { usageCache.current }
        set {
            var value = newValue
            if let fresh = newValue, fresh.windows.isEmpty, let held = usageCache.current?.windows {
                let now = Date()
                value = PaiUsage(windows: held.filter { ($0.resetDate ?? .distantFuture) > now }, costUsd: fresh.costUsd, error: fresh.error, via: fresh.via)
            }
            if usageCache.set(value) { DispatchQueue.main.async { NotificationCenter.default.post(name: usageChanged, object: nil) } }
        }
    }

    /// Reads the cached agents, needs and usage off the main thread at launch, so the first screens find them in memory.
    public static func preload() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = agentsCache.current
            _ = needsCache.current
            _ = usageCache.current
        }
    }

    /// The last agent list seen, readable from any queue: chat nodes lay out off the main thread.
    public static var agents: [PaiAgent] {
        get { agentsCache.current }
        set {
            if agentsCache.set(newValue) { DispatchQueue.main.async { NotificationCenter.default.post(name: agentsChanged, object: nil) } }
        }
    }

    public static func agent(_ slug: String?) -> PaiAgent? {
        guard let slug else { return nil }
        return agents.first { $0.slug == slug }
    }

    /// The agent whose chat a topic is; the main topic is pai's even before pai has a row.
    public static func agent(thread: Int64?) -> PaiAgent? {
        guard let thread else { return nil }
        if let agent = agents.first(where: { $0.threadId == thread }) { return agent }
        return thread == mainThreadId ? agent(paiSlug) : nil
    }

    /// The topic an agent's chat is in: its own, pai's main one; nil for a sub-agent, whose chat is in the app.
    public static func thread(of slug: String) -> Int64? {
        if slug == paiSlug { return mainThreadId ?? agent(slug)?.threadId }
        return agent(slug)?.threadId
    }

    /// From pai down to the agent: what the breadcrumb shows. Unknown agents are just themselves.
    public static func chain(to slug: String) -> [PaiAgent] {
        var chain: [PaiAgent] = []
        var current = agent(slug)
        while let a = current, !chain.contains(where: { $0.slug == a.slug }) {
            chain.insert(a, at: 0)
            current = agent(a.parent)
        }
        return chain
    }

    /// Whether `ancestor` sits above `slug` in the tree.
    public static func isAncestor(_ ancestor: String, of slug: String) -> Bool {
        chain(to: slug).dropLast().contains { $0.slug == ancestor }
    }

    /// The agents under one, open ones first, the latest active first.
    public static func children(of slug: String) -> [PaiAgent] {
        agents.filter { $0.parent == slug && $0.slug != slug }.sorted { a, b in
            if a.isClosed != b.isClosed { return !a.isClosed }
            return (a.lastActive ?? 0) > (b.lastActive ?? 0)
        }
    }

    /// Every agent in tree order, depth first from pai: how the bot chat's topic list runs.
    public static func treeOrder() -> [PaiAgent] {
        var result: [PaiAgent] = []
        func walk(_ agent: PaiAgent) {
            guard !result.contains(where: { $0.slug == agent.slug }) else { return }
            result.append(agent)
            for child in children(of: agent.slug) { walk(child) }
        }
        if let pai = agent(paiSlug) { walk(pai) }
        let slugs = Set(agents.map(\.slug))
        // Agents whose parent is unknown hang under pai.
        for orphan in agents where orphan.parent.map({ !slugs.contains($0) }) ?? (orphan.slug != paiSlug) {
            walk(orphan)
        }
        return result
    }

    /// Where a topic of the bot chat stands in the topic list, 0 first: pai's main topic, then the agents in tree
    /// order; nil for a topic that is no agent's (a plain thread), which follows them by its last message.
    public static func topicRank(thread: Int64) -> Int? {
        if thread == mainThreadId { return 0 }
        guard let index = treeOrder().firstIndex(where: { $0.threadId == thread && !$0.isPai }) else { return nil }
        return index + 1
    }
}

// MARK: Forwarding

extension PaiChat {
    /// A message of the bot chat that is pai's log, loaded into an agent's topic from before the topic existed: no
    /// Telegram message, so it is forwarded once the bot has posted it (`POST /telegram/materialize`).
    public static func isHistoryRow(_ message: Message) -> Bool {
        message.id.namespace == Namespaces.Message.Box && isBot(message.peers[message.id.peerId])
    }

    /// Whether a message of the bot chat may be forwarded: his own words and what pai and its agents answered, never
    /// an event, card, ask, notice or status line.
    public static func isForwardable(_ message: Message) -> Bool {
        if message.isPaiEcho || !message.flags.contains(.Incoming) {
            return true
        }
        guard let kind = PaiTrailer.find(message)?.meta.kind else {
            return true
        }
        return forwardableKinds.contains(kind)
    }

    private static let forwardableKinds: Set<String> = ["turn", "result", "report", "user"]
}

/// A plain thread (`start_thread`, not an agent) named only by its short id, the way pai mentions one in a
/// reply: "started [UI fixes · 323f24]" — a session id's first six hex characters (`Session.shortId`).
public enum PaiThreadLink {
    private static let pattern = try! NSRegularExpression(pattern: "\\s·\\s([0-9a-f]{6})$")

    public static func shortId(in linkText: String) -> String? {
        let text = linkText as NSString
        guard let match = pattern.firstMatch(in: linkText, range: NSRange(location: 0, length: text.length)), match.range(at: 1).location != NSNotFound else {
            return nil
        }
        return text.substring(with: match.range(at: 1))
    }
}
