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
public final class PaiProjectPickerController: ViewController {
    /// Called once a choice is made; the presenter takes the screen away.
    public var picked: (() -> Void)?
    private var hosting: UIViewController!
    private var presentationData: PresentationData

    public init(context: AccountContext) {
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: nil)
        self.navigationPresentation = .modal
        self.hosting = UIHostingController(rootView: ProjectPickerView(store: PaiHost.store, pick: { [weak self] project in
            PaiChat.pendingProject = project
            self?.picked?()
        }, close: { [weak self] in self?.dismiss() }))
        self.hosting.overrideUserInterfaceStyle = self.presentationData.theme.overallDarkAppearance ? .dark : .light
        self.hosting.view.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.presentationData.theme.list.plainBackgroundColor
        self.addChild(self.hosting)
        self.displayNode.view.addSubview(self.hosting.view)
        self.hosting.didMove(toParent: self)
        self.displayNodeDidLoad()
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = layout.insets(options: [.statusBar]).top
        let bottom = max(layout.intrinsicInsets.bottom, layout.inputHeight ?? 0.0)
        transition.updateFrame(view: self.hosting.view, frame: CGRect(x: 0, y: top, width: layout.size.width, height: max(0, layout.size.height - top)))
        self.hosting.additionalSafeAreaInsets = UIEdgeInsets(top: 0.0, left: 0.0, bottom: bottom, right: 0.0)
    }
}

@available(iOS 16.0, *)
struct ProjectPickerView: View {
    @ObservedObject var store: PaiStore
    let pick: (PaiProject?) -> Void
    let close: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private var matches: [PaiProject] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.projects.filter { q.isEmpty || $0.slug.lowercased().contains(q) || ($0.summary ?? "").lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    row(symbol: PaiProjectIcon.general, title: "General", detail: "The assistant's own workspace", selected: PaiChat.pendingProject == nil) { pick(nil) }
                }
                ForEach(matches) { project in
                    row(symbol: PaiProjectIcon.symbol(project), title: project.slug, detail: project.summary, selected: PaiChat.pendingProject?.slug == project.slug) { pick(project) }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(action: close) { Image(systemName: "chevron.left") } }
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
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color(.systemBackground))
            }
        }
        .onAppear {
            store.start()
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
