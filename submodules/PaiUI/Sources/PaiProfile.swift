import AccountContext
import Display
import Foundation
import SwiftUI
import TelegramCore

/// What an agent's profile (Telegram's profile screen on its peer, `PeerInfoPaiItems.swift`) shows of it, and the lists
/// its rows open: the agent's tasks and routines, and on pai's own profile what the sessions are given, the calls and
/// the settings. The lists read; changing a task or a routine is said to the agent in its topic.
public enum PaiProfile {
    /// A list one of the profile's rows opens.
    public enum List {
        /// The tasks an agent owns; nil: everyone's.
        case tasks(owner: String?)
        /// The routines an agent runs or owns; nil: all of them.
        case routines(agent: String?)
        /// What the sessions are given, one kind: tool, skill, instruction, memory.
        case context(kind: String, title: String)
        case calls
        case settings
    }

    /// The profile's own rows of pai's sessions: kind, title, SF Symbol.
    public struct ContextKind {
        public let kind: String
        public let title: String
        public let symbol: String
    }

    public static let contextKinds: [ContextKind] = [
        ContextKind(kind: "tool", title: "Tools", symbol: "wrench.and.screwdriver.fill"),
        ContextKind(kind: "skill", title: "Skills", symbol: "sparkles"),
        ContextKind(kind: "instruction", title: "Instructions", symbol: "text.alignleft"),
        ContextKind(kind: "memory", title: "Memories", symbol: "brain.head.profile"),
    ]

    /// The address of the Keep page an agent works on (`keep:page/<id>`).
    public static func keepURL(_ agent: PaiAgent) -> String? {
        guard let urn = agent.keepPage, urn.hasPrefix("keep:page/") else {
            return nil
        }
        return "\(PaiPill.keepBase)/p/\(urn.dropFirst("keep:page/".count))"
    }

    /// A list as a screen to push from the profile; nil before iOS 16.
    public static func controller(context: AccountContext, list: List) -> ViewController? {
        guard #available(iOS 16.0, *) else {
            return nil
        }
        if case .settings = list {
            return PaiSettingsController(context: context)
        }
        return PaiProfileListController(context: context, list: list)
    }
}

@available(iOS 16.0, *)
final class PaiProfileListController: PaiHostedController {
    init(context: AccountContext, list: PaiProfile.List) {
        super.init(context: context)
        let close: () -> Void = { [weak self] in self?.dismiss() }
        self.host(PaiSignInGate(close: close) {
            PaiProfileListScreen(list: list, close: close)
        }.environmentObject(PaiHost.store))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@available(iOS 16.0, *)
private struct PaiProfileListScreen: View {
    let list: PaiProfile.List
    let close: () -> Void
    @StateObject private var settings = PaiSettingsStore()

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(action: close) { Image(systemName: "chevron.left") } }
                }
                .navigationDestination(for: ContextItemRoute.self) { route in
                    ContextDetailView(id: route.id, settings: settings)
                }
        }
    }

    @ViewBuilder private var content: some View {
        switch list {
        case let .tasks(owner):
            PaiTasksList(owner: owner)
        case let .routines(agent):
            PaiRoutinesList(agent: agent)
        case let .context(kind, title):
            ContextListView(kind: kind, title: title, settings: settings)
                .task { await settings.load() }
                .refreshable { await settings.load() }
        case .calls:
            PaiCallsList().navigationTitle("Calls")
        case .settings:
            EmptyView()
        }
    }
}

/// Tasks by where they stand: waiting on him first, then what is being done, the inbox, waiting on others, scheduled;
/// the last done ones under them.
@available(iOS 16.0, *)
private struct PaiTasksList: View {
    let owner: String?
    @EnvironmentObject private var store: PaiStore
    @State private var tasks: [PaiTaskItem] = []
    @State private var loaded = false
    @State private var error: String?

    private struct Group: Hashable {
        let status: String
        let title: String
    }

    private static let groups: [Group] = [
        Group(status: "waiting_user", title: "Waiting on you"),
        Group(status: "active", title: "Doing"),
        Group(status: "inbox", title: "Inbox"),
        Group(status: "waiting_other", title: "Waiting on others"),
        Group(status: "scheduled", title: "Scheduled"),
    ]

