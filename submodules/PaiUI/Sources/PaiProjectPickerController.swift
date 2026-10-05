import AccountContext
import AsyncDisplayKit
import Display
import Foundation
import SwiftUI
import TelegramPresentationData
import UIKit

/// The symbol a project shows next to its name.
public enum PaiProjectIcon {
    public static let general = "bubble.left.and.text.bubble.right"

    public static func symbol(_ project: PaiProject) -> String {
        project.kind == "repo" ? "chevron.left.forwardslash.chevron.right" : "folder"
    }
}

/// Pick the project a new thread starts in, or none for the general workspace.
@available(iOS 16.0, *)
public final class PaiProjectPickerController: PaiHostedController {
    /// Called once a choice is made; the presenter takes the screen away.
    public var picked: (() -> Void)?

    public override init(context: AccountContext) {
        super.init(context: context)
        self.host(ProjectPickerView(store: PaiHost.store, pick: { [weak self] project in
            PaiChat.pendingProject = project
            self?.picked?()
        }, close: { [weak self] in self?.dismiss() }))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@available(iOS 16.0, *)
struct ProjectPickerView: View {
    @ObservedObject var store: PaiStore
    let pick: (PaiProject?) -> Void
    let close: () -> Void
    @State private var query = ""
    @State private var pinned = PaiChat.pinnedProjects
    @FocusState private var focused: Bool
    @EnvironmentObject private var insets: PaiInsets

    /// Pinned projects first (in the order they were pinned), then the rest as the daemon listed them.
    private var matches: [PaiProject] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = store.projects.filter { q.isEmpty || $0.slug.lowercased().contains(q) || ($0.summary ?? "").lowercased().contains(q) }
        return filtered.enumerated().sorted { a, b in
            let pa = pinned.firstIndex(of: a.element.slug), pb = pinned.firstIndex(of: b.element.slug)
            if let pa, let pb { return pa < pb }
            if pa != nil || pb != nil { return pa != nil }
            return a.offset < b.offset
        }.map(\.element)
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = store.connectionError, store.projects.isEmpty {
                    ContentUnavailableCompat(symbol: "bolt.slash", title: "Not connected", detail: error)
                } else {
                    if query.isEmpty {
                        row(symbol: PaiProjectIcon.general, title: "General", detail: "The assistant's own workspace", selected: PaiChat.pendingProject == nil) { pick(nil) }
                    }
                    if store.isLoading && store.projects.isEmpty {
                        ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
                    } else if matches.isEmpty && !query.isEmpty {
                        ContentUnavailableCompat(symbol: "magnifyingglass", title: "No matches", detail: "No project matches \u{201c}\(query)\u{201d}.")
                    }
                    ForEach(matches) { project in
                        row(symbol: PaiProjectIcon.symbol(project), title: project.slug, detail: project.summary, selected: PaiChat.pendingProject?.slug == project.slug) { pick(project) }
                            .contextMenu {
                                Button {
                                    pinned = pinned.contains(project.slug) ? pinned.filter { $0 != project.slug } : pinned + [project.slug]
                                    PaiChat.pinnedProjects = pinned
                                } label: {
                                    Label(pinned.contains(project.slug) ? "Unpin" : "Pin", systemImage: pinned.contains(project.slug) ? "pin.slash" : "pin")
                                }
                            }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(action: close) { Image(systemName: "chevron.left") } }
                ToolbarItem(placement: .topBarTrailing) {
                    if let error = store.connectionError, !store.projects.isEmpty { Image(systemName: "bolt.slash").foregroundStyle(.red).help(error) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Project name", text: $query)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8 + insets.bottom)
                .background(Color(.systemBackground))
            }
        }
        .onAppear {
            store.start()
            store.refresh()
            focused = true
        }
    }

    private func row(symbol: String, title: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.body).foregroundStyle(Color.accentColor).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(.primary)
                    if let detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
    }
}
