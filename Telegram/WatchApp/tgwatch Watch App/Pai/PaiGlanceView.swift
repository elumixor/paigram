import SwiftUI

/// The glance on the wrist: the plan's windows, today's spend and who spent it, the running agents and the
/// questions waiting on the user, each answerable from here.
struct PaiGlanceView: View {
    @State private var pai = PaiWatch.shared

    var body: some View {
        List {
            if let glance = pai.glance {
                Section {
                    PaiUsageHeader(glance: glance)
                        .listRowBackground(Color.clear)
                }
                if !glance.needs.isEmpty {
                    Section(glance.needsCount > glance.needs.count ? "Waiting · \(glance.needsCount)" : "Waiting") {
                        ForEach(glance.needs) { need in
                            NavigationLink {
                                PaiNeedView(need: need)
                            } label: {
                                PaiNeedRow(need: need, sending: pai.answering.contains(need.id))
                            }
                        }
                    }
                }
                if !glance.agents.isEmpty {
                    Section("Today") {
                        ForEach(glance.agents) { agent in
                            HStack {
                                Text(agent.name).lineLimit(1)
                                Spacer()
                                Text(PaiFormat.usd(agent.usd)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
                Text("Updated \(glance.at, style: .relative) ago")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            } else if pai.loading {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            if let failure = pai.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Pai")
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
        .task { pai.refresh() }
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
