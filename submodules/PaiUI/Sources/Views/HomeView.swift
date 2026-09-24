import SwiftUI

/// Every project with its threads, the ones that need you first; search and a new thread in the bar.
@available(iOS 16.0, *)
struct HomeView: View {
    let open: (PaiSession) -> Void
    let newThread: () -> Void
    let close: () -> Void
    @EnvironmentObject private var store: PaiStore
    @State private var expanded: Set<String> = []
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private static let general = "General"
    private static let shown = 3

    private struct Group: Identifiable {
        let id: String
        let symbol: String
        let sessions: [PaiSession]
        var active: Int { sessions.filter { $0.isRunning || $0.isWaiting }.count }
    }

    /// The general workspace first, then every project the daemon knows, each with its threads (attention first).
    private var groups: [Group] {
        let bySlug = Dictionary(grouping: store.sessions) { $0.project ?? Self.general }
        let sorted: ([PaiSession]?) -> [PaiSession] = { sessions in
            (sessions ?? []).sorted { a, b in
                let ra = a.isWaiting ? 0 : a.isRunning ? 1 : 2
                let rb = b.isWaiting ? 0 : b.isRunning ? 1 : 2
                return ra != rb ? ra < rb : a.lastActivity > b.lastActivity
            }
        }
        let known = Set(store.projects.map(\.slug))
        let orphans = bySlug.keys.filter { $0 != Self.general && !known.contains($0) }.sorted()
        let all = [Group(id: Self.general, symbol: PaiProjectIcon.general, sessions: sorted(bySlug[Self.general]))]
            + store.projects.map { Group(id: $0.slug, symbol: PaiProjectIcon.symbol($0), sessions: sorted(bySlug[$0.slug])) }
            + orphans.map { Group(id: $0, symbol: "folder", sessions: sorted(bySlug[$0])) }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.compactMap { group in
            if group.id.lowercased().contains(q) { return group }
            let matching = group.sessions.filter { $0.displayTitle.lowercased().contains(q) }
            return matching.isEmpty ? nil : Group(id: group.id, symbol: group.symbol, sessions: matching)
        }
    }

    var body: some View {
        NavigationStack {
            list
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: searching ? stopSearch : close) { Image(systemName: "chevron.left") }
                    }
                    ToolbarItem(placement: .principal) { titleOrSearch }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 14) {
                            if !searching {
                                Button(action: startSearch) { Image(systemName: "magnifyingglass") }
                            }
                            Button(action: newThread) { Image(systemName: "square.and.pencil") }
                            if let error = store.connectionError { Image(systemName: "bolt.slash").foregroundStyle(.red).help(error) }
                        }
                    }
                }
        }
        .onAppear(perform: store.start)
    }

    /// The title, or the search field grown into its place.
    @ViewBuilder private var titleOrSearch: some View {
        if searching {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Project or thread", text: $query)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .frame(minWidth: 240)
            .transition(.scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
        } else {
            Text("Projects").font(.headline).transition(.opacity)
        }
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
            if let error = store.connectionError, store.sessions.isEmpty, store.projects.isEmpty {
                ContentUnavailableCompat(symbol: "bolt.slash", title: "Not connected", detail: error)
            } else if store.isLoading {
                ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
            }
            ForEach(groups) { group in
                Section {
                    let visible = visibleSessions(group)
                    ForEach(visible) { session in
                        ThreadRow(session: session)
                            .contentShape(Rectangle())
                            .onTapGesture { open(session) }
                    }
                    let hidden = group.sessions.count - visible.count
                    if hidden > 0 {
                        Button { expanded.insert(group.id) } label: {
                            Text("\(hidden) more").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: group.symbol).font(.caption)
                        Text(group.id).font(.caption.weight(.semibold)).textCase(.uppercase).tracking(0.6)
                        if group.active > 0 { Text("\(group.active) active").font(.caption).foregroundStyle(Color.accentColor) }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, group.sessions.isEmpty ? 0 : 6)
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacingCompat()
        .refreshable { store.refresh() }
        .animation(.default, value: store.sessions)
    }

    /// Everything running or waiting, then the latest few unless the group is opened up.
    private func visibleSessions(_ group: Group) -> [PaiSession] {
        if expanded.contains(group.id) || !query.isEmpty { return group.sessions }
        let active = group.sessions.filter { $0.isRunning || $0.isWaiting }
        let rest = group.sessions.filter { !($0.isRunning || $0.isWaiting) }
        return active + rest.prefix(max(0, Self.shown - active.count))
    }
}

@available(iOS 16.0, *)
private extension View {
    /// Tight section spacing on the systems that have the knob; the older list gets its default.
    @ViewBuilder func listSectionSpacingCompat() -> some View {
        if #available(iOS 17.0, *) { self.listSectionSpacing(.compact) } else { self }
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
