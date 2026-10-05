import SwiftUI

/// What the hub shows besides the agents: the task board, routines, and what sessions are given.
@available(iOS 16.0, *)
@MainActor
final class PaiHubStore: ObservableObject {
    @Published private(set) var tasks: [PaiTaskItem] = []
    @Published private(set) var routines: [PaiRoutine] = []
    @Published private(set) var needs: [PaiNeed] = []
    @Published private(set) var loaded = false
    @Published var error: String?
    /// Memories, tools and skills come with the daemon's context, the same store Settings reads.
    let settings = PaiSettingsStore()
    private let client = PaiClient()
    private var observer: NSObjectProtocol?
    private var reload: Task<Void, Never>?

    func start() {
        if observer == nil {
            // Anything the daemon reports moving reloads the board a moment later, once a burst of events settles.
            observer = NotificationCenter.default.addObserver(forName: PaiChat.changed, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleReload() }
            }
        }
        Task {
            await load()
            await settings.load()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func scheduleReload() {
        reload?.cancel()
        reload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    func load() async {
        async let tasks = try? client.taskItems(includeClosed: true)
        async let routines = try? client.routines()
        async let needs = try? client.needs()
        let (t, r, n) = await (tasks, routines, needs)
        if let t { self.tasks = t }
        if let r { self.routines = r }
        if let n { self.needs = n }
        loaded = true
    }

    func move(_ task: PaiTaskItem, to status: String) {
        guard task.status != status, let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let before = tasks[index]
        tasks[index].status = status
        tasks[index].updatedAt = Date().timeIntervalSince1970 * 1000
        Task {
            do {
                _ = try await client.updateTask(task.id, status: status)
            } catch {
                if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = before }
                self.error = error.localizedDescription
            }
        }
    }

    func setRoutine(_ routine: PaiRoutine, enabled: Bool) {
        guard let index = routines.firstIndex(where: { $0.id == routine.id }) else { return }
        routines[index].enabled = enabled
        Task {
            do {
                _ = try await client.setRoutine(routine.id, enabled: enabled)
            } catch {
                if let index = routines.firstIndex(where: { $0.id == routine.id }) { routines[index].enabled = !enabled }
                self.error = error.localizedDescription
            }
        }
    }

    func answer(_ need: PaiNeed, _ text: String) {
        needs.removeAll { $0.id == need.id }
        Task {
            do {
                try await client.answer(need, text: text)
            } catch {
                self.error = error.localizedDescription
            }
            await load()
        }
    }

    func stop(agent: PaiAgent) {
        Task {
            do {
                try await client.stop(agent: agent.slug)
            } catch {
                self.error = error.localizedDescription
            }
            PaiHost.store.refreshAgents()
        }
    }

    func stop(thread: PaiAgentThread) {
        Task {
            do {
                try await client.stop(session: thread.sessionId)
            } catch {
                self.error = error.localizedDescription
            }
            PaiHost.store.refreshAgents()
        }
    }
}

@available(iOS 16.0, *)
enum HubTab: String, CaseIterable, Identifiable {
    case agents, tasks, routines, memory, tools, skills

