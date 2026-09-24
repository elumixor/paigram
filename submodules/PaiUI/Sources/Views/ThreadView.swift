import SwiftUI

/// One conversation, rendered the way Claude Code prints it: `❯` for you, `⏺` for the assistant, `⎿` for results.
@available(iOS 16.0, *)
struct ThreadView: View {
    let sessionId: String
    @EnvironmentObject private var store: PaiStore
    @StateObject private var model: ThreadModelHolder

    init(sessionId: String) {
        self.sessionId = sessionId
        _model = StateObject(wrappedValue: ThreadModelHolder(sessionId: sessionId))
    }

    private var session: PaiSession? { store.session(sessionId) }

    var body: some View {
        let thread = model.thread(store: store)
        VStack(spacing: 0) {
            ThreadTranscript(thread: thread)
            if let error = thread.error {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 16).padding(.bottom, 4)
            }
            if thread.isBusy { WorkingBar(tool: thread.currentTool) }
            Composer(placeholder: thread.hasPendingQuestion ? "Answer" : "Reply", isBusy: thread.isBusy,
                     onSend: { text in Task { await thread.send(text) } },
                     onStop: { Task { await thread.interrupt() } })
        }
        .navigationTitle(session?.displayTitle ?? "Thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
        }
        .onAppear(perform: thread.start)
        .onDisappear(perform: thread.stop)
    }

    private var header: some View {
        VStack(spacing: 1) {
            Text(session?.displayTitle ?? "Thread").font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                if let session { StateDot(session: session) }
                Text([session?.project, session?.model.map(Self.shortModel), session?.shortId].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private static func shortModel(_ model: String) -> String {
        model.replacingOccurrences(of: "claude-", with: "").split(separator: "-").prefix(2).joined(separator: " ")
    }
}

/// Keeps one `ThreadModel` alive for the view's lifetime; the client only exists once the store does.
@available(iOS 16.0, *)
@MainActor
final class ThreadModelHolder: ObservableObject {
    private let sessionId: String
    private var model: ThreadModel?
    init(sessionId: String) { self.sessionId = sessionId }
    func thread(store: PaiStore) -> ThreadModel {
        if let model { return model }
        let created = ThreadModel(sessionId: sessionId, client: store.client, busy: store.session(sessionId)?.isRunning ?? false)
        model = created
        return created
    }
}

@available(iOS 16.0, *)
struct ThreadTranscript: View {
    @ObservedObject var thread: ThreadModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if thread.isLoading {
                        ForEach(0..<5, id: \.self) { _ in SkeletonRow() }
                    }
                    ForEach(thread.entries) { entry in
                        EntryView(entry: entry, thread: thread)
                            .id(entry.id)
                            .transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .animation(.easeOut(duration: 0.2), value: thread.entries.count)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: thread.entries.last?.id) { _ in withAnimation { proxy.scrollTo("bottom") } }
            .onChange(of: thread.isLoading) { _ in proxy.scrollTo("bottom") }
        }
    }
}

/// Shown under the transcript while a turn runs: what the assistant is doing this second.
@available(iOS 16.0, *)
struct WorkingBar: View {
    let tool: String?
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.accentColor).frame(width: 8, height: 8).modifier(Breathing())
            ToolTicker(text: tool ?? "Thinking…")
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }
}
