import AVKit
import SwiftUI

@available(iOS 16.0, *)
extension AgentFace.Who {
    /// The face of an agent by its slug, from the list the chat keeps.
    static func of(_ slug: String) -> AgentFace.Who {
        let agent = PaiChat.agent(slug)
        return AgentFace.Who(slug: slug, name: agent?.name ?? slug, avatar: agent?.avatar)
    }
}

/// A phone button that calls an agent; borderless, so it works inside list rows and links.
@available(iOS 16.0, *)
struct PaiCallButton: View {
    let slug: String
    var size: CGFloat = 32

    var body: some View {
        Button { PaiCall.shared.start(agent: slug) } label: {
            Image(systemName: "phone.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: size, height: size)
                .background(Color.accentColor.opacity(0.12), in: Circle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Call")
    }
}

// MARK: The call screen

/// What the call window shows: the whole screen, or the pill when minimized.
@available(iOS 16.0, *)
struct PaiCallRoot: View {
    @EnvironmentObject private var call: PaiCall

    var body: some View {
        Group {
            if call.minimized {
                PaiCallPill()
            } else {
                PaiCallScreen()
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// "Listening · 0:42": the state and, once connected, the time on the call.
@available(iOS 16.0, *)
struct PaiCallStatus: View {
    @EnvironmentObject private var call: PaiCall

    private var word: String {
        switch call.state {
        case "listening": return "Listening"
        case "thinking": return "Thinking…"
        case "speaking": return "Speaking"
        case "ended": return call.endReason.map { $0 == "hung up" ? "Call ended" : $0 } ?? "Call ended"
        default: return "Connecting…"
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let connectedAt = call.connectedAt, call.state != "ended" {
                Text("\(word) · \(context.date.timeIntervalSince(connectedAt).paiDuration)").monospacedDigit()
            } else {
                Text(word)
            }
        }
    }
}

@available(iOS 16.0, *)
struct PaiCallScreen: View {
    @EnvironmentObject private var call: PaiCall
    @State private var showTranscript = false

    private var hue: Double { Double(PaiAvatars.hue(call.slug)) }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.38), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if showTranscript {
                    HStack(spacing: 12) {
                        AgentFace(who: .of(call.slug), size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(call.agentName).font(.headline)
                            PaiCallStatus().font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    PaiCallTranscript(lines: call.lines)
                } else {
                    Spacer()
                    portrait
                    Text(call.agentName).font(.largeTitle.weight(.semibold)).padding(.top, 22).lineLimit(1).minimumScaleFactor(0.6)
                    PaiCallStatus().font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 28).padding(.top, 4)
                    Spacer()
                }
                if let note = call.note {
                    Text(note).font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .padding(.horizontal, 24).padding(.bottom, 12)
                        .transition(.opacity)
                }
                controls
            }
            .foregroundStyle(.white)
        }
        .animation(.easeOut(duration: 0.2), value: showTranscript)
        .animation(.easeOut(duration: 0.2), value: call.note)
    }

    private var topBar: some View {
        HStack {
            Button { call.setMinimized(true) } label: {
                Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40).background(Color.white.opacity(0.14), in: Circle())
            }
            Spacer()
            Menu {
                Picker("Voice", selection: Binding(get: { call.engine }, set: { call.setEngine($0) })) {
                    ForEach(call.engines) { engine in Text(engine.label).tag(engine.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                    Text(call.label(engine: call.engine)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color.white.opacity(0.14), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.top, 8)
    }

    /// The face, with a ring that breathes while the agent speaks.
    private var portrait: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: call.state != "speaking")) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let scale = call.state == "speaking" ? 1.0 + 0.07 * (1 + sin(t * 5.5)) / 2 : 1.0
                Circle().fill(Color.white.opacity(call.state == "speaking" ? 0.16 : 0.07))
                    .frame(width: 184, height: 184)
                    .scaleEffect(scale)
            }
            AgentFace(who: .of(call.slug), size: 150)
        }
    }

    private var controls: some View {
        VStack(spacing: 26) {
            HStack(spacing: 34) {
                PaiCallControl(symbol: call.muted ? "mic.slash.fill" : "mic.fill", title: call.muted ? "Unmute" : "Mute", on: call.muted) {
                    call.setMuted(!call.muted)
                }
                PaiCallControl(symbol: "text.bubble.fill", title: "Transcript", on: showTranscript) {
                    showTranscript.toggle()
                }
                VStack(spacing: 6) {
                    PaiRoutePicker().frame(width: 64, height: 64).background(Color.white.opacity(0.14), in: Circle())
                    Text("Audio").font(.caption)
                }
            }
            Button { call.hangUp() } label: {
                Image(systemName: "phone.down.fill").font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 74, height: 74).background(Color.red, in: Circle())
            }
            .accessibilityLabel("Hang up")
        }
        .padding(.top, 12).padding(.bottom, 28)
    }
}

@available(iOS 16.0, *)
private struct PaiCallControl: View {
    let symbol: String
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 24, weight: .medium))
                    .foregroundStyle(on ? Color.black : Color.white)
                    .frame(width: 64, height: 64)
                    .background(on ? Color.white : Color.white.opacity(0.14), in: Circle())
                Text(title).font(.caption).foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }
}

