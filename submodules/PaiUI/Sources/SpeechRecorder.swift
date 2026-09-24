import AVFoundation
import Foundation
import Speech

public struct SpeechError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Dictation on the device: the microphone goes to `SFSpeechRecognizer`, the text comes back as it forms.
@MainActor
public final class SpeechRecorder: ObservableObject {
    @Published public private(set) var transcript = ""
    @Published public private(set) var isRecording = false
    @Published public private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    public init() {}

    public func start(locale: Locale) async throws {
        guard !isRecording else { return }
        guard await Self.authorized() else { throw SpeechError(message: "Allow microphone and speech recognition in Settings") }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechError(message: "Speech recognition is not available for \(locale.identifier)")
        }
        self.recognizer = recognizer
        transcript = ""

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = false }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let rms = Self.rms(buffer)
            Task { @MainActor in self?.level = rms }
        }
        engine.prepare()
        try engine.start()
        isRecording = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true { self.tearDown() }
            }
        }
    }

    /// Stops listening; the transcript stays until the next start.
    public func stop() {
        guard isRecording else { return }
        request?.endAudio()
        tearDown()
    }

    private func tearDown() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
