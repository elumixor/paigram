import SwiftUI

/// Every project with its threads, the ones that need you first; search and a new thread at the bottom.
@available(iOS 16.0, *)
struct HomeView: View {
    let open: (PaiSession) -> Void
    let newThread: (PaiProject?) -> Void
    let close: () -> Void
    @EnvironmentObject private var store: PaiStore
    @EnvironmentObject private var insets: PaiInsets
    @State private var expanded: Set<String> = []
    @State private var searching = false
    @State private var query = ""
    @State private var pinned = PaiChat.pinnedProjects
    @FocusState private var searchFocused: Bool

    private static let general = "General"
    private static let shown = 3

    private struct Group: Identifiable {
        let id: String
        let symbol: String
        let project: PaiProject?
        let sessions: [PaiSession]
        var active: Int { sessions.filter { $0.isRunning || $0.isWaiting }.count }
        var lastActivity: Double { sessions.map(\.lastActivity).max() ?? 0 }
    }

    /// Pinned projects first, then the rest by their latest thread; within a group the ones needing attention first.
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
        let all = [Group(id: Self.general, symbol: PaiProjectIcon.general, project: nil, sessions: sorted(bySlug[Self.general]))]
            + store.projects.map { Group(id: $0.slug, symbol: PaiProjectIcon.symbol($0), project: $0, sessions: sorted(bySlug[$0.slug])) }
            + orphans.map { Group(id: $0, symbol: "folder", project: nil, sessions: sorted(bySlug[$0])) }
        let ordered = all.sorted { a, b in
            let pa = pinned.firstIndex(of: a.id), pb = pinned.firstIndex(of: b.id)
            if let pa, let pb { return pa < pb }
            if pa != nil || pb != nil { return pa != nil }
            return a.lastActivity > b.lastActivity
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return ordered }
        return ordered.compactMap { group in
            if group.id.lowercased().contains(q) { return group }
            let matching = group.sessions.filter { $0.displayTitle.lowercased().contains(q) }
            return matching.isEmpty ? nil : Group(id: group.id, symbol: group.symbol, project: group.project, sessions: matching)
        }
    }

    var body: some View {
        NavigationStack {
            list
                .navigationTitle("Projects")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(action: close) { Image(systemName: "chevron.left") } }
                    ToolbarItem(placement: .topBarTrailing) {
                        if let error = store.connectionError { Image(systemName: "bolt.slash").foregroundStyle(.red).help(error) }
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
                    TextField("Project or thread", text: $query)
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

    private func togglePin(_ id: String) {
        pinned = pinned.contains(id) ? pinned.filter { $0 != id } : pinned + [id]
        PaiChat.pinnedProjects = pinned
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
                            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                            .listRowSeparator(.hidden)
                    }
                    let hidden = group.sessions.count - visible.count
                    if hidden > 0 {
                        Button { expanded.insert(group.id) } label: {
                            Text("\(hidden) more").font(.footnote).foregroundStyle(.secondary)
                        }
                        .listRowInsets(EdgeInsets(top: 1, leading: 42, bottom: 3, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    header(group)
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacingCompat()
        .environment(\.defaultMinListHeaderHeight, 0)
        .environment(\.defaultMinListRowHeight, 30)
        .refreshable { store.refresh() }
        .animation(.default, value: store.sessions)
    }

    /// The project's name with a pin when pinned, and a way to start a thread right in it.
    private func header(_ group: Group) -> some View {
        HStack(spacing: 6) {
            Image(systemName: group.symbol).font(.caption)
            Text(group.id).font(.caption.weight(.semibold)).textCase(.uppercase).tracking(0.6)
            if pinned.contains(group.id) { Image(systemName: "pin.fill").font(.caption2) }
            if group.active > 0 { Text("\(group.active) active").font(.caption).foregroundStyle(Color.accentColor) }
            Spacer()
            Button { newThread(group.project) } label: {
                Image(systemName: "plus").font(.caption.weight(.semibold)).frame(width: 24, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .opacity(group.id == Self.general || group.project != nil ? 1 : 0)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 14).padding(.bottom, 2)
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
        .contextMenu {
            Button { togglePin(group.id) } label: {
                Label(pinned.contains(group.id) ? "Unpin" : "Pin", systemImage: pinned.contains(group.id) ? "pin.slash" : "pin")
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
    }

    /// Everything running or waiting, then the latest few unless the group is opened up.
    private func visibleSessions(_ group: Group) -> [PaiSession] {
        if expanded.contains(group.id) || !query.isEmpty { return group.sessions }
        let active = group.sessions.filter { $0.isRunning || $0.isWaiting }
        let rest = group.sessions.filter { !($0.isRunning || $0.isWaiting) }
        return active + rest.prefix(max(0, Self.shown - active.count))
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
private extension View {
    /// Tight section spacing on the systems that have the knob; the older list gets its default.
    @ViewBuilder func listSectionSpacingCompat() -> some View {
        if #available(iOS 17.0, *) { self.listSectionSpacing(0) } else { self }
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
