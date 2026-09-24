import SwiftUI

/// Text or dictation in, one message out. Dictation fills the field live; stopping it sends.
@available(iOS 16.0, *)
struct Composer: View {
    let placeholder: String
    let isBusy: Bool
    let onSend: (String) -> Void
    let onStop: (() -> Void)?

    @EnvironmentObject private var settings: PaiSettings
    @StateObject private var recorder = SpeechRecorder()
    @State private var text = ""
    @State private var speechError: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if let speechError {
                Text(speechError).font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                field
                trailing
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: recorder.transcript) { text = $0 }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if recorder.isRecording {
                LevelMeter(level: recorder.level).frame(width: 18, height: 18).padding(.bottom, 6)
            }
            TextField(recorder.isRecording ? "Listening…" : placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.vertical, 8)
        }
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(recorder.isRecording ? Color.paiRecording : .clear, lineWidth: 1.5))
    }

    @ViewBuilder private var trailing: some View {
        if recorder.isRecording {
            IconButton(symbol: "xmark", tint: .secondary, action: cancelRecording)
            IconButton(symbol: "arrow.up", tint: .white, fill: Color.paiRecording, action: stopRecordingAndSend)
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            IconButton(symbol: "arrow.up", tint: .white, fill: .accentColor, action: send)
        } else if isBusy, let onStop {
            IconButton(symbol: "stop.fill", tint: .secondary, action: onStop)
            IconButton(symbol: "mic.fill", tint: .accentColor, action: startRecording)
        } else {
            IconButton(symbol: "mic.fill", tint: .accentColor, action: startRecording)
        }
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        text = ""
        onSend(message)
    }

    private func startRecording() {
        focused = false
        speechError = nil
        Task {
            do { try await recorder.start(locale: Locale(identifier: settings.speechLocale)) } catch { speechError = error.localizedDescription }
        }
    }

    private func stopRecordingAndSend() {
        recorder.stop()
        // The recognizer may still deliver its last words right after the tap is removed.
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            text = recorder.transcript
            send()
        }
    }

    private func cancelRecording() {
        recorder.stop()
        text = ""
    }
}

@available(iOS 16.0, *)
struct IconButton: View {
    let symbol: String
    var tint: Color = .accentColor
    var fill: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(fill ?? Color(.secondarySystemBackground), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A bar that follows the microphone level.
@available(iOS 16.0, *)
struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            let bars = 3
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let phase = CGFloat(i) / CGFloat(bars)
                    Capsule().fill(Color.paiRecording)
                        .frame(height: max(4, geo.size.height * CGFloat(min(1, max(0, level - Float(phase) * 0.35 + 0.35)))))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.linear(duration: 0.08), value: level)
        }
    }
}
