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

/// pai › Hiring › Screener: every level above is a way back up to it.
@available(iOS 16.0, *)
struct BreadcrumbBar: View {
    let chain: [PaiAgent]
    let current: String
    let open: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(chain.enumerated()), id: \.element.slug) { index, agent in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    if agent.slug == current {
                        Text(agent.name).font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                    } else {
                        Button(agent.name) { open(agent.slug) }.font(.footnote).foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: The tree

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

// MARK: An agent's chat

/// A sub-agent's chat, which has no topic of its own: its brief, what it said and was told, the work it handed
/// on (cards into deeper agents), its questions and the events about it; a composer writes to it directly.
@available(iOS 16.0, *)
struct AgentChatView: View {
    let slug: String
    let open: (String) -> Void
    let back: () -> Void
    @EnvironmentObject private var store: PaiStore
    @EnvironmentObject private var insets: PaiInsets
    @State private var draft = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var agent: PaiAgent? { store.agent(slug) }
    private var rows: [PaiLogMessage] { store.rows(slug) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if let brief = agent?.brief, !brief.isEmpty {
                            BriefCard(brief: brief)
                        }
                        ForEach(rows) { row in
                            AgentMessageRow(row: row, slug: slug, open: open, answer: answer).id(row.id)
                        }
                        ForEach(store.drafts(of: slug)) { draft in
                            DraftCard(draft: draft, face: agent) { send in resolve(draft.id, send: send) }.id("draft-\(draft.id)")
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: rows.last?.id) { id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                BreadcrumbBar(chain: chain, current: slug, open: open)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .navigationTitle(agent?.name ?? slug)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(action: back) { Image(systemName: "chevron.left") } }
                ToolbarItem(placement: .topBarTrailing) {
                    if let error = store.connectionError {
                        Image(systemName: "bolt.slash").foregroundStyle(.red).help(error)
                    } else if let agent {
                        HStack(spacing: 10) {
                            AgentStatusIcon(status: agent.isBusy ? "working" : PaiAgentStatus.effective(agent: agent.slug, posted: agent.status)).help(PaiAgentStatus.label(agent.status))
                            if agent.isBusy {
                                StopButton {
                                    Task {
                                        try? await PaiClient().stop(agent: slug)
                                        store.refreshAgents()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task {
            store.start()
            store.refreshDrafts()
            await store.loadChat(slug)
        }
    }

    /// pai down to this agent; an agent the list does not know yet is just itself.
    private var chain: [PaiAgent] {
        let chain = PaiChat.chain(to: slug)
        if !chain.isEmpty { return chain }
        return [PaiAgent(slug: slug, name: slug, kind: "sub", parent: nil, brief: nil, status: nil, threadId: nil, turnsToday: nil, costUsd: nil, lastActive: nil, depth: nil, breadcrumb: nil, openTasks: nil, queued: nil)]
    }

    private var composer: some View {
        VStack(spacing: 4) {
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message \(agent?.name ?? slug)", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                BarButton(symbol: "arrow.up", filled: true, action: send)
                    .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8 + insets.bottom)
        .background(Color(.systemBackground))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        sending = true
        error = nil
        Task {
            defer { sending = false }
            do {
                try await store.send(text, to: slug)
            } catch {
                draft = text
                self.error = error.localizedDescription
            }
        }
    }

    private func resolve(_ draftId: Int, send: Bool) {
        error = nil
        Task {
            do {
                try await store.resolve(draft: draftId, send: send)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func answer(_ askId: Int, _ text: String) {
        error = nil
        Task {
            do {
                try await store.answer(ask: askId, text: text, in: slug)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// What the agent was set up to do, at the top of its chat.
@available(iOS 16.0, *)
private struct BriefCard: View {
    let brief: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Brief", systemImage: "doc.text").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            MarkdownText(text: brief).font(.footnote).lineLimit(expanded ? nil : 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { expanded.toggle() } }
        .padding(.bottom, 6)
    }
}

/// One row of an agent's chat, drawn by what it is.
@available(iOS 16.0, *)
private struct AgentMessageRow: View {
    let row: PaiLogMessage
    let slug: String
    let open: (String) -> Void
    let answer: (Int, String) -> Void
    @EnvironmentObject private var store: PaiStore

    private func name(_ party: String) -> String {
        if party == "user" { return "You" }
        if let agent = store.agent(party) { return agent.name }
        if let colon = party.firstIndex(of: ":") { return String(party[party.index(after: colon)...]) }
        return party
    }

    /// Who wrote a row, drawn as a face; routines and watchers get a generic one.
    private func face(_ party: String) -> AgentFace.Who {
        if let agent = store.agent(party) { return AgentFace.Who(slug: agent.slug, name: agent.name, avatar: agent.avatar) }
        return AgentFace.Who(slug: party, name: name(party), avatar: nil)
    }

    var body: some View {
        switch row.kind {
        case "event":
            EventLine(row: row, isHere: (row.meta.agent ?? slug) == slug) { open(row.meta.agent ?? slug) }
        case "notice":
            NoticeCard(row: row)
        case "delegate", "request":
            if row.from == slug {
                AgentCard(symbol: PaiEventIcon.symbol(event: row.kind), name: name(row.to), line: row.firstLine, status: store.agent(row.to)?.status, face: face(row.to)) { open(row.to) }
            } else {
                Bubble(text: row.body, mine: false, caption: "from \(name(row.from))", face: face(row.from))
            }
        case "report", "response":
            if row.to == slug {
                AgentCard(symbol: PaiEventIcon.symbol(event: row.kind), name: name(row.from), line: row.firstLine, status: nil, face: face(row.from)) { open(row.from) }
            } else {
                Bubble(text: row.body, mine: false, caption: "to \(name(row.to))", face: face(row.from))
            }
        case "ask":
            AskCard(row: row, face: face(row.from), answer: answer)
        case "answer":
            Bubble(text: row.body, mine: true, caption: nil, symbol: "checkmark.bubble")
        default:
            Bubble(text: row.body, mine: row.from == "user", caption: row.from == "user" || row.from == slug ? nil : name(row.from), face: row.from == "user" ? nil : face(row.from))
        }
    }
}

/// An event, the way the chat shows it: centered, grey, its symbol first; red when something failed.
@available(iOS 16.0, *)
private struct EventLine: View {
    let row: PaiLogMessage
    let isHere: Bool
    let open: () -> Void

    var body: some View {
        let isError = row.meta.event == "error"
        HStack(spacing: 5) {
            Image(systemName: PaiEventIcon.symbol(event: row.meta.event, icon: row.meta.icon))
            Text(row.firstLine).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(isError ? Color.red : Color.secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .onTapGesture { if !isHere { open() } }
    }
}

@available(iOS 16.0, *)
private struct NoticeCard: View {
    let row: PaiLogMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bell").foregroundStyle(row.meta.priority == "urgent" ? Color.paiWaiting : Color.secondary)
            MarkdownText(text: row.body).font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Work handed to an agent or what it said back: one line, its status, a way into its chat.
@available(iOS 16.0, *)
struct AgentCard: View {
    let symbol: String
    let name: String
    let line: String
    let status: String?
    var face: AgentFace.Who? = nil
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                if let face {
                    AgentFace(who: face, size: 30)
                } else {
                    Image(systemName: symbol).font(.footnote.weight(.semibold)).foregroundStyle(Color.accentColor).frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        if let status {
                            Label(PaiAgentStatus.label(status), systemImage: PaiAgentStatus.symbol(status))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.paiStatus(status))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.paiStatus(status).opacity(0.14), in: Capsule())
                        }
                    }
                    if !line.isEmpty {
                        Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A question from the agent: where it comes from, the question, its options until it is answered.
@available(iOS 16.0, *)
private struct AskCard: View {
    let row: PaiLogMessage
    let face: AgentFace.Who
    let answer: (Int, String) -> Void
    @State private var typed = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AgentFace(who: face, size: 28)
            VStack(alignment: .leading, spacing: 8) {
                Label(row.meta.breadcrumb ?? "Question", systemImage: "questionmark.bubble")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.paiWaiting)
                MarkdownText(text: row.body).font(.callout)
                if let given = row.meta.answer {
                    Label(given, systemImage: "checkmark.bubble").font(.footnote).foregroundStyle(.secondary)
                } else if let askId = row.meta.askId {
                    ForEach(row.meta.options ?? [], id: \.self) { option in
                        Button { answer(askId, option) } label: {
                            Text(option).font(.footnote.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                    HStack(spacing: 6) {
                        TextField("Your answer", text: $typed, axis: .vertical)
                            .font(.footnote)
                            .lineLimit(1...4)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Button {
                            let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            typed = ""
                            answer(askId, text)
                        } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.title3)
                        }
                        .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A message an agent wrote for the user to send: where it goes, what it says, Send or Discard.
@available(iOS 16.0, *)
private struct DraftCard: View {
    let draft: PaiDraft
    let face: PaiAgent?
    let resolve: (Bool) -> Void

    private var channel: (String, String) {
        switch draft.channel {
        case "email": return ("Email", "envelope")
        case "telegram": return ("Telegram", "paperplane")
        case "linkedin": return ("LinkedIn message", "person.2")
        case "post": return ("LinkedIn post", "megaphone")
        default: return ("WhatsApp", "message")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let face {
                AgentFace(who: AgentFace.Who(slug: face.slug, name: face.name, avatar: face.avatar), size: 28)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("\(channel.0) draft", systemImage: channel.1)
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.paiWaiting)
                if let to = draft.fields.to, !to.isEmpty {
                    Text("To \(to)").font(.footnote.weight(.semibold))
                }
                if let subject = draft.fields.subject, !subject.isEmpty {
                    Text(subject).font(.footnote.weight(.medium))
                }
                if let body = draft.fields.body, !body.isEmpty {
                    MarkdownText(text: body).font(.callout)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if let note = draft.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button { resolve(false) } label: {
                        Text("Discard").font(.footnote.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    Button { resolve(true) } label: {
                        Label("Send", systemImage: "paperplane.fill").font(.footnote.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// A plain message: the user's on the right in the accent, everyone else's on the left.
@available(iOS 16.0, *)
private struct Bubble: View {
    let text: String
    let mine: Bool
    let caption: String?
    var symbol: String? = nil
    var face: AgentFace.Who? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if let face, !mine {
                AgentFace(who: face, size: 28)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private var content: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            if let caption {
                Text(caption).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.footnote) }
                MarkdownText(text: text).font(.callout)
            }
            .foregroundStyle(mine ? Color.white : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(mine ? Color.accentColor : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .textSelection(.enabled)
        }
        .frame(maxWidth: 320, alignment: mine ? .trailing : .leading)
    }
}
