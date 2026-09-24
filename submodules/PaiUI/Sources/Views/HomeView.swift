import SwiftUI

/// Every project with its threads, the ones that need you first, and a way to start another.
@available(iOS 16.0, *)
struct HomeView: View {
    let open: (PaiSession) -> Void
    let newThread: () -> Void
    let close: () -> Void
    @EnvironmentObject private var store: PaiStore
    @State private var expanded: Set<String> = []

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
        return [Group(id: Self.general, symbol: PaiProjectIcon.general, sessions: sorted(bySlug[Self.general]))]
            + store.projects.map { Group(id: $0.slug, symbol: PaiProjectIcon.symbol($0), sessions: sorted(bySlug[$0.slug])) }
            + orphans.map { Group(id: $0, symbol: "folder", sessions: sorted(bySlug[$0])) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                list
                Button(action: newThread) {
                    Label("New thread", systemImage: "plus")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color(.systemBackground))
            }
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(action: close) { Image(systemName: "chevron.left") } }
                ToolbarItem(placement: .topBarTrailing) {
                    if let error = store.connectionError { Image(systemName: "bolt.slash").foregroundStyle(.red).help(error) }
                }
            }
        }
        .onAppear(perform: store.start)
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
                }
            }
        }
        .listStyle(.plain)
        .refreshable { store.refresh() }
        .animation(.default, value: store.sessions)
    }

    /// Everything running or waiting, then the latest few unless the group is opened up.
    private func visibleSessions(_ group: Group) -> [PaiSession] {
        if expanded.contains(group.id) { return group.sessions }
        let active = group.sessions.filter { $0.isRunning || $0.isWaiting }
        let rest = group.sessions.filter { !($0.isRunning || $0.isWaiting) }
        return active + rest.prefix(max(0, Self.shown - active.count))
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
