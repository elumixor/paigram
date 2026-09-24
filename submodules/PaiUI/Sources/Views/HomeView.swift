import SwiftUI

/// Every thread at a glance, the composer always in reach.
@available(iOS 16.0, *)
struct HomeView: View {
    let open: (PaiSession) -> Void
    @EnvironmentObject private var store: PaiStore
    @State private var composeProject: String?
    @State private var sendError: String?

    var body: some View {
        Group {
            VStack(spacing: 0) {
                list
                if let sendError {
                    Text(sendError).font(.footnote).foregroundStyle(.red).padding(.horizontal, 16).padding(.bottom, 4)
                }
                projectPicker
                Composer(placeholder: "New thread", isBusy: false, onSend: newThread, onStop: nil)
            }
        }
        .onAppear(perform: store.start)
    }

    // MARK: List

    private static let workspace = "Workspace"

    /// Threads by project, the workspace first, then the projects alphabetically; within a group the ones needing attention first.
    private var groups: [(project: String, sessions: [PaiSession])] {
        let byProject = Dictionary(grouping: store.sessions) { $0.project ?? Self.workspace }
        return byProject.keys.sorted { a, b in
            if a == Self.workspace { return true }
            if b == Self.workspace { return false }
            return a < b
        }.map { (project: $0, sessions: byProject[$0] ?? []) }
    }

    private var list: some View {
        List {
            if let error = store.connectionError, store.sessions.isEmpty {
                ContentUnavailableCompat(symbol: "bolt.slash", title: "Not connected", detail: error)
            } else if store.isLoading {
                ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
            } else if store.sessions.isEmpty {
                ContentUnavailableCompat(symbol: "text.bubble", title: "No threads yet", detail: "Type or speak below to start one.")
            }
            ForEach(groups, id: \.project) { group in
                Section {
                    ForEach(group.sessions) { session in
                        ThreadRow(session: session)
                            .contentShape(Rectangle())
                            .onTapGesture { open(session) }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(group.project).font(.caption.weight(.semibold)).textCase(.uppercase).tracking(0.6)
                        let active = group.sessions.filter { $0.isRunning || $0.isWaiting }.count
                        if active > 0 { Text("\(active) active").font(.caption).foregroundStyle(Color.accentColor) }
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { store.refresh() }
        .animation(.default, value: store.sessions)
    }

    // MARK: Compose

    private var projectPicker: some View {
        HStack {
            Menu {
                Button("Workspace") { composeProject = nil }
                ForEach(store.projects) { project in
                    Button(project.slug) { composeProject = project.slug }
                }
            } label: {
                Label(composeProject ?? "Workspace", systemImage: "folder")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 6)
        .background(Color(.systemBackground))
    }

    private func newThread(_ text: String) {
        sendError = nil
        Task {
            do {
                open(try await store.newThread(text: text, project: composeProject))
            } catch {
                sendError = error.localizedDescription
            }
        }
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