    var id: String { rawValue }
    var title: String {
        switch self {
        case .agents: return "Agents"
        case .tasks: return "Tasks"
        case .routines: return "Routines"
        case .memory: return "Memory"
        case .tools: return "Tools"
        case .skills: return "Skills"
        }
    }
    var symbol: String {
        switch self {
        case .agents: return "person.2"
        case .tasks: return "rectangle.split.3x1"
        case .routines: return "clock.arrow.circlepath"
        case .memory: return "brain.head.profile"
        case .tools: return "wrench.and.screwdriver"
        case .skills: return "sparkles"
        }
    }
}

/// The hub: a row of tabs over one pane at a time.
@available(iOS 16.0, *)
struct HubView: View {
    let openAgent: (PaiAgent) -> Void
    let openThread: (Int64) -> Void
    let close: () -> Void
    @EnvironmentObject private var store: PaiStore
    @StateObject private var hub = PaiHubStore()
    @State private var tab: HubTab = .agents

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                Divider()
                pane.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(tab.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(action: close) { Image(systemName: "chevron.left") } }
                ToolbarItem(placement: .topBarTrailing) {
                    if let error = hub.error ?? store.connectionError {
                        Image(systemName: "bolt.slash").foregroundStyle(.red).help(error).onTapGesture { hub.error = nil }
                    }
                }
            }
            .navigationDestination(for: ContextItemRoute.self) { route in
                ContextDetailView(id: route.id, settings: hub.settings)
            }
        }
        .onAppear {
            store.start()
            store.refreshAgents()
            hub.start()
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HubTab.allCases) { item in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { tab = item }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: item.symbol).font(.footnote.weight(.semibold))
                            Text(item.title).font(.subheadline.weight(.medium))
                            if let count = badge(item), count > 0 {
                                Text("\(count)").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(item == .agents ? Color.paiWaiting : Color.secondary.opacity(0.25), in: Capsule())
                                    .foregroundStyle(item == .agents ? Color.white : Color.primary)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .foregroundStyle(tab == item ? Color.white : Color.primary)
                        .background(tab == item ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private func badge(_ item: HubTab) -> Int? {
        switch item {
        case .agents: return hub.needs.count
        case .tasks: return hub.tasks.filter(\.isOpen).count
        default: return nil
        }
    }

    @ViewBuilder private var pane: some View {
        switch tab {
        case .agents: AgentsPane(hub: hub, openAgent: openAgent, openThread: openThread)
        case .tasks: TaskBoard(hub: hub, openAgent: openAgent)
        case .routines: RoutinesPane(hub: hub)
        case .memory: ContextListView(kind: "memory", title: "Memory", settings: hub.settings)
        case .tools: ContextListView(kind: "tool", title: "Tools", settings: hub.settings)
        case .skills: ContextListView(kind: "skill", title: "Skills", settings: hub.settings)
        }
    }
}

// MARK: Agents

/// What waits on the user first, then pai and every agent under it with the threads each started; anything
/// running has a stop button right on its row.
@available(iOS 16.0, *)
private struct AgentsPane: View {
    @ObservedObject var hub: PaiHubStore
    let openAgent: (PaiAgent) -> Void
    let openThread: (Int64) -> Void
    @EnvironmentObject private var store: PaiStore

    private enum Row: Identifiable {
        case agent(PaiAgent, depth: Int)
        case thread(PaiAgentThread, depth: Int)

        var id: String {
            switch self {
            case .agent(let agent, _): return "a:\(agent.slug)"
            case .thread(let thread, _): return "t:\(thread.sessionId)"
            }
        }
    }

    /// Depth first from pai; open agents before closed ones, the latest active first; each agent's threads under it.
    private var rows: [Row] {
        let agents = store.agents.filter { !$0.isClosed || $0.isPai }
        let slugs = Set(agents.map(\.slug))
        let children = Dictionary(grouping: agents) { agent -> String in
            guard let parent = agent.parent, slugs.contains(parent) else { return "" }
            return parent
        }
        var result: [Row] = []
        var seen = Set<String>()
        func walk(_ parent: String, depth: Int) {
            let level = (children[parent] ?? []).sorted { a, b in
                if a.isPai != b.isPai { return a.isPai }
                if a.isBusy != b.isBusy { return a.isBusy }
                return (a.lastActive ?? 0) > (b.lastActive ?? 0)
            }
            for agent in level where !seen.contains(agent.slug) {
                seen.insert(agent.slug)
                result.append(.agent(agent, depth: depth))
                for thread in (agent.threads ?? []).sorted(by: { $0.lastActivity > $1.lastActivity }).prefix(agent.isPai ? 8 : 5) {
                    result.append(.thread(thread, depth: depth + 1))
                }
                walk(agent.slug, depth: depth + 1)
            }
        }
        walk("", depth: 0)
        return result
    }

    var body: some View {
        List {
            if !hub.needs.isEmpty {
                Section {
                    ForEach(hub.needs) { need in
                        NeedCard(need: need) { hub.answer(need, $0) }
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Label("Needs you", systemImage: "hand.raised.fill").font(.footnote.weight(.semibold)).foregroundStyle(Color.paiWaiting)
                }
            }
            Section {
                if store.agents.filter({ !$0.isPai && !$0.isClosed }).isEmpty {
                    Text("No agents yet. Ask pai for something bigger than a quick answer and it sets one up.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
                ForEach(rows) { row in
                    switch row {
                    case let .agent(agent, depth):
                        AgentRow(agent: agent, depth: depth, stop: { hub.stop(agent: agent) })
                            .contentShape(Rectangle())
                            .onTapGesture { openAgent(agent) }
                            .swipeActions { if agent.isBusy { Button("Stop", role: .destructive) { hub.stop(agent: agent) } } }
                            .contextMenu {
                                Button { openAgent(agent) } label: { Label("Open chat", systemImage: "bubble.left") }
                                if agent.isBusy { Button(role: .destructive) { hub.stop(agent: agent) } label: { Label("Stop", systemImage: "stop.circle") } }
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                    case let .thread(thread, depth):
                        ThreadRow(thread: thread, depth: depth, stop: { hub.stop(thread: thread) })
                            .contentShape(Rectangle())
                            .onTapGesture { if let id = thread.threadId { openThread(id) } }
                            .swipeActions { if thread.isRunning { Button("Stop", role: .destructive) { hub.stop(thread: thread) } } }
                            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                            .listRowSeparator(.hidden)
                    }
                }
            } header: {
                Text("Agents").font(.footnote.weight(.semibold))
            }
        }
        .listStyle(.plain)
        .refreshable {
            store.refreshAgents()
            await hub.load()
        }
        .animation(.default, value: store.agents)
        .animation(.default, value: hub.needs)
    }
}

/// A question with its answers as buttons — one tap — and a field for anything else.
@available(iOS 16.0, *)
struct NeedCard: View {
    let need: PaiNeed
    let answer: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(need.from).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if need.priority == "urgent" {
                    Text("urgent").font(.caption2.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1).background(Color.red, in: Capsule())
                }
                Spacer()
                Text(Date(timeIntervalSince1970: need.createdAt / 1000).paiAge).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(need.question.paiPlain).font(.callout)
            if !need.options.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(need.options.enumerated()), id: \.offset) { index, option in
                        Button { answer(option) } label: {
                            Text(option).font(.subheadline.weight(.medium)).lineLimit(2)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .foregroundStyle(index == 0 ? Color.white : Color.accentColor)
                                .background(index == 0 ? Color.accentColor : Color.accentColor.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if need.freeText ?? true {
                HStack(spacing: 8) {
                    TextField(need.options.isEmpty ? "Answer" : "Or type an answer", text: $draft)
                        .font(.subheadline)
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                    if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.paiWaiting.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.paiWaiting.opacity(0.35)))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        focused = false
        answer(text)
    }
}

/// Lays children out in rows, wrapping when a row is full: option buttons of any length.
@available(iOS 16.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// One agent: status, name, what it is for; open tasks, spend today; a stop button while it works.
@available(iOS 16.0, *)
private struct AgentRow: View {
    let agent: PaiAgent
    let depth: Int
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if depth > 0 {
                Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.quaternary)
                    .padding(.leading, CGFloat(depth - 1) * 18)
            }
            AgentStatusIcon(status: agent.isBusy ? "working" : agent.status)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(agent.name).font(.callout.weight(depth == 0 ? .semibold : .medium)).lineLimit(1)
                    if agent.kind == "sub" { Text("sub").font(.caption2).foregroundStyle(.tertiary) }
                }
                if !agent.briefLine.isEmpty, !agent.isPai {
                    Text(agent.briefLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let open = agent.openTasks, open > 0 {
                Label("\(open)", systemImage: "checklist").font(.caption).foregroundStyle(.secondary)
            }
            if let cost = agent.costUsd, cost > 0 {
                Text(String(format: "$%.2f", cost)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            if agent.isBusy {
                StopButton(action: stop)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A thread an agent started: where it runs, how long ago it moved; stoppable while it runs.
@available(iOS 16.0, *)
private struct ThreadRow: View {
    let thread: PaiAgentThread
    let depth: Int
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.quaternary)
                .padding(.leading, CGFloat(max(0, depth - 1)) * 18)
            Image(systemName: "text.bubble").font(.caption).foregroundStyle(thread.isRunning ? Color.accentColor : .secondary)
                .frame(width: 20)
                .modifier(BreathingIf(active: thread.isRunning))
            VStack(alignment: .leading, spacing: 1) {
                Text(thread.title.paiPlain).font(.subheadline).lineLimit(1)
                Text([thread.project, Date(timeIntervalSince1970: thread.lastActivity / 1000).paiAge].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if thread.isRunning { StopButton(action: stop) }
        }
    }
}

@available(iOS 16.0, *)
private struct BreathingIf: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.modifier(Breathing()) } else { content }
    }
}

/// The interrupt: red, round, always in the same place on a row.
@available(iOS 16.0, *)
struct StopButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.red.opacity(0.85), in: Circle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Stop")
    }
}

// MARK: Tasks

/// The task list as a board: a column per status, cards dragged between them (or moved from their menu).
@available(iOS 16.0, *)
private struct TaskBoard: View {
    @ObservedObject var hub: PaiHubStore
    let openAgent: (PaiAgent) -> Void
    @EnvironmentObject private var store: PaiStore
    @State private var selected: PaiTaskItem?
    @State private var target: String?

    static let columns: [(status: String, title: String, symbol: String)] = [
        ("inbox", "Inbox", "tray"),
        ("active", "Active", "bolt"),
        ("waiting_user", "Waiting on you", "hand.raised"),
        ("waiting_other", "Waiting on others", "hourglass"),
        ("scheduled", "Scheduled", "calendar"),
        ("done", "Done", "checkmark.circle"),
    ]

    private func items(_ status: String) -> [PaiTaskItem] {
        let week = (Date().timeIntervalSince1970 - 7 * 86_400) * 1000
        return hub.tasks
            .filter { $0.status == status && (status != "done" || $0.updatedAt > week) }
            .sorted { a, b in
                if a.isOverdue != b.isOverdue { return a.isOverdue }
                return a.updatedAt > b.updatedAt
            }
    }

    var body: some View {
        Group {
            if hub.loaded && hub.tasks.filter({ $0.isOpen || $0.status == "done" }).isEmpty {
                ScrollView {
                    ContentUnavailableCompat(symbol: "rectangle.split.3x1", title: "No tasks yet", detail: "pai puts what you hand it here, and its agents keep each one moving.")
                }
            } else {
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Self.columns, id: \.status) { column in
                            columnView(column.status, column.title, column.symbol)
                        }
                    }
                    .padding(16)
                }
                .refreshable { await hub.load() }
            }
        }
        .sheet(item: $selected) { task in
            TaskDetail(task: task, hub: hub, openAgent: { agent in
                selected = nil
                openAgent(agent)
            })
            .presentationDetents([.medium, .large])
        }
    }

    private func columnView(_ status: String, _ title: String, _ symbol: String) -> some View {
        let list = items(status)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption.weight(.semibold))
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(list.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
            }
            .foregroundStyle(status == "waiting_user" && !list.isEmpty ? Color.paiWaiting : Color.primary)
            .padding(.horizontal, 4)
            ForEach(list) { task in
                TaskCard(task: task, owner: store.agent(task.owner))
                    .onTapGesture { selected = task }
                    .draggable(String(task.id)) {
                        TaskCard(task: task, owner: store.agent(task.owner)).frame(width: 240)
                    }
                    .contextMenu {
                        ForEach(Self.columns.filter { $0.status != task.status }, id: \.status) { other in
                            Button { hub.move(task, to: other.status) } label: { Label("Move to \(other.title)", systemImage: other.symbol) }
                        }
                        Button(role: .destructive) { hub.move(task, to: "dropped") } label: { Label("Drop", systemImage: "trash") }
                    }
            }
            if list.isEmpty {
                Text("Drop here").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.quaternary))
            }
        }
        .padding(10)
        .frame(width: 260, alignment: .top)
        .background(Color(.secondarySystemBackground).opacity(target == status ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.accentColor.opacity(target == status ? 0.8 : 0), lineWidth: 2))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids.compactMap(Int.init) {
                if let task = hub.tasks.first(where: { $0.id == id }) { hub.move(task, to: status) }
            }
            return true
        } isTargeted: { over in
            target = over ? status : (target == status ? nil : target)
        }
    }
}

