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
    @Published public private(set) var connectionError: String?
    @Published public private(set) var isLoading = false

    public let client = PaiClient()
    private var followTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    private static let reconnectDelay: UInt64 = 4_000_000_000
    private static let refreshDebounce: UInt64 = 300_000_000

    public init() {}

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
        do {
            async let tasks = client.tasks()
            async let projects = client.projects()
            let (fetched, fetchedProjects) = try await (tasks, projects)
            self.sessions = Self.merge(live: fetched.live, recent: fetched.recent)
            self.projects = fetchedProjects
            connectionError = nil
        } catch is CancellationError {
        } catch {
            connectionError = error.localizedDescription
        }
    }

    /// Live processes win over their database rows; sorted so the ones needing attention come first.
    private static func merge(live: [PaiSession], recent: [PaiSession]) -> [PaiSession] {
        var byId: [String: PaiSession] = [:]
        for session in recent { byId[session.sessionId] = session }
        // A live process knows its state; only the database row remembers the last reply.
        for session in live { byId[session.sessionId] = session.withLastResult(byId[session.sessionId]?.lastResult) }
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
        if event.kind == "session.tool", let id = event.sessionId, let summary = event.payload["summary"]?.string {
            sessions = sessions.map { $0.sessionId == id ? $0.withTool(summary) : $0 }
        }
        if Self.refreshingKinds.contains(event.kind) { refresh() }
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
}

private extension PaiSession {
    func withLastResult(_ result: String?) -> PaiSession {
        guard lastResult == nil, let result else { return self }
        return PaiSession(sessionId: sessionId, shortId: shortId, kind: kind, title: title, project: project, state: state,
                          lastActivity: lastActivity, costUsd: costUsd, turns: turns, model: model, lastTool: lastTool,
                          recentTools: recentTools, waiting: waiting, lastResult: result, parent: parent, threadId: threadId)
    }

    func withTool(_ summary: String) -> PaiSession {
        PaiSession(sessionId: sessionId, shortId: shortId, kind: kind, title: title, project: project, state: .busy,
                   lastActivity: Date().timeIntervalSince1970 * 1000, costUsd: costUsd, turns: turns, model: model,
                   lastTool: summary, recentTools: ((recentTools ?? []) + [summary]).suffix(5).map { $0 },
                   waiting: false, lastResult: lastResult, parent: parent, threadId: threadId)
    }
}
