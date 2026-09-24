import SwiftUI

/// One thread in the list: title, where it lives, and, while it runs, the tool it is on right now.
@available(iOS 16.0, *)
struct ThreadRow: View {
    let session: PaiSession

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StateDot(session: session).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.displayTitle).font(.body.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(session.lastActivityDate.paiAge).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                if session.project != nil || session.kind == "code" {
                    HStack(spacing: 6) {
                        if let project = session.project { Tag(project) }
                        if session.kind == "code" { Tag("code") }
                    }
                }
                detail
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if session.isWaiting {
            Label("Waiting for your answer", systemImage: "questionmark.bubble")
                .font(.footnote).foregroundStyle(Color.paiWaiting)
        } else if session.isRunning {
            ToolTicker(text: session.lastTool ?? "Thinking…")
        } else if let last = session.lastResult, !last.isEmpty {
            Text(last.paiPlain).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// The running tool as a terminal tail: monospaced, with a block cursor that keeps blinking.
@available(iOS 16.0, *)
struct ToolTicker: View {
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.paiMono).lineLimit(1).foregroundStyle(.primary)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.25), value: text)
            Text("▍").font(.paiMono).foregroundStyle(Color.accentColor).modifier(Breathing())
        }
    }
}

@available(iOS 16.0, *)
struct Tag: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.secondary)
    }
}
