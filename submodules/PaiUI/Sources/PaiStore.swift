import Foundation
import SwiftUI

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
    /// Each agent's chat as far as it has been opened, newest last; cached so it opens at once.
    @Published public private(set) var messages: [String: [PaiLogMessage]] = [:]
    @Published public private(set) var connectionError: String?
    @Published public private(set) var isLoading = false

    public let client = PaiClient()
    private var followTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var agentsTask: Task<Void, Never>?

    private static let reconnectDelay: UInt64 = 4_000_000_000
    private static let refreshDebounce: UInt64 = 300_000_000

    private static let cacheKey = "pai.cache"

    /// The last list seen is shown at once; the daemon's answer replaces it.
    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey), let cached = try? JSONDecoder().decode(Cache.self, from: data) {
            sessions = cached.sessions
            projects = cached.projects
        }
    }

    private struct Cache: Codable {
        let sessions: [PaiSession]
        let projects: [PaiProject]
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Cache(sessions: sessions, projects: projects)) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    public var running: [PaiSession] { sessions.filter { $0.isRunning && !$0.isWaiting } }
    public var waiting: [PaiSession] { sessions.filter { $0.isWaiting } }
    public var rest: [PaiSession] { sessions.filter { !$0.isRunning && !$0.isWaiting } }

    public func session(_ id: String) -> PaiSession? { sessions.first { $0.sessionId == id } }

    public func start() {
        guard followTask == nil else { return }
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
            try? await Task.sleep(nanoseconds: Self.refreshDebounce)
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
            if let usage = try? await client.usage() { PaiChat.usage = usage }
        }
        refreshNeeds()
        do {
            async let tasks = client.tasks()
            async let projects = client.projects()
            async let held = client.allThreads()
            let (fetched, fetchedProjects, fetchedHeld) = try await (tasks, projects, held)
            self.sessions = Self.merge(live: fetched.live, recent: fetched.recent, held: fetchedHeld.map(\.asSession))
            self.projects = fetchedProjects
            connectionError = nil
            persist()
        } catch is CancellationError {
        } catch {
            connectionError = error.localizedDescription
        }
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
        "task.created", "session.started", "session.resumed", "session.turn_end", "session.exit",
        "session.question", "session.answer", "session.input", "session.error",
    ]

    private func handle(_ event: PaiEvent) {
        if event.kind == "message.new", let message = try? event.payload.decode(PaiLogMessage.self) {
            receive(message)
        }
        if event.kind.hasPrefix("agent.") { refreshAgents() }
        if event.kind == "message.new" || event.kind == "session.question" || event.kind == "session.answer" || event.kind.hasPrefix("ask.") { refreshNeeds() }
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
            try? await Task.sleep(nanoseconds: Self.refreshDebounce)
            guard let self, !Task.isCancelled, let fetched = try? await self.client.needs() else { return }
            PaiChat.needs = fetched
        }
    }

    // MARK: Agents

    public func agent(_ slug: String) -> PaiAgent? { agents.first { $0.slug == slug } }

    public func refreshAgents() {
        agentsTask?.cancel()
        agentsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.refreshDebounce)
            guard let self, !Task.isCancelled, let fetched = try? await self.client.agents() else { return }
            PaiChat.agents = fetched
            if fetched != self.agents { self.agents = fetched }
        }
    }

    private static func messagesKey(_ slug: String) -> String { "pai.messages.\(slug)" }
    private static let keptMessages = 200

    /// Reads an agent's cached chat before its screen first draws, so it opens at once.
    public func prime(_ slug: String) { _ = chat(slug) }

    /// What a view shows of an agent's chat; `loadChat` fills it.
    public func rows(_ slug: String) -> [PaiLogMessage] { messages[slug] ?? [] }

    /// An agent's chat as cached, read from disk the first time.
    private func chat(_ slug: String) -> [PaiLogMessage] {
        if let rows = messages[slug] { return rows }
        let cached = UserDefaults.standard.data(forKey: Self.messagesKey(slug)).flatMap { try? JSONDecoder().decode([PaiLogMessage].self, from: $0) } ?? []
        messages[slug] = cached
        return cached
    }

    private func store(_ rows: [PaiLogMessage], for slug: String) {
        let kept = Array(rows.suffix(Self.keptMessages))
        messages[slug] = kept
        if let data = try? JSONEncoder().encode(kept.filter { $0.id > 0 }) { UserDefaults.standard.set(data, forKey: Self.messagesKey(slug)) }
    }

    /// Catches an agent's chat up: what came after the last row held, or the latest page the first time.
    public func loadChat(_ slug: String) async {
        let held = chat(slug)
        guard !Task.isCancelled else { return }
        let last = held.last(where: { $0.id > 0 })?.id
        do {
            let fetched = try await client.messages(agent: slug, after: last)
            merge(fetched, into: slug)
            connectionError = nil
        } catch is CancellationError {
        } catch {
            connectionError = error.localizedDescription
        }
    }

    private func merge(_ rows: [PaiLogMessage], into slug: String) {
        guard !rows.isEmpty else { return }
        var byId: [Int: PaiLogMessage] = [:]
        for row in chat(slug) { byId[row.id] = row }
        for row in rows { byId[row.id] = row }
        // What the user wrote shows at once; the logged row replaces it when it arrives.
        let sent = Set(rows.filter { $0.from == "user" }.map(\.body))
        let merged = byId.values.filter { $0.id > 0 || !sent.contains($0.body) }.sorted { a, b in
            if (a.id > 0) != (b.id > 0) { return a.id > 0 }
            return a.id > 0 ? a.id < b.id : a.id > b.id
        }
        store(merged, for: slug)
    }

    /// A row from the live stream lands in every open chat it belongs to.
    private func receive(_ message: PaiLogMessage) {
        for slug in messages.keys where message.concerns(slug) {
            merge([message], into: slug)
        }
    }

    /// The user writes to an agent; the row shows before the daemon has logged it.
    public func send(_ text: String, to slug: String) async throws {
        let pending = PaiLogMessage(id: -Int(Date().timeIntervalSince1970 * 1000), from: "user", to: slug, kind: "chat", body: text, createdAt: Date().timeIntervalSince1970 * 1000)
        store(chat(slug) + [pending], for: slug)
        do {
            try await client.message(agent: slug, text: text)
        } catch {
            store(chat(slug).filter { $0.id != pending.id }, for: slug)
            throw error
        }
    }

    /// Answers an agent's question; the ask shows the answer from then on.
    public func answer(ask id: Int, text: String, in slug: String) async throws {
        try await client.answer(ask: id, text: text)
        store(chat(slug).map { row in
            guard row.meta.askId == id, row.kind == "ask" else { return row }
            var row = row
            row.meta.answer = text
            return row
        }, for: slug)
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
