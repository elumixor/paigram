import SwiftUI

/// Every thread at a glance, the composer always in reach.
@available(iOS 16.0, *)
struct HomeView: View {
    @EnvironmentObject private var store: PaiStore
    @EnvironmentObject private var settings: PaiSettings
    @State private var projectFilter: String?
    @State private var composeProject: String?
    @State private var path: [String] = []
    @State private var showSettings = false
    @State private var sendError: String?

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                list
                if let sendError {
                    Text(sendError).font(.footnote).foregroundStyle(.red).padding(.horizontal, 16).padding(.bottom, 4)
                }
                projectPicker
                Composer(placeholder: "New thread", isBusy: false, onSend: newThread, onStop: nil)
            }
            .navigationTitle("Pai")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let error = store.connectionError {
                        Image(systemName: "bolt.slash").foregroundStyle(.red).help(error)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .navigationDestination(for: String.self) { id in
                ThreadView(sessionId: id)
            }
            .sheet(isPresented: $showSettings, onDismiss: store.start) { SettingsView() }
        }
        .onAppear {
            store.start()
            if !settings.isConfigured { showSettings = true }
        }
    }

    // MARK: List

    private var visible: [PaiSession] {
        store.sessions.filter { projectFilter == nil || $0.project == projectFilter }
    }

    private var list: some View {
        List {
            if let error = store.connectionError, store.sessions.isEmpty {
                ContentUnavailableCompat(symbol: "bolt.slash", title: "Not connected", detail: error)
            } else if store.isLoading {
                ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
            } else if visible.isEmpty {
                ContentUnavailableCompat(symbol: "text.bubble", title: "No threads yet", detail: "Type or speak below to start one.")
            }
            section("Running", visible.filter { $0.isRunning && !$0.isWaiting })
            section("Needs you", visible.filter { $0.isWaiting })
            section("Recent", visible.filter { !$0.isRunning && !$0.isWaiting })
        }
        .listStyle(.plain)
        .refreshable { store.refresh() }
        .safeAreaInset(edge: .top) { filterBar }
        .animation(.default, value: store.sessions)
    }

    @ViewBuilder private func section(_ title: String, _ sessions: [PaiSession]) -> some View {
        if !sessions.isEmpty {
            Section {
                ForEach(sessions) { session in
                    ThreadRow(session: session)
                        .contentShape(Rectangle())
                        .onTapGesture { path.append(session.sessionId) }
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }
            } header: {
                HStack(spacing: 6) {
                    Text(title).font(.caption.weight(.semibold)).textCase(.uppercase).tracking(0.6)
                    Text("\(sessions.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Only projects that have threads are worth filtering by.
    private var usedProjects: [String] {
        Array(Set(store.sessions.compactMap { $0.project })).sorted()
    }

    @ViewBuilder private var filterBar: some View {
        if !usedProjects.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(title: "All", selected: projectFilter == nil) { projectFilter = nil }
                    ForEach(usedProjects, id: \.self) { slug in
                        FilterChip(title: slug, selected: projectFilter == slug) {
                            projectFilter = projectFilter == slug ? nil : slug
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .background(.bar)
        }
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
        .background(.bar)
        .onChange(of: projectFilter) { composeProject = $0 }
    }

    private func newThread(_ text: String) {
        sendError = nil
        Task {
            do {
                let created = try await store.newThread(text: text, project: composeProject)
                path.append(created.sessionId)
            } catch {
                sendError = error.localizedDescription
            }
        }
    }
}

@available(iOS 16.0, *)
struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
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
