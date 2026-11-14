import Foundation
import SwiftUI

/// One store for the app's lifetime; the chat starts it and the screens read from it.
@available(iOS 16.0, *)
@MainActor
public enum PaiHost {
    public static let store = PaiStore()
}

/// Every thread the daemon knows, kept current from the global event stream.
@available(iOS 16.0, *)
@MainActor
public final class PaiStore: ObservableObject {
    @Published public private(set) var sessions: [PaiSession] = [] {
        didSet {
            let active = sessions.contains { $0.isRunning || $0.isWaiting }
            if active != hasActive {
                hasActive = active
                NotificationCenter.default.post(name: PaiChat.activityChanged, object: active)
            }
        }
    }
    public private(set) var hasActive = false
    @Published public private(set) var projects: [PaiProject] = []
    /// pai and its agents; the same list `PaiChat.agents` keeps for the chat's nodes.
    @Published public private(set) var agents: [PaiAgent] = PaiChat.agents
    @Published public private(set) var connectionError: String?
    /// Messages agents wrote for the user to send, still waiting on him.
    @Published public private(set) var drafts: [PaiDraft] = []
    @Published public private(set) var isLoading = false

    public let client = PaiClient()
    private var followTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var agentsTask: Task<Void, Never>?
    /// Fetches that have succeeded once: until then a refresh goes at once, after that it waits out a burst of events.
    private var settled: Set<String> = []
    /// `/threads/all` from the last load, merged into the next one until its own answer arrives.
    private var heldSessions: [PaiSession]?

    private static let reconnectDelay: UInt64 = 4_000_000_000
    private static let refreshDebounce: UInt64 = 300_000_000

    private static let cacheName = "store"

    /// The last list seen is shown as soon as it is read (off the main thread); the daemon's answer replaces it.
    public init() {
        PaiPerf.first("store.init")
        Task { [weak self] in
            guard let cached = await PaiCache.load(Cache.self, Self.cacheName, legacyKey: "pai.cache") else { return }
            guard let self, !self.settled.contains("refresh") else { return }
            self.sessions = cached.sessions
            self.projects = cached.projects
            if !cached.sessions.isEmpty { PaiPerf.first("sessions.cached") }
        }
    }

    private struct Cache: Codable {
        let sessions: [PaiSession]
        let projects: [PaiProject]
    }

    private func persist() {
        PaiCache.save(Cache(sessions: sessions, projects: projects), Self.cacheName)
    }

    /// No wait before a fetch that has not succeeded yet, the debounce after.
    private func delay(_ fetch: String) -> UInt64 {
        settled.contains(fetch) ? Self.refreshDebounce : 0
    }

    public var running: [PaiSession] { sessions.filter { $0.isRunning && !$0.isWaiting } }
    public var waiting: [PaiSession] { sessions.filter { $0.isWaiting } }
    public var rest: [PaiSession] { sessions.filter { !$0.isRunning && !$0.isWaiting } }

    public func session(_ id: String) -> PaiSession? { sessions.first { $0.sessionId == id } }

