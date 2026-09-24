import Foundation
import SwiftUI

/// One line of a thread, in the order it happened.
@available(iOS 16.0, *)
@available(iOS 16.0, *)
public struct ThreadEntry: Identifiable, Equatable {
    public enum Kind: Equatable {
        case user(String)
        case assistant(text: String, live: Bool)
        case thinking(String)
        case tool(name: String, summary: String, result: String?, running: Bool, depth: Int)
        case question(questionId: String, questions: [PaiQuestion])
        case notice(String, isError: Bool)
    }
    public let id: String
    public var kind: Kind
}

/// A thread's history plus what the daemon streams while it works.
@available(iOS 16.0, *)
@available(iOS 16.0, *)
@MainActor
public final class ThreadModel: ObservableObject {
    @Published public private(set) var entries: [ThreadEntry] = []
    @Published public private(set) var isBusy = false
    @Published public private(set) var currentTool: String?
    @Published public private(set) var error: String?
    @Published public private(set) var isLoading = true

    public let sessionId: String
    private let client: PaiClient
    private var followTask: Task<Void, Never>?
    private var liveTextId: String?
    private var toolDepths: [String: Int] = [:]
    private var counter = 0

    private static let reconnectDelay: UInt64 = 4_000_000_000

    public init(sessionId: String, client: PaiClient, busy: Bool) {
        self.sessionId = sessionId
        self.client = client
        self.isBusy = busy
    }

    private func nextId(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(counter)"
    }

    public func start() {
        followTask?.cancel()
        followTask = Task { [weak self] in
            guard let self else { return }
            await self.loadHistory()
            while !Task.isCancelled {
                do {
                    for try await event in self.client.events(session: self.sessionId, deltas: true) {
                        self.handle(event)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.error = error.localizedDescription
                }
                try? await Task.sleep(nanoseconds: Self.reconnectDelay)
            }
        }
    }

    public func stop() {
        followTask?.cancel()
        followTask = nil
    }

    private func loadHistory() async {
        defer { isLoading = false }
        do {
            let messages = try await client.transcript(session: sessionId)
            entries = messages.flatMap { message -> [ThreadEntry] in
                var items: [ThreadEntry] = []
                if let thinking = message.thinking, !thinking.isEmpty { items.append(ThreadEntry(id: nextId("th"), kind: .thinking(thinking))) }
                if let text = message.text, !text.isEmpty, message.meta != true {
                    items.append(ThreadEntry(id: nextId("m"), kind: message.role == "user" ? .user(text) : .assistant(text: text, live: false)))
                }
                for tool in message.tools ?? [] {
                    items.append(ThreadEntry(id: tool.id, kind: .tool(name: tool.name, summary: tool.input ?? tool.name, result: tool.result, running: false, depth: 0)))
                }
                return items
            }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Events

    private func handle(_ event: PaiEvent) {
        let p = event.payload
        switch event.kind {
        case "session.input":
            isBusy = true
            if let text = p["text"]?.string, !text.isEmpty, !isDuplicateUserLine(text) {
                entries.append(ThreadEntry(id: nextId("u"), kind: .user(text)))
            }
        case "session.delta":
            isBusy = true
            guard let text = p["text"]?.string, !text.isEmpty else { return }
            if let id = liveTextId, let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].kind = .assistant(text: text, live: true)
            } else {
                let id = nextId("a")
                liveTextId = id
                entries.append(ThreadEntry(id: id, kind: .assistant(text: text, live: true)))
            }
        case "session.text":
            guard let text = p["text"]?.string, !text.isEmpty else { return }
            if let id = liveTextId, let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].kind = .assistant(text: text, live: false)
            } else {
                entries.append(ThreadEntry(id: nextId("a"), kind: .assistant(text: text, live: false)))
            }
            liveTextId = nil
        case "session.tool":
            isBusy = true
            liveTextId = nil
            guard let id = p["id"]?.string else { return }
            let depth = p["parent"]?.string.flatMap { toolDepths[$0] }.map { $0 + 1 } ?? 0
            toolDepths[id] = depth
            let summary = p["summary"]?.string ?? p["name"]?.string ?? "tool"
            currentTool = summary
            entries.append(ThreadEntry(id: id, kind: .tool(name: p["name"]?.string ?? "tool", summary: summary, result: nil, running: true, depth: depth)))
        case "session.tool_result":
            guard let id = p["id"]?.string, let index = entries.firstIndex(where: { $0.id == id }),
                  case .tool(let name, let summary, _, _, let depth) = entries[index].kind else { return }
            entries[index].kind = .tool(name: name, summary: summary, result: p["result"]?.string, running: false, depth: depth)
            if currentTool == summary { currentTool = nil }
        case "session.question":
            guard let id = p["id"]?.string, let questions = try? p["questions"]?.decode([PaiQuestion].self) else { return }
            liveTextId = nil
            entries.append(ThreadEntry(id: "q-\(id)", kind: .question(questionId: id, questions: questions)))
        case "session.answer":
            entries.removeAll { if case .question = $0.kind { return true } else { return false } }
        case "session.turn_end", "session.exit":
            isBusy = false
            currentTool = nil
            liveTextId = nil
            finishRunningTools()
            if event.kind == "session.turn_end", p["isError"]?.bool == true, let text = p["text"]?.string {
                entries.append(ThreadEntry(id: nextId("n"), kind: .notice(text, isError: true)))
            }
        case "session.progress", "session.notice":
            if let text = p["text"]?.string { entries.append(ThreadEntry(id: nextId("n"), kind: .notice(text, isError: false))) }
        case "session.status":
            if p["status"]?.string == "compacting" { entries.append(ThreadEntry(id: nextId("n"), kind: .notice("Compacting context…", isError: false))) }
        case "session.error":
            isBusy = false
            if let message = p["message"]?.string { entries.append(ThreadEntry(id: nextId("n"), kind: .notice(message, isError: true))) }
        default:
            break
        }
    }

    private func isDuplicateUserLine(_ text: String) -> Bool {
        if case .user(let last) = entries.last?.kind { return last == text }
        return false
    }

    private func finishRunningTools() {
        entries = entries.map { entry in
            guard case .tool(let name, let summary, let result, true, let depth) = entry.kind else { return entry }
            return ThreadEntry(id: entry.id, kind: .tool(name: name, summary: summary, result: result, running: false, depth: depth))
        }
    }

    // MARK: Actions

    public func send(_ text: String) async {
        entries.append(ThreadEntry(id: nextId("u"), kind: .user(text)))
        isBusy = true
        do {
            if hasPendingQuestion {
                try await client.answer(session: sessionId, text: text)
            } else {
                _ = try await client.send(session: sessionId, text: text)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            isBusy = false
        }
    }

    public func answer(_ text: String) async {
        do {
            try await client.answer(session: sessionId, text: text)
            entries.append(ThreadEntry(id: nextId("u"), kind: .user(text)))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func interrupt() async {
        do { try await client.stop(session: sessionId) } catch { self.error = error.localizedDescription }
    }

    public var hasPendingQuestion: Bool {
        entries.contains { if case .question = $0.kind { return true } else { return false } }
    }
}
