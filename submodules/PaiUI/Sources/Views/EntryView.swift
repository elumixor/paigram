import SwiftUI

/// One transcript line in the TUI grammar.
@available(iOS 16.0, *)
struct EntryView: View {
    let entry: ThreadEntry
    @ObservedObject var thread: ThreadModel

    var body: some View {
        switch entry.kind {
        case .user(let text):
            line(glyph: "❯", glyphColor: .accentColor) {
                Text(text).font(.body).textSelection(.enabled)
            }
        case .assistant(let text, let live):
            line(glyph: "⏺", glyphColor: live ? .accentColor : .secondary, breathing: live) {
                MarkdownText(text: text).font(.body).textSelection(.enabled)
            }
        case .thinking(let text):
            line(glyph: "∴", glyphColor: .secondary) {
                Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
            }
        case .tool(let name, let summary, let result, let running, let depth):
            ToolEntry(name: name, summary: summary, result: result, running: running)
                .padding(.leading, CGFloat(depth) * 18)
        case .question(let id, let questions):
            QuestionCard(questionId: id, questions: questions) { answer in Task { await thread.answer(answer) } }
        case .notice(let text, let isError):
            line(glyph: "·", glyphColor: isError ? .red : .secondary) {
                Text(text).font(.footnote).foregroundStyle(isError ? Color.red : Color.secondary)
            }
        }
    }

    private func line<Content: View>(glyph: String, glyphColor: Color, breathing: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(glyph).font(.paiMono.weight(.bold)).foregroundStyle(glyphColor)
                .frame(width: 14, alignment: .center)
                .modifier(OptionalBreathing(on: breathing))
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@available(iOS 16.0, *)
struct OptionalBreathing: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.modifier(Breathing()) } else { content }
    }
}

/// `⏺ Bash($ ls)` with its `⎿ result`; the bullet breathes until the result lands.
@available(iOS 16.0, *)
struct ToolEntry: View {
    let name: String
    let summary: String
    let result: String?
    let running: Bool
    @State private var expanded = false

    private var isLong: Bool { (result ?? "").count > 160 || (result ?? "").contains("\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("⏺").font(.paiMono.weight(.bold))
                    .foregroundStyle(running ? Color.accentColor : Color.green)
                    .frame(width: 14)
                    .modifier(OptionalBreathing(on: running))
                Image(systemName: ToolGlyph.symbol(for: name, summary: summary))
                    .font(.caption).foregroundStyle(.secondary).frame(width: 14)
                Text(summary).font(.paiMono).lineLimit(expanded ? nil : 2).textSelection(.enabled)
                if running { Spinner() }
            }
            if let result, !result.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text("⎿").font(.paiMono).foregroundStyle(.tertiary).frame(width: 14)
                    Text(result).font(.paiMonoSmall).foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 3).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 22)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if isLong { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } }
    }
}

/// Three dots that walk while a tool runs.
@available(iOS 16.0, *)
struct Spinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.33, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Color.accentColor).frame(width: 4, height: 4)
                    .opacity(reduceMotion || phase == i ? 1 : 0.3)
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}

/// The assistant asked; each option is one tap, or type the answer below.
@available(iOS 16.0, *)
struct QuestionCard: View {
    let questionId: String
    let questions: [PaiQuestion]
    let onAnswer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = question.header, !header.isEmpty {
                        Text(header).font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(Color.paiWaiting)
                    }
                    Text(question.question).font(.body)
                    ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                        Button { onAnswer(option.label) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).font(.subheadline.weight(.medium))
                                if let description = option.description, !description.isEmpty {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.paiWaiting, lineWidth: 1.5))
    }
}