/// One task on the board: its title, who owns it, when it is due, what is next.
@available(iOS 16.0, *)
private struct TaskCard: View {
    let task: PaiTaskItem
    let owner: PaiAgent?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title).font(.subheadline.weight(.medium)).lineLimit(3)
            if let next = task.nextAction, !next.isEmpty, task.isOpen {
                Text(next).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                Label(owner?.name ?? task.owner, systemImage: owner?.isBusy == true ? "bolt.fill" : "person.crop.circle")
                    .font(.caption2.weight(.medium)).foregroundStyle(owner?.isBusy == true ? Color.accentColor : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let due = task.due {
                    Text(due).font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(task.isOverdue ? Color.white : Color.secondary)
                        .background(task.isOverdue ? Color.red.opacity(0.85) : Color(.tertiarySystemFill), in: Capsule())
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            if task.status == "waiting_user" {
                RoundedRectangle(cornerRadius: 2).fill(Color.paiWaiting).frame(width: 3).padding(.vertical, 8)
            }
        }
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .opacity(task.status == "done" ? 0.6 : 1)
    }
}

/// A task opened from the board: everything about it, its status as a picker, its owner one tap away.
@available(iOS 16.0, *)
private struct TaskDetail: View {
    let task: PaiTaskItem
    @ObservedObject var hub: PaiHubStore
    let openAgent: (PaiAgent) -> Void
    @EnvironmentObject private var store: PaiStore
    @Environment(\.dismiss) private var dismiss

