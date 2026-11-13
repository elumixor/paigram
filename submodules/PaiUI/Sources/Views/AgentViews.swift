import SwiftUI
import SwiftSignalKit

extension Color {
    /// An agent's status in colour: running in the accent, waiting on you in amber, the rest quiet.
    static func paiStatus(_ status: String?) -> Color {
        switch status {
        case "working": return .accentColor
        case "waiting": return .paiWaiting
        case "closed": return Color.secondary.opacity(0.4)
        default: return .paiIdle
        }
    }
}

/// An agent's status as its symbol, breathing while it works.
@available(iOS 16.0, *)
struct AgentStatusIcon: View {
    let status: String?

    var body: some View {
        let icon = Image(systemName: PaiAgentStatus.symbol(status))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.paiStatus(status))
            .frame(width: 20)
        if status == "working" { icon.modifier(Breathing()) } else { icon }
    }
}

/// Every agent under pai, indented by depth: its status, its open tasks, what it spent today.
@available(iOS 16.0, *)
struct AgentTreeView: View {
    let open: (PaiAgent) -> Void
    let close: () -> Void
    @EnvironmentObject private var store: PaiStore

    private struct Row: Identifiable {
        let agent: PaiAgent
        let depth: Int
        var id: String { agent.slug }
    }

    /// Depth first from pai; within a level the open ones first, the latest active first.
    private var rows: [Row] {
        let slugs = Set(store.agents.map(\.slug))
        let children = Dictionary(grouping: store.agents) { agent -> String in
            guard let parent = agent.parent, slugs.contains(parent) else { return "" }
            return parent
        }
        let order: (PaiAgent, PaiAgent) -> Bool = { a, b in
            if a.isPai != b.isPai { return a.isPai }
            if a.isClosed != b.isClosed { return !a.isClosed }
            return (a.lastActive ?? 0) > (b.lastActive ?? 0)
        }
        var result: [Row] = []
        func walk(_ parent: String, depth: Int) {
            for agent in (children[parent] ?? []).sorted(by: order) where !result.contains(where: { $0.id == agent.slug }) {
                result.append(Row(agent: agent, depth: depth))
                walk(agent.slug, depth: depth + 1)
            }
        }
        walk("", depth: 0)
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                if store.agents.isEmpty {
                    if let error = store.connectionError {
                        ContentUnavailableCompat(symbol: "bolt.slash", title: "Not connected", detail: error)
                    } else {
                        ContentUnavailableCompat(symbol: "person.2", title: "No agents yet", detail: "pai creates them as work comes in")
                    }
                }
                ForEach(rows) { row in
                    AgentTreeRow(agent: row.agent, depth: row.depth)
                        .contentShape(Rectangle())
                        .onTapGesture { open(row.agent) }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 30)
            .refreshable { store.refreshAgents() }
            .animation(.default, value: store.agents)
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(action: close) { Image(systemName: "chevron.left") } }
                ToolbarItem(placement: .topBarTrailing) {
                    if let error = store.connectionError { Image(systemName: "bolt.slash").foregroundStyle(.red).help(error) }
                }
            }
        }
        .onAppear {
            PaiPerf.first("view.agentTree.appear")
            store.start()
            store.refreshAgents()
        }
    }
}

/// One agent, one line: status, name, open tasks, turns and cost today.
@available(iOS 16.0, *)
struct AgentTreeRow: View {
    let agent: PaiAgent
    let depth: Int

    var body: some View {
        HStack(spacing: 8) {
            if depth > 0 {
                Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.quaternary)
                    .padding(.leading, CGFloat(depth - 1) * 18)
            }
            AgentStatusIcon(status: agent.status)
            Text(agent.name).font(.callout.weight(depth == 0 ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 8)
            if let open = agent.openTasks, open > 0 {
                Label("\(open)", systemImage: "checklist").font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            }
            if let spent = spentToday {
                Text(spent).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            if !agent.isClosed {
                PaiCallButton(slug: agent.slug, size: 28)
            }
        }
        .opacity(agent.isClosed ? 0.55 : 1)
    }

    /// "4 turns · $0.12"; nothing on a quiet day.
    private var spentToday: String? {
        let turns = agent.turnsToday ?? 0
        let cost = agent.costUsd ?? 0
        guard turns > 0 || cost > 0 else { return nil }
        let costText = cost > 0 ? String(format: "$%.2f", cost) : nil
        return [turns > 0 ? "\(turns) \(turns == 1 ? "turn" : "turns")" : nil, costText].compactMap { $0 }.joined(separator: " · ")
    }
}

/// An agent's portrait in a circle, its initials on its colour until the portrait loads.
@available(iOS 16.0, *)
struct AgentFace: View {
    struct Who: Equatable {
        let slug: String
        let name: String
        let avatar: String?
    }

    let who: Who
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image = image ?? who.avatar.flatMap(PaiAvatars.cached) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(uiImage: PaiAvatars.placeholder(name: who.name, slug: who.slug, size: size)).resizable()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: who.avatar) {
            guard let url = who.avatar, PaiAvatars.cached(url) == nil else { return }
            image = await withCheckedContinuation { continuation in
                let _ = PaiAvatars.image(url).start(next: { continuation.resume(returning: $0) })
            }
        }
    }
}