/// The system's audio route picker: speaker, iPhone, AirPods.
@available(iOS 16.0, *)
private struct PaiRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .white
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// What was said on the call, the user's lines on the right; a partial line is dimmer until it settles.
@available(iOS 16.0, *)
private struct PaiCallTranscript: View {
    let lines: [PaiCall.Line]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if lines.isEmpty {
                        Text("What you both say shows up here.").font(.footnote).foregroundStyle(.secondary).padding(.top, 40)
                    }
                    ForEach(lines) { line in
                        PaiCallBubble(role: line.role, text: line.text, settled: line.final).id(line.id)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .onChange(of: lines) { lines in
                guard let last = lines.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

@available(iOS 16.0, *)
private struct PaiCallBubble: View {
    let role: String
    let text: String
    var settled = true

    var body: some View {
        let mine = role == "user"
        Text(text)
            .font(.callout)
            .foregroundStyle(mine ? Color.white : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(mine ? Color.accentColor : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(settled ? 1 : 0.6)
            .frame(maxWidth: 300, alignment: mine ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
            .textSelection(.enabled)
    }
}

/// The minimized call: face, name, time, mute and hang up; a tap brings the screen back.
@available(iOS 16.0, *)
private struct PaiCallPill: View {
    @EnvironmentObject private var call: PaiCall

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                AgentFace(who: .of(call.slug), size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(call.agentName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    PaiCallStatus().font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { call.setMuted(!call.muted) } label: {
                    Image(systemName: call.muted ? "mic.slash.fill" : "mic.fill").frame(width: 34, height: 34)
                        .background(call.muted ? Color.white : Color.white.opacity(0.15), in: Circle())
                        .foregroundStyle(call.muted ? Color.black : Color.white)
                }
                .buttonStyle(.plain)
                Button { call.hangUp() } label: {
                    Image(systemName: "phone.down.fill").foregroundStyle(.white).frame(width: 34, height: 34).background(Color.red, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 8).padding(.trailing, 8).padding(.vertical, 6)
            .background(Color(white: 0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.green.opacity(0.6), lineWidth: 1))
            .contentShape(Capsule())
            .onTapGesture { call.setMinimized(false) }
            .padding(.horizontal, 12).padding(.bottom, 4)
        }
        .foregroundStyle(.white)
    }
}

// MARK: Calls list

@available(iOS 16.0, *)
@MainActor
final class PaiCallsStore: ObservableObject {
    @Published private(set) var calls: [PaiCallRecord] = []
    @Published private(set) var loaded = false
    @Published var error: String?

    func load() async {
        do {
            let list = try await PaiClient().calls()
            calls = list.calls
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

/// Recent calls, newest first: who, what came of it, how long; a tap opens the transcript.
@available(iOS 16.0, *)
struct PaiCallsList: View {
    @StateObject private var store = PaiCallsStore()

    var body: some View {
        List {
            if store.calls.isEmpty {
                if !store.loaded {
                    SkeletonRow()
                    SkeletonRow()
                } else if let error = store.error {
                    ContentUnavailableCompat(symbol: "bolt.slash", title: "Not connected", detail: error)
                } else {
                    ContentUnavailableCompat(symbol: "phone", title: "No calls yet", detail: "Tap the phone on any agent to talk to it")
                }
            }
            ForEach(store.calls) { record in
                NavigationLink {
                    PaiCallDetailView(record: record)
                } label: {
                    PaiCallRow(record: record)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12))
            }
        }
        .listStyle(.plain)
        .refreshable { await store.load() }
        .task { await store.load() }
        .onReceive(NotificationCenter.default.publisher(for: PaiCall.ended)) { _ in
            // The headline is written a few seconds after the call.
            Task {
                await store.load()
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await store.load()
            }
        }
    }
}

@available(iOS 16.0, *)
private struct PaiCallRow: View {
    let record: PaiCallRecord

    var body: some View {
        HStack(spacing: 12) {
            AgentFace(who: .of(record.agent), size: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(AgentFace.Who.of(record.agent).name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    if let date = record.startDate {
                        Text(date.paiCallTime).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(record.paiHeadline).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                Label(record.paiSummary, systemImage: record.status == "live" ? "waveform" : "phone.fill")
                    .font(.caption).foregroundStyle(record.status == "live" ? Color.green : Color.secondary)
                    .labelStyle(.titleAndIcon)
            }
            PaiCallButton(slug: record.agent)
        }
    }
}

extension PaiCallRecord {
    var paiHeadline: String {
        if let headline, !headline.isEmpty { return headline }
        return status == "live" ? "On the call now" : "Voice call"
    }

    var paiSummary: String {
        let duration = (durationS ?? 0).paiDuration
        if let engine, #available(iOS 16.0, *) {
            return "\(duration) · \(PaiCall.shared.label(engine: engine))"
        }
        return duration
    }
}

@available(iOS 16.0, *)
extension Date {
    /// "14:05" today, "Yesterday", or the date.
    var paiCallTime: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        return formatted(date: .abbreviated, time: .omitted)
    }
}

/// One call: who, when, what came of it, everything said; Call again at the bottom.
@available(iOS 16.0, *)
struct PaiCallDetailView: View {
    let record: PaiCallRecord
    @State private var detail: PaiCallRecord?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                VStack(spacing: 8) {
                    AgentFace(who: .of(record.agent), size: 72)
                    Text(AgentFace.Who.of(record.agent).name).font(.title3.weight(.semibold))
                    Text([record.startDate.map { $0.formatted(date: .abbreviated, time: .shortened) }, record.paiSummary].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary)
                    Text((detail ?? record).paiHeadline).font(.callout).multilineTextAlignment(.center).padding(.top, 4)
                }
                .padding(.vertical, 12)
                if let lines = detail?.transcript {
                    if lines.isEmpty {
                        Text("Nothing was said on this call.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        PaiCallBubble(role: line.role, text: line.text)
                    }
                } else if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                } else {
                    ProgressView().padding(.top, 20)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 90)
        }
        .safeAreaInset(edge: .bottom) {
            Button { PaiCall.shared.start(agent: record.agent) } label: {
                Label("Call again", systemImage: "phone.fill").font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.green, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24).padding(.bottom, 12)
        }
        .navigationTitle("Call")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                detail = try await PaiClient().callDetail(record.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A `call.ended` row in an agent's chat: what came of the call, how long, Call again.
@available(iOS 16.0, *)
struct PaiCallEndedCard: View {
    let row: PaiLogMessage
    let slug: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "phone.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(Color.green, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(row.meta.headline ?? row.firstLine).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(["Voice call", row.meta.durationS?.paiDuration, row.meta.engine.map { PaiCall.shared.label(engine: $0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button { PaiCall.shared.start(agent: row.meta.agent ?? slug) } label: {
                Text("Call again").font(.footnote.weight(.semibold)).foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }
}
