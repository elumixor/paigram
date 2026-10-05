import SwiftUI

/// Every thread and agent, flattened and sorted by recency; what is busy or waiting for you reads that
/// way at a glance, not just as a plain row. Search and a new thread sit at the bottom.
@available(iOS 16.0, *)
struct HomeView: View {
    let open: (PaiSession) -> Void
    let openAgent: (PaiAgent) -> Void
    let newThread: (PaiProject?) -> Void
    let openTree: () -> Void
    let close: () -> Void
    @EnvironmentObject private var store: PaiStore
    @EnvironmentObject private var insets: PaiInsets
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// A thread or an agent, the two things this screen lets you jump into.
    fileprivate enum Item: Identifiable {
        case thread(PaiSession)
        case agent(PaiAgent)

        var id: String {
            switch self {
            case .thread(let session): return "t:\(session.sessionId)"
            case .agent(let agent): return "a:\(agent.slug)"
            }
        }
        var title: String {
            switch self {
            case .thread(let session): return session.displayTitle.paiPlain
            case .agent(let agent): return agent.name
            }
        }
        /// The project a thread is in, or where an agent sits in the tree.
        var detail: String? {
            switch self {
            case .thread(let session): return session.project
            case .agent(let agent): return agent.breadcrumb
            }
        }
        var lastActivity: Double {
            switch self {
            case .thread(let session): return session.lastActivity
            case .agent(let agent): return agent.lastActive ?? 0
            }
        }
        var isBusy: Bool {
            switch self {
            case .thread(let session): return session.isRunning
            case .agent(let agent): return agent.status == "working" || agent.status == "queued"
            }
        }
        var isWaiting: Bool {
            switch self {
            case .thread(let session): return session.isWaiting
            case .agent(let agent): return agent.status == "waiting"
            }
        }
    }

    /// Every thread and agent (pai itself excluded — this screen is reached from pai's own chat),
    /// newest activity first; search narrows by title or project/breadcrumb.
    private var items: [Item] {
        let all = store.sessions.map(Item.thread) + store.agents.filter { !$0.isPai }.map(Item.agent)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) || ($0.detail ?? "").lowercased().contains(q) }
        return filtered.sorted { $0.lastActivity > $1.lastActivity }
    }

    var body: some View {
        NavigationStack {
            list
                .navigationTitle("Projects")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(action: close) { Image(systemName: "chevron.left") } }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack {
                            if let error = store.connectionError { Image(systemName: "bolt.slash").foregroundStyle(.red).help(error) }
                            Button(action: openTree) { Image(systemName: "point.3.connected.trianglepath.dotted") }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) { bottomBar }
        }
        .onAppear(perform: store.start)
    }

    /// Search grows out of its button; the new-thread button stays on the right.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            if searching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Thread, agent, or project", text: $query)
                        .focused($searchFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    Button(action: stopSearch) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .transition(.scale(scale: 0.2, anchor: .leading).combined(with: .opacity))
            } else {
                BarButton(symbol: "magnifyingglass", action: startSearch)
                Spacer()
            }
            BarButton(symbol: "square.and.pencil", filled: true) { newThread(nil) }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8 + insets.bottom)
        .background(Color(.systemBackground))
    }

    private func startSearch() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { searching = true }
        searchFocused = true
    }

    private func stopSearch() {
        query = ""
        searchFocused = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { searching = false }
    }

    private var list: some View {
        List {
            if let error = store.connectionError, store.sessions.isEmpty, store.agents.isEmpty {
                ContentUnavailableCompat(symbol: "bolt.slash", title: "Not connected", detail: error)
            } else if store.isLoading, items.isEmpty {
                ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
            } else if items.isEmpty, !query.isEmpty {
                ContentUnavailableCompat(symbol: "magnifyingglass", title: "No matches", detail: "No thread, agent, or project matches \u{201c}\(query)\u{201d}.")
            }
            ForEach(items) { item in
                HomeRow(item: item)
                    .contentShape(Rectangle())
                    .onTapGesture { select(item) }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable { store.refresh() }
        .animation(.default, value: store.sessions)
    }

    private func select(_ item: Item) {
        switch item {
        case .thread(let session): open(session)
        case .agent(let agent): openAgent(agent)
        }
    }
}

/// One thread or agent: its state at a glance, its name, where it is, how long ago it moved.
@available(iOS 16.0, *)
private struct HomeRow: View {
    fileprivate let item: HomeView.Item

    private var tint: Color {
        item.isWaiting ? .paiWaiting : item.isBusy ? .accentColor : .clear
    }

    var body: some View {
        HStack(spacing: 10) {
            StateDot(waiting: item.isWaiting, busy: item.isBusy)
            Image(systemName: symbol).font(.footnote).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout).fontWeight(item.isBusy || item.isWaiting ? .semibold : .regular).lineLimit(1)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.isWaiting {
                Image(systemName: "questionmark.bubble").font(.footnote).foregroundStyle(Color.paiWaiting)
            }
            Text(Date(timeIntervalSince1970: item.lastActivity / 1000).paiAge).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var symbol: String {
        switch item {
        case .thread: return "bubble.left.and.text.bubble.right"
        case .agent: return "person.crop.circle"
        }
    }
}

/// One round bar button, filled when it is the main action.
@available(iOS 16.0, *)
struct BarButton: View {
    let symbol: String
    var filled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(filled ? Color.white : Color.accentColor)
                .frame(width: 40, height: 40)
                .background(filled ? Color.accentColor : Color(.secondarySystemBackground), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

@available(iOS 16.0, *)
struct ContentUnavailableCompat: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
        .listRowSeparator(.hidden)
    }
}

@available(iOS 16.0, *)
struct SkeletonRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill)).frame(width: 180, height: 14)
            RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill)).frame(width: 260, height: 11)
        }
        .padding(.vertical, 6)
        .modifier(Breathing())
        .listRowSeparator(.hidden)
    }
}