    private var mine: [PaiTaskItem] {
        tasks.filter { owner == nil || $0.owner == owner }
    }

    var body: some View {
        List {
            if mine.isEmpty {
                if !loaded {
                    SkeletonRow()
                    SkeletonRow()
                } else if let error {
                    ContentUnavailableCompat(symbol: "bolt.slash", title: "Not connected", detail: error)
                } else {
                    ContentUnavailableCompat(symbol: "checklist", title: "No tasks", detail: "")
                }
            }
            ForEach(Self.groups, id: \.status) { group in
                let items = mine.filter { $0.status == group.status }.sorted { ($0.due ?? "9") < ($1.due ?? "9") }
                if !items.isEmpty {
                    Section(group.title) {
                        ForEach(items) { PaiTaskRow(task: $0, owner: owner == nil ? store.agent($0.owner)?.name ?? $0.owner : nil) }
                    }
                }
            }
            let done = mine.filter { $0.status == "done" }.sorted { $0.updatedAt > $1.updatedAt }.prefix(20)
            if !done.isEmpty {
                Section("Done") {
                    ForEach(Array(done)) { PaiTaskRow(task: $0, owner: owner == nil ? store.agent($0.owner)?.name ?? $0.owner : nil) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tasks")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            tasks = try await store.client.taskItems(includeClosed: true)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

@available(iOS 16.0, *)
private struct PaiTaskRow: View {
    let task: PaiTaskItem
    /// Whose it is, when the list is everyone's.
    let owner: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.title).font(.callout).lineLimit(3)
            if let next = task.nextAction, !next.isEmpty, task.isOpen {
                Text(next).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            let meta = [owner, task.due].compactMap { $0 }
            if !meta.isEmpty {
                Text(meta.joined(separator: " · ")).font(.caption2).foregroundStyle(task.isOverdue ? Color.red : Color.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(task.status == "done" ? 0.6 : 1)
    }
}

/// Routines on a schedule and on events, each with what it does and how often it ran.
@available(iOS 16.0, *)
private struct PaiRoutinesList: View {
    let agent: String?
    @EnvironmentObject private var store: PaiStore
    @State private var routines: [PaiRoutine] = []
    @State private var loaded = false
    @State private var error: String?

    private var mine: [PaiRoutine] {
        routines.filter { agent == nil || $0.agent == agent || $0.owner == agent }
    }

    var body: some View {
        List {
            if mine.isEmpty {
                if !loaded {
                    SkeletonRow()
                } else if let error {
                    ContentUnavailableCompat(symbol: "bolt.slash", title: "Not connected", detail: error)
                } else {
                    ContentUnavailableCompat(symbol: "clock.arrow.circlepath", title: "Nothing runs by itself", detail: "")
                }
            }
            let scheduled = mine.filter(\.isScheduled)
            if !scheduled.isEmpty {
                Section("On a schedule") {
                    ForEach(scheduled) { PaiRoutineRow(routine: $0, symbol: "clock", trigger: PaiRoutineText.cron($0.schedule), agent: store.agent($0.agent)?.name) }
                }
            }
            let onEvents = mine.filter { !$0.isScheduled }
            if !onEvents.isEmpty {
                Section("When something happens") {
                    ForEach(onEvents) { PaiRoutineRow(routine: $0, symbol: "bolt", trigger: "On \(PaiRoutineText.event($0.event))", agent: store.agent($0.agent)?.name) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Routines")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            routines = try await store.client.routines()
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

@available(iOS 16.0, *)
private struct PaiRoutineRow: View {
    let routine: PaiRoutine
    let symbol: String
    let trigger: String
    let agent: String?

    var body: some View {
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
            Spacer(minLength: 4)
            if !routine.enabled {
                Text("off").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
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

/// A routine's trigger in words.
enum PaiRoutineText {
    /// Five-field cron in words for the common shapes; anything else as it is.
    static func cron(_ cron: String) -> String {
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

    static func event(_ event: String) -> String {
        switch event {
        case "gmail.new": return "new mail"
        case "linkedin.message": return "a LinkedIn message"
        case "telegram.message": return "a Telegram message"
        case "calendar.upcoming": return "an upcoming event"
        default: return event.replacingOccurrences(of: ".", with: " ")
        }
    }
}
