import SwiftUI

/// Where the watch opens: Pai's dashboard. The plan's windows and today's spend, the asks waiting on the user
/// (each answerable here), and every agent with what it is on and its plan. Telegram's chats sit behind a button.
struct PaiHomeView: View {
    @State private var pai = PaiWatch.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $pai.path) {
            List {
                if let glance = pai.glance {
                    Section {
                        PaiUsageHeader(glance: glance)
                            .listRowBackground(Color.clear)
                    }
                    Section(glance.needsCount > glance.needs.count ? "Asks · \(glance.needsCount)" : "Asks") {
                        if glance.needs.isEmpty {
                            Label("Nothing waiting", systemImage: "checkmark.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(glance.needs) { need in
                            NavigationLink(value: PaiRoute.need(need.id)) {
                                PaiNeedRow(need: need, sending: pai.answering.contains(need.id))
                            }
                        }
                    }
                    if !glance.team.isEmpty {
                        Section("Agents") {
                            ForEach(Self.ordered(glance.team)) { member in
                                NavigationLink(value: PaiRoute.agent(member.slug)) {
                                    PaiMemberRow(member: member, asks: glance.needs.filter { $0.agent == member.slug }.count)
                                }
                            }
                        }
                    }
                    if !glance.agents.isEmpty {
                        Section("Spend today") {
                            ForEach(glance.agents) { agent in
                                HStack {
                                    Text(agent.name).lineLimit(1)
                                    Spacer()
                                    Text(PaiFormat.usd(agent.usd)).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .font(.footnote)
                            }
                        }
                    }
                } else if pai.loading {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                } else if !pai.signedIn {
                    Text("Open Paigram on your iPhone and sign in to pai.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                if let failure = pai.failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .listRowBackground(Color.clear)
                }
                Section {
                    Button {
                        pai.telegramPresented = true
                    } label: {
                        Label("Telegram", systemImage: "paperplane.fill")
                    }
                    if let at = pai.glance?.at {
                        Text("Updated \(at, style: .relative) ago")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle("Pai")
            .navigationDestination(for: PaiRoute.self) { route in
                switch route {
                case let .agent(slug): PaiAgentView(slug: slug)
                case let .need(id): PaiNeedScreen(id: id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        pai.refresh()
                    } label: {
                        if pai.loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(pai.loading)
                }
            }
        }
        .task { pai.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { pai.refresh() }
        }
    }

    /// Working agents first, then the rest in the tree's order.
    static func ordered(_ team: [PaiGlance.Member]) -> [PaiGlance.Member] {
        team.filter(\.working) + team.filter { !$0.working }
    }
}

enum PaiRoute: Hashable {
    case agent(String)
    case need(String)
}

struct PaiStatusDot: View {
    let status: String

    var body: some View {
        Circle()
            .fill(Self.color(status))
            .frame(width: 7, height: 7)
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "working": return .green
        case "paused", "blocked": return .orange
        case "failed", "error": return .red
        default: return .gray
        }
    }
}

struct PaiMemberRow: View {
    let member: PaiGlance.Member
    let asks: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                PaiStatusDot(status: member.status)
                Text(member.name).font(.footnote.weight(.semibold)).lineLimit(1)
                if let role = member.role {
                    Text(role).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if asks > 0 {
                    Label("\(asks)", systemImage: "questionmark.bubble.fill")
                        .labelStyle(PaiCompactLabel())
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            if let line = member.now?.text ?? member.doing {
                Text(line).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// One agent: what it last said it is on, its plan, and its asks.
struct PaiAgentView: View {
    let slug: String
    @State private var pai = PaiWatch.shared

    var body: some View {
        List {
            if let member = pai.glance?.team.first(where: { $0.slug == slug }) {
                Section {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            PaiStatusDot(status: member.status)
                            Text(member.status.capitalized).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let role = member.role {
                            Text(role).font(.footnote.weight(.semibold))
                        }
                        if let doing = member.doing {
                            Text(doing).font(.footnote)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                let asks = pai.glance?.needs.filter { $0.agent == slug } ?? []
                if !asks.isEmpty {
                    Section("Asks") {
                        ForEach(asks) { need in
                            NavigationLink(value: PaiRoute.need(need.id)) {
                                PaiNeedRow(need: need, sending: pai.answering.contains(need.id))
                            }
                        }
                    }
                }
                Section("Plan") {
                    if member.steps.isEmpty {
                        Text("No plan yet").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(member.steps) { step in
                        PaiStepRow(step: step)
                    }
                }
            } else {
                Text("No longer on the team").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(pai.glance?.team.first(where: { $0.slug == slug })?.name ?? slug)
    }
}

struct PaiStepRow: View {
    let step: PaiGlance.Member.Step

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.text)
                    .font(.system(size: 13))
                    .foregroundStyle(step.state == "done" ? .secondary : .primary)
                    .lineLimit(5)
                if let eta = step.eta {
                    Text(eta).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var icon: String {
        switch step.state {
        case "now": return "arrow.right.circle.fill"
        case "done": return "checkmark.circle.fill"
        default: return "circle"
        }
    }

    private var tint: Color {
        switch step.state {
        case "now": return .blue
        case "done": return .green
        default: return .secondary
        }
    }
}

/// An ask by id, so a pushed screen follows the glance (and says so once the ask is answered elsewhere).
struct PaiNeedScreen: View {
    let id: String
    @State private var pai = PaiWatch.shared

    var body: some View {
        if let need = pai.glance?.needs.first(where: { $0.id == id }) {
            if let draft = need.draft {
                PaiDraftView(need: need, draft: draft)
            } else {
                PaiNeedView(need: need)
            }
        } else {
            Text("Answered").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct PaiUsageHeader: View {
    let glance: PaiGlance

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(glance.windows.prefix(2)) { window in
                    VStack(spacing: 2) {
                        Gauge(value: min(window.percent, 100), in: 0 ... 100) {
                            Text(window.name == "Weekly" ? "W" : "5h")
                        } currentValueLabel: {
                            Text("\(Int(window.percent.rounded()))")
                        }
                        .gaugeStyle(.accessoryCircular)
                        .tint(PaiFormat.tint(window.percent))
                        Text(window.resetsIn().map { "\(window.name == "Weekly" ? "Week" : "Session") · \($0)" } ?? window.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack {
                Label(PaiFormat.usd(glance.todayUsd), systemImage: "dollarsign.circle")
                Spacer()
                Label("\(glance.running)", systemImage: "bolt.fill")
                    .foregroundStyle(glance.running > 0 ? .green : .secondary)
                Label("\(glance.needsCount)", systemImage: "questionmark.bubble.fill")
                    .foregroundStyle(glance.needsCount > 0 ? .orange : .secondary)
            }
            .font(.footnote.monospacedDigit())
            .labelStyle(PaiCompactLabel())
        }
    }
}

struct PaiNeedRow: View {
    let need: PaiGlance.Need
    let sending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(need.from).font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                Spacer()
                if sending {
                    ProgressView().frame(width: 14, height: 14)
                } else {
                    Text(need.createdAt, style: .relative).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Text(need.plainQuestion).font(.footnote).lineLimit(3)
        }
    }
}

/// One question: the options as buttons, and a reply (dictation, scribble or keyboard) when it takes free text.
struct PaiNeedView: View {
    let need: PaiGlance.Need
    @State private var pai = PaiWatch.shared
    @State private var reply = ""
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    private var sending: Bool { pai.answering.contains(need.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(need.from).font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                Text(need.plainQuestion).font(.body)
                ForEach(need.options, id: \.self) { option in
                    Button(option) { send(option) }
                        .disabled(sending)
                }
                if need.freeText || need.options.isEmpty {
                    TextField("Reply", text: $reply)
                        .submitLabel(.send)
                        .onSubmit { send(reply) }
                        .disabled(sending)
                }
                if sending {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if failed {
                    Text("Not sent. Try again.").font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(need.from)
    }

    private func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        failed = false
        pai.answer(need, text: text) { ok in
            if ok { dismiss() } else { failed = true }
        }
    }
}

struct PaiCompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}
