import AccountContext
import AsyncDisplayKit
import Display
import Foundation
import SwiftUI
import TelegramPresentationData
import UIKit

/// The pai bot's profile: what runs, what it costs, and what its sessions are given
/// (tools, skills, instructions, memories). Opened from the avatar in the chat's bar.
@available(iOS 16.0, *)
public final class PaiSettingsController: PaiHostedController {
    /// Set by the chat: opens the Pai screen (threads by project) on top of this one.
    public var openProjects: (() -> Void)?

    public override init(context: AccountContext) {
        super.init(context: context)
        self.host(SettingsView(store: PaiHost.store, settings: PaiSettingsStore(), openProjects: { [weak self] in self?.openProjects?() }, close: { [weak self] in self?.dismiss() }))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The daemon's context, usage and health, loaded together when the screen opens.
@available(iOS 16.0, *)
final class PaiSettingsStore: ObservableObject {
    @Published private(set) var context: PaiContext?
    @Published private(set) var usage: PaiUsage?
    @Published private(set) var health: PaiHealth?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    private let client = PaiClient()

    func items(_ kind: String) -> [PaiContextItem] { (context?.items ?? []).filter { $0.kind == kind } }
    func item(_ id: String) -> PaiContextItem? { context?.items.first { $0.id == id } }

    @MainActor func save(_ item: PaiContextItem, text: String) async throws {
        let saved = try await client.saveContext(name: item.name, text: text)
        guard var context else { return }
        context = PaiContext(items: context.items.map { $0.id == saved.id ? saved : $0 }, sessions: context.sessions)
        self.context = context
    }

    @MainActor func load() async {
        isLoading = context == nil
        defer { isLoading = false }
        async let context = client.context()
        async let usage = client.usage()
        async let health = client.health()
        do {
            self.health = try await health
            self.context = try await context
            self.usage = try await usage
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Which section a context kind gets: symbol, colour, title.
@available(iOS 16.0, *)
private struct ContextKind {
    let kind: String
    let title: String
    let symbol: String
    let color: Color

    static let all = [
        ContextKind(kind: "tool", title: "Tools", symbol: "wrench.and.screwdriver.fill", color: .blue),
        ContextKind(kind: "skill", title: "Skills", symbol: "sparkles", color: .purple),
        ContextKind(kind: "instruction", title: "Instructions", symbol: "text.alignleft", color: .orange),
        ContextKind(kind: "memory", title: "Memories", symbol: "brain.head.profile", color: .pink),
    ]
}

@available(iOS 16.0, *)
struct SettingsView: View {
    @ObservedObject var store: PaiStore
    @ObservedObject var settings: PaiSettingsStore
    let openProjects: () -> Void
    let close: () -> Void

    var body: some View {
        NavigationStack {
            List {
                header
                statusSection
                usageSection
                contextSection
            }
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(action: close) { Image(systemName: "chevron.left") } }
                ToolbarItem(placement: .topBarTrailing) {
                    if let error = settings.error ?? store.connectionError { Image(systemName: "bolt.slash").foregroundStyle(.red).help(error) }
                }
            }
            .navigationDestination(for: ContextKindRoute.self) { route in
                ContextListView(kind: route.kind, title: route.title, settings: settings)
            }
            .navigationDestination(for: ContextItemRoute.self) { route in
                ContextDetailView(id: route.id, settings: settings)
            }
            .refreshable { await settings.load() }
        }
        .task {
            store.start()
            await settings.load()
        }
    }

    private var header: some View {
        Section {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "sparkle").font(.system(size: 40, weight: .medium)).foregroundStyle(.white)
                }
                .frame(width: 96, height: 96)
                Text("pai").font(.title2.weight(.semibold))
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
        }
    }

    private var subtitle: String {
        guard let health = settings.health else { return settings.error ?? (settings.isLoading ? "connecting…" : PaiSecrets.baseURL) }
        return "\(health.version) · \(health.host.hostname)"
    }

    private var statusSection: some View {
        Section {
            Button(action: openProjects) {
                HStack {
                    SettingsRow(symbol: "circle.grid.2x2.fill", color: .green, title: "Projects", value: threadsValue)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
            if let health = settings.health {
                SettingsRow(symbol: "clock.fill", color: .gray, title: "Uptime", value: Self.duration(health.uptime))
            }
        } header: {
            Text("Status")
        }
    }

    private var threadsValue: String {
        let running = store.running.count, waiting = store.waiting.count
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return parts.isEmpty ? "idle" : parts.joined(separator: " · ")
    }

    @ViewBuilder private var usageSection: some View {
        if let usage = settings.usage {
            Section {
                ForEach(usage.windows) { window in
                    UsageRow(window: window)
                }
                if let cost = usage.costUsd {
                    SettingsRow(symbol: "dollarsign.circle.fill", color: .mint, title: "Sessions cost", value: String(format: "$%.2f", cost))
                }
            } header: {
                Text("Usage")
            } footer: {
                if let error = usage.error { Text(error) } else if let via = usage.via { Text("Limits read through \(via).") }
            }
        }
    }

    private var contextSection: some View {
        Section {
            ForEach(ContextKind.all, id: \.kind) { kind in
                NavigationLink(value: ContextKindRoute(kind: kind.kind, title: kind.title)) {
                    SettingsRow(symbol: kind.symbol, color: kind.color, title: kind.title, value: countValue(kind.kind))
                }
            }
        } header: {
            Text("What the sessions are given")
        } footer: {
            Text("Tools are what a running session reported at its start. Instructions are the system prompt in its parts: the general one, then one per module.")
        }
    }

    private func countValue(_ kind: String) -> String {
        let items = settings.items(kind)
        if kind == "tool" { return "\(items.reduce(0) { $0 + $1.lines.count })" }
        return items.isEmpty ? (settings.isLoading ? "…" : "0") : "\(items.count)"
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }
}

@available(iOS 16.0, *)
private struct ContextKindRoute: Hashable {
    let kind: String
    let title: String
}

/// A row in Telegram's settings style: a coloured square icon, a title, a value on the right.
@available(iOS 16.0, *)
struct SettingsRow: View {
    let symbol: String
    let color: Color
    let title: String
    var value: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
            Spacer()
            if let value { Text(value).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

/// One limit window: a ring for how much of it is used (like the menu bar app's quota rings), the name,
/// and when it resets.
@available(iOS 16.0, *)
private struct UsageRow: View {
    let window: PaiUsageWindow

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private var resetDate: Date? {
        guard let raw = window.resetsAt else { return nil }
        return Self.iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private var resets: String? {
        guard let date = resetDate, date.timeIntervalSinceNow > 0 else { return nil }
        return "resets in \(SettingsView.duration(date.timeIntervalSinceNow))"
    }

    /// How much of the window's own length is still left before it resets, for the ring's outer arc.
    private var timeRemainingFraction: Double? {
        guard let date = resetDate, window.length > 0 else { return nil }
        return min(max(date.timeIntervalSinceNow / window.length, 0), 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            UsageRing(percent: window.percent, timeRemainingFraction: timeRemainingFraction)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.name)
                if let resets { Text(resets).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

/// Two concentric arcs, the way the menu bar app draws a quota: the thin outer one counts down the
/// window's own time left, the thicker inner one is how much of it has been used.
@available(iOS 16.0, *)
private struct UsageRing: View {
    let percent: Double
    let timeRemainingFraction: Double?

    private var usedFraction: Double { min(max(percent, 0), 100) / 100 }
    private var color: Color { percent >= 90 ? .red : percent >= 70 ? .paiWaiting : .accentColor }

    var body: some View {
        ZStack {
            if let timeRemainingFraction {
                Circle().stroke(Color(.tertiarySystemFill), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: timeRemainingFraction)
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 5).padding(5)
            Circle()
                .trim(from: 0, to: usedFraction)
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(5)
            Text("\(Int(percent))%").font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary)
        }
        .frame(width: 40, height: 40)
    }
}

/// Everything of one kind: tools expanding in place with what each does, the rest opening on their text.
@available(iOS 16.0, *)
private struct ContextListView: View {
    let kind: String
    let title: String
    @ObservedObject var settings: PaiSettingsStore
    @State private var expanded: Set<String> = []

    private var items: [PaiContextItem] { settings.items(kind) }

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableCompat(symbol: "tray", title: "Nothing here", detail: kind == "tool" ? "No session has started yet; tools are known once one has." : "")
            }
            ForEach(items) { item in
                if kind == "tool" {
                    toolServer(item)
                } else {
                    NavigationLink(value: ContextItemRoute(id: item.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.body)
                            if !item.description.isEmpty { Text(item.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            Text(surfaces(item)).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func surfaces(_ item: PaiContextItem) -> String {
        item.surfaces.isEmpty ? "not loaded anywhere" : item.surfaces.joined(separator: ", ")
    }

    private func toolServer(_ item: PaiContextItem) -> some View {
        Section {
            Button {
                if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.body).foregroundStyle(.primary)
                        Text(item.description).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded.contains(item.id) ? 90 : 0))
                }
            }
            if expanded.contains(item.id) {
                ForEach(item.tools ?? item.lines.map { PaiContextItem.Tool(name: $0, description: nil) }) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(.paiMono)
                        if let description = tool.description, !description.isEmpty {
                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }
}

@available(iOS 16.0, *)
private struct ContextItemRoute: Hashable {
    let id: String
}

/// The text of one instruction, memory or skill, rendered; an editable one opens in an editor and saves back.
@available(iOS 16.0, *)
private struct ContextDetailView: View {
    let id: String
    @ObservedObject var settings: PaiSettingsStore
    @State private var editing = false
    @State private var draft = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var item: PaiContextItem? { settings.item(id) }

    var body: some View {
        Group {
            if let item {
                if editing {
                    editor
                } else {
                    reader(item)
                }
            } else {
                ContentUnavailableCompat(symbol: "doc", title: "Gone", detail: "This item is no longer listed.")
            }
        }
        .navigationTitle(item?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let item, item.editable {
                ToolbarItem(placement: .topBarTrailing) {
                    if editing {
                        HStack(spacing: 14) {
                            Button("Cancel") { editing = false }
                            Button(saving ? "Saving…" : "Save") { save(item) }.fontWeight(.semibold).disabled(saving)
                        }
                    } else {
                        Button("Edit") {
                            draft = item.body ?? ""
                            editing = true
                            focused = true
                        }
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(editing)
    }

    private func reader(_ item: PaiContextItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !item.description.isEmpty { Text(item.description).font(.footnote).foregroundStyle(.secondary) }
                Text(item.source).font(.paiMonoSmall).foregroundStyle(.tertiary).textSelection(.enabled)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Divider()
                if (item.body ?? "").isEmpty {
                    Text("(empty)").foregroundStyle(.tertiary)
                } else {
                    MarkdownView(text: item.body!)
                }
            }
            .padding(16)
        }
    }

    private var editor: some View {
        TextEditor(text: $draft)
            .font(.paiMono)
            .focused($focused)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 10)
            .background(Color(.systemBackground))
            .overlay(alignment: .bottom) {
                if let error { Text(error).font(.footnote).foregroundStyle(.red).padding(8).frame(maxWidth: .infinity).background(.thinMaterial) }
            }
    }

    private func save(_ item: PaiContextItem) {
        saving = true
        error = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                try await settings.save(item, text: draft)
                editing = false
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