    private var current: PaiTaskItem { hub.tasks.first { $0.id == task.id } ?? task }
    private var owner: PaiAgent? { store.agent(current.owner) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(current.title).font(.headline)
                    if let next = current.nextAction, !next.isEmpty { LabeledContent("Next", value: next) }
                    if let due = current.due { LabeledContent("Due", value: due) }
                }
                Section("Status") {
                    Picker("Status", selection: Binding(get: { current.status }, set: { hub.move(current, to: $0) })) {
                        ForEach(TaskBoard.columns, id: \.status) { column in
                            Label(column.title, systemImage: column.symbol).tag(column.status)
                        }
                        Label("Dropped", systemImage: "trash").tag("dropped")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if let owner {
                    Section("Owner") {
                        Button { openAgent(owner) } label: {
                            HStack {
                                AgentStatusIcon(status: owner.isBusy ? "working" : owner.status)
                                Text(owner.name)
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(.primary)
                        if owner.isBusy {
                            Button(role: .destructive) { hub.stop(agent: owner) } label: { Label("Stop \(owner.name)", systemImage: "stop.circle") }
                        }
                    }
                }
                if let notes = current.notes, !notes.isEmpty {
                    Section("Notes") { MarkdownView(text: notes) }
                }
                if let source = current.source, let url = URL(string: source), source.hasPrefix("http") {
                    Section { Link(destination: url) { Label("Open source", systemImage: "arrow.up.right.square") } }
                }
            }
            .navigationTitle("Task #\(current.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: Routines

/// What runs by itself: on a schedule, when something happens, and the reminders (tasks with a date).
@available(iOS 16.0, *)
private struct RoutinesPane: View {
    @ObservedObject var hub: PaiHubStore
    @EnvironmentObject private var store: PaiStore

    private var scheduled: [PaiRoutine] { hub.routines.filter(\.isScheduled) }
    private var onEvents: [PaiRoutine] { hub.routines.filter { !$0.isScheduled } }
    private var reminders: [PaiTaskItem] {
        hub.tasks.filter { $0.isOpen && ($0.due != nil || $0.status == "scheduled") }.sorted { ($0.due ?? "9") < ($1.due ?? "9") }
    }

    var body: some View {
        List {
            if hub.loaded && hub.routines.isEmpty && reminders.isEmpty {
                ContentUnavailableCompat(symbol: "clock.arrow.circlepath", title: "Nothing runs by itself yet", detail: "Ask pai to check something every morning, or whenever a message arrives.")
            }
            if !scheduled.isEmpty {
                Section("On a schedule") {
                    ForEach(scheduled) { routine in
                        RoutineRow(routine: routine, symbol: "clock", trigger: Self.cronText(routine.schedule), agent: store.agent(routine.agent)?.name) { hub.setRoutine(routine, enabled: $0) }
                    }
                }
            }
            if !onEvents.isEmpty {
                Section("When something happens") {
                    ForEach(onEvents) { routine in
                        RoutineRow(routine: routine, symbol: "bolt", trigger: "On \(Self.eventText(routine.event))", agent: store.agent(routine.agent)?.name) { hub.setRoutine(routine, enabled: $0) }
                    }
                }
            }
            if !reminders.isEmpty {
                Section("Reminders") {
                    ForEach(reminders) { task in
                        HStack(spacing: 10) {
                            Image(systemName: "bell").foregroundStyle(task.isOverdue ? Color.red : Color.accentColor).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title).font(.callout).lineLimit(2)
                                Text([task.due, store.agent(task.owner)?.name ?? task.owner].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(task.isOverdue ? Color.red : .secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await hub.load() }
    }

    /// Five-field cron in words for the common shapes; anything else as it is.
    static func cronText(_ cron: String) -> String {
        let f = cron.split(separator: " ").map(String.init)
        guard f.count == 5 else { return cron }
        let (minute, hour, dom, month, dow) = (f[0], f[1], f[2], f[3], f[4])
        if minute.hasPrefix("*/"), hour == "*" { return "Every \(minute.dropFirst(2)) minutes" }
        guard let m = Int(minute) else { return cron }
        if hour == "*" { return String(format: "Every hour at :%02d", m) }
        if hour.hasPrefix("*/") { return "Every \(hour.dropFirst(2)) hours" }
        guard let h = Int(hour) else { return cron }
        let time = String(format: "%02d:%02d", h, m)
        guard dom == "*", month == "*" else { return "\(time), cron \(cron)" }
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        switch dow {
        case "*": return "Every day at \(time)"
        case "1-5": return "Weekdays at \(time)"
        case "0,6", "6,0": return "Weekends at \(time)"
        default:
            if let d = Int(dow), d < days.count { return "Every \(days[d]) at \(time)" }
            return "\(time), days \(dow)"
        }
    }

    static func eventText(_ event: String) -> String {
        switch event {
        case "gmail.new": return "new mail"
        case "linkedin.message": return "a LinkedIn message"
        case "telegram.message": return "a Telegram message"
        case "calendar.upcoming": return "an upcoming event"
        default: return event.replacingOccurrences(of: ".", with: " ")
        }
    }
}

@available(iOS 16.0, *)
private struct RoutineRow: View {
    let routine: PaiRoutine
    let symbol: String
    let trigger: String
    let agent: String?
    let setEnabled: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { routine.enabled }, set: setEnabled)) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(routine.enabled ? Color.accentColor : .secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.name).font(.callout)
                    Text("\(trigger) · \(actionText)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if let runs = routine.runs, runs > 0 {
                        Text("ran \(runs)×\(routine.lastRun.map { ", last \(Date(timeIntervalSince1970: $0 / 1000).paiAge)" } ?? "")")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var actionText: String {
        switch routine.action {
        case "notify": return "tells you"
        case "turn": return "pai takes it up"
        case "wake": return "wakes \(agent ?? routine.agent)"
        case "triage": return "sorted for you"
        case "task": return "starts a task"
        default: return routine.action
        }
    }
}