    public func start() {
        guard followTask == nil else { return }
        PaiPerf.first("store.start")
        connectionError = nil
        refresh()
        followTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    for try await event in self.client.events(session: nil, deltas: false) {
                        self.handle(event)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.connectionError = error.localizedDescription
                }
                try? await Task.sleep(nanoseconds: Self.reconnectDelay)
            }
        }
    }

    public func stop() {
        followTask?.cancel()
        followTask = nil
    }

    public func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.delay("refresh"))
            guard !Task.isCancelled else { return }
            await self.load()
        }
    }

    private func load() async {
        isLoading = sessions.isEmpty
        defer { isLoading = false }
        // Agents and pai's topic come on their own: a daemon without them still lists threads.
        refreshAgents()
        Task { [client] in
            if let mainThread = try? await client.telegramInfo().mainThread { PaiChat.mainThreadId = mainThread }
        }
        Task { [client] in
            if let usage = try? await client.usage() {
                PaiPerf.mark("load.usage")
                PaiChat.usage = usage
            }
        }
        refreshNeeds()
        // `/threads/all` is the slow one: the list shows from tasks and projects, the held threads join when they come.
        async let held = Self.timed("load.threads") { try await client.allThreads() }
        let fetched: PaiTasks
        do {
            async let tasks = Self.timed("load.tasks") { try await client.tasks() }
            async let projects = Self.timed("load.projects") { try await client.projects() }
            let (fetchedTasks, fetchedProjects) = try await (tasks, projects)
            fetched = fetchedTasks
            sessions = Self.merge(live: fetched.live, recent: fetched.recent, held: heldSessions ?? sessions)
            self.projects = fetchedProjects
            connectionError = nil
            settled.insert("refresh")
            PaiPerf.first("sessions.network")
            persist()
        } catch is CancellationError {
            return
        } catch {
            connectionError = error.localizedDescription
            return
        }
        guard let fetchedHeld = try? await held, !Task.isCancelled else { return }
        heldSessions = fetchedHeld.map(\.asSession)
        sessions = Self.merge(live: fetched.live, recent: fetched.recent, held: heldSessions ?? [])
        PaiPerf.first("sessions.held")
        persist()
    }

    /// Logs when one of `load`'s requests is done.
    private static func timed<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        let value = try await work()
        PaiPerf.mark(name)
        return value
    }

    /// Live processes win over their database rows; sorted so the ones needing attention come first.
    private static func merge(live: [PaiSession], recent: [PaiSession], held: [PaiSession] = []) -> [PaiSession] {
        var byId: [String: PaiSession] = [:]
        for session in held { byId[session.sessionId] = session }
        for session in recent { byId[session.sessionId] = session.withCwd(byId[session.sessionId]?.cwd) }
        // A live process knows its state; only the database row remembers the last reply.
        for session in live { byId[session.sessionId] = session.withLastResult(byId[session.sessionId]?.lastResult).withCwd(byId[session.sessionId]?.cwd) }
        return byId.values.filter { $0.parent == nil }.sorted { a, b in
            let ra = a.isWaiting ? 0 : a.isRunning ? 1 : 2
            let rb = b.isWaiting ? 0 : b.isRunning ? 1 : 2
            return ra != rb ? ra < rb : a.lastActivity > b.lastActivity
        }
    }

    private static let refreshingKinds: Set<String> = [
        "task.created", "task.added", "task.updated", "session.started", "session.resumed", "session.turn_end", "session.exit",
        "session.question", "session.answer", "session.input", "session.error",
    ]

    private func handle(_ event: PaiEvent) {
        if event.kind.hasPrefix("agent.") { refreshAgents() }
        if event.kind.hasPrefix("draft.") || event.kind == "message.new" { refreshDrafts() }
        // A task waiting on the user is one of the decisions `/needs` serves, so a task that was
        // finished anywhere — by him, by an agent, in conversation — has to take its card away.
        if event.kind == "message.new" || event.kind == "session.question" || event.kind == "session.answer" || event.kind.hasPrefix("ask.") || event.kind.hasPrefix("task.") { refreshNeeds() }
        if event.kind == "session.tool", let id = event.sessionId, let summary = event.payload["summary"]?.string {
            sessions = sessions.map { $0.sessionId == id ? $0.withTool(summary) : $0 }
        }
        if Self.refreshingKinds.contains(event.kind) { refresh() }
        if event.kind != "session.delta" { NotificationCenter.default.post(name: PaiChat.changed, object: nil) }
    }

    // MARK: Decisions

    private var needsTask: Task<Void, Never>?

    /// What waits on the user, fetched again whenever a question opens or closes anywhere.
    public func refreshNeeds() {
        needsTask?.cancel()
        needsTask = Task { [weak self] in
            guard let delay = self?.delay("needs") else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, let fetched = try? await self.client.needs() else { return }
            PaiPerf.mark("load.needs")
            self.settled.insert("needs")
            PaiChat.needs = fetched
        }
    }

    // MARK: Drafts

    private var draftsTask: Task<Void, Never>?

    public func drafts(of slug: String) -> [PaiDraft] { drafts.filter { $0.agent == slug } }

    public func refreshDrafts() {
        draftsTask?.cancel()
        draftsTask = Task { [weak self] in
            guard let delay = self?.delay("drafts") else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, let fetched = try? await self.client.drafts() else { return }
            self.settled.insert("drafts")
            let pending = fetched.filter(\.isPending)
            if pending != self.drafts { self.drafts = pending }
        }
    }

    /// Sends or drops a draft; its card goes at once and comes back if the daemon refuses.
    public func resolve(draft id: Int, send: Bool) async throws {
        let held = drafts
        drafts.removeAll { $0.id == id }
        do {
            if send {
                try await client.sendDraft(id)
            } else {
                try await client.discardDraft(id)
            }
        } catch {
            drafts = held
            throw error
        }
    }

    // MARK: Agents

    public func agent(_ slug: String) -> PaiAgent? { agents.first { $0.slug == slug } }

    public func refreshAgents() {
        agentsTask?.cancel()
        agentsTask = Task { [weak self] in
            guard let delay = self?.delay("agents") else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, let fetched = try? await self.client.agents() else { return }
            PaiPerf.mark("load.agents")
            self.settled.insert("agents")
            PaiChat.agents = fetched
            if fetched != self.agents { self.agents = fetched }
        }
    }

    // MARK: Actions

    private static let topicWait: UInt64 = 500_000_000
    private static let topicAttempts = 20

    /// Starts a thread and waits for the bot to give it a Telegram topic, so it can be opened as a chat.
    public func newThread(text: String, project: String?) async throws -> PaiSession {
        var created = try await client.newThread(text: text, project: project)
        sessions = Self.merge(live: [created], recent: sessions)
        for _ in 0..<Self.topicAttempts where created.threadId == nil {
            try await Task.sleep(nanoseconds: Self.topicWait)
            let tasks = try await client.tasks()
            if let fresh = (tasks.live + tasks.recent).first(where: { $0.sessionId == created.sessionId }) { created = fresh }
        }
        sessions = Self.merge(live: [created], recent: sessions)
        return created
    }

    public func telegramInfo() async throws -> PaiTelegramInfo { try await client.telegramInfo() }

    /// Brings a conversation held on disk to life and waits for its Telegram topic.
    public func adopt(_ session: PaiSession) async throws -> PaiSession {
        guard let cwd = session.cwd else { throw PaiClientError(message: "This conversation has no folder to open it in") }
        var live = try await client.adopt(session: session.sessionId, cwd: cwd, title: session.title)
        for _ in 0..<Self.topicAttempts where live.threadId == nil {
            try await Task.sleep(nanoseconds: Self.topicWait)
            let tasks = try await client.tasks()
            if let fresh = (tasks.live + tasks.recent).first(where: { $0.sessionId == live.sessionId }) { live = fresh }
        }
        sessions = Self.merge(live: [live], recent: sessions)
        return live
    }
}

