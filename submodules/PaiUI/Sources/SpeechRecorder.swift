import AVFoundation
import Foundation
import Speech

public struct SpeechError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Dictation on the device without picking a language first: the microphone feeds one recognizer
/// per language at the same time, and the transcript is whichever one is most sure of itself.
@MainActor
public final class SpeechRecorder: ObservableObject {
    @Published public private(set) var transcript = ""
    @Published public private(set) var isRecording = false
    @Published public private(set) var level: Float = 0

    public static let languages = ["en-US", "ru-RU", "uk-UA"]

    private struct Candidate {
        var text = ""
        var confidence: Float = 0
        var isFinal = false
    }

    private final class Listener {
        let recognizer: SFSpeechRecognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
        init(recognizer: SFSpeechRecognizer) { self.recognizer = recognizer }
    }

    private let engine = AVAudioEngine()
    private var listeners: [String: Listener] = [:]
    private var candidates: [String: Candidate] = [:]

    public init() {}

    public func start() async throws {
        guard !isRecording else { return }
        guard await Self.authorized() else { throw SpeechError(message: "Allow microphone and speech recognition in Settings") }
        let recognizers = Self.languages.compactMap { id -> (String, SFSpeechRecognizer)? in
            guard let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable else { return nil }
            return (id, r)
        }
        guard !recognizers.isEmpty else { throw SpeechError(message: "Speech recognition is not available right now") }

        transcript = ""
        candidates = [:]
        listeners = Dictionary(uniqueKeysWithValues: recognizers.map { ($0.0, Listener(recognizer: $0.1)) })
        for listener in listeners.values { listener.request.shouldReportPartialResults = true }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let requests = listeners.values.map(\.request)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            for request in requests { request.append(buffer) }
            let rms = Self.rms(buffer)
            Task { @MainActor in self?.level = rms }
        }
        engine.prepare()
        try engine.start()
        isRecording = true

        for (language, listener) in listeners {
            listener.task = listener.recognizer.recognitionTask(with: listener.request) { [weak self] result, _ in
                guard let result else { return }
                let text = result.bestTranscription.formattedString
                let segments = result.bestTranscription.segments
                let confidence = segments.isEmpty ? 0 : segments.map(\.confidence).reduce(0, +) / Float(segments.count)
                Task { @MainActor in self?.update(language, Candidate(text: text, confidence: confidence, isFinal: result.isFinal)) }
            }
        }
    }

    /// Stops listening; the transcript settles on the most confident language once the final results are in.
    public func stop() async {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        for listener in listeners.values { listener.request.endAudio() }
        isRecording = false
        level = 0
        // Final results carry the confidences; give the recognizers a moment to deliver them.
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, candidates.values.contains(where: { !$0.isFinal && !$0.text.isEmpty }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        for listener in listeners.values { listener.task?.cancel() }
        listeners = [:]
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func update(_ language: String, _ candidate: Candidate) {
        candidates[language] = candidate
        transcript = Self.best(candidates)
    }

    /// Partial results have no confidence yet, so until the end the longest text wins; then confidence does.
    private static func best(_ candidates: [String: Candidate]) -> String {
        let scored = candidates.values.filter { !$0.text.isEmpty }
        if scored.allSatisfy({ $0.confidence == 0 }) {
            return scored.max { $0.text.count < $1.text.count }?.text ?? ""
        }
        return scored.max { $0.confidence < $1.confidence }?.text ?? ""
    }

    private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard speech == .authorized else { return false }
        return await withCheckedContinuation { c in AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) } }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return min(1, sqrt(sum / Float(n)) * 8)
    }
}