private extension PaiSession {
    func withLastResult(_ result: String?) -> PaiSession {
        guard lastResult == nil, let result else { return self }
        return PaiSession(sessionId: sessionId, shortId: shortId, kind: kind, title: title, project: project, state: state,
                          lastActivity: lastActivity, costUsd: costUsd, turns: turns, model: model, lastTool: lastTool,
                          recentTools: recentTools, waiting: waiting, lastResult: result, parent: parent, threadId: threadId, cwd: cwd)
    }

    func withCwd(_ path: String?) -> PaiSession {
        guard let path, cwd != path else { return self }
        return PaiSession(sessionId: sessionId, shortId: shortId, kind: kind, title: title, project: project, state: state,
                          lastActivity: lastActivity, costUsd: costUsd, turns: turns, model: model, lastTool: lastTool,
                          recentTools: recentTools, waiting: waiting, lastResult: lastResult, parent: parent, threadId: threadId, cwd: path)
    }

    func withTool(_ summary: String) -> PaiSession {
        PaiSession(sessionId: sessionId, shortId: shortId, kind: kind, title: title, project: project, state: .busy,
                   lastActivity: Date().timeIntervalSince1970 * 1000, costUsd: costUsd, turns: turns, model: model,
                   lastTool: summary, recentTools: ((recentTools ?? []) + [summary]).suffix(5).map { $0 },
                   waiting: false, lastResult: lastResult, parent: parent, threadId: threadId, cwd: cwd)
    }
}
