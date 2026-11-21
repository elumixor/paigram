import Foundation
import AVFoundation
import NaturalLanguage
import Speech
import SwiftSignalKit

/// Languages Paigram transcribes voice messages in, with their native names.
public let voiceTranscriptionLanguages: [(locale: String, title: String)] = [
    ("uk-UA", "Українська"),
    ("ru-RU", "Русский"),
    ("en-US", "English"),
    ("cs-CZ", "Čeština")
]

public struct LocallyTranscribedAudio {
    public var text: String
    public var locale: String
    public var isFinal: Bool
    /// Speech recognition permission is off and nothing that works without it produced text.
    public var speechPermissionDenied: Bool = false
}

/// Prefix of the temporary audio segments written for detection and chunked recognition.
public let voiceSegmentFilePrefix = "voice-"

/// Deletes voice segments in `directory` last modified more than `maxAge` seconds before `now`.
public func sweepStaleVoiceSegments(in directory: URL, maxAge: TimeInterval = 3600.0, now: Date = Date()) {
    let fileManager = FileManager.default
    guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
        return
    }
    for url in urls where url.lastPathComponent.hasPrefix(voiceSegmentFilePrefix) && url.pathExtension == "caf" {
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            continue
        }
        if now.timeIntervalSince(modified) > maxAge {
            try? fileManager.removeItem(at: url)
        }
    }
}

/// Candidate locales ordered by the app language, then the system languages, then the rest.
public func voiceTranscriptionLocaleOrder(appLanguageCode: String) -> [String] {
    let all = voiceTranscriptionLanguages.map(\.locale)
    var result: [String] = []
    let codes = [appLanguageCode] + Locale.preferredLanguages
    for code in codes {
        let language = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? ""
        if let locale = all.first(where: { $0.hasPrefix(language + "-") }), !result.contains(locale) {
            result.append(locale)
        }
    }
    for locale in all where !result.contains(locale) {
        result.append(locale)
    }
    return result
}

/// Transcribes an AAC/m4a file. Detects the language among `preferredLocales` unless `forcedLocale` is set.
/// Order: iOS 26 SpeechAnalyzer (on-device), else SFSpeechRecognizer on-device, else SFSpeechRecognizer server in chunks.
public func transcribeVoiceAudio(path: String, preferredLocales: [String], forcedLocale: String?) -> Signal<LocallyTranscribedAudio?, NoError> {
    return Signal { subscriber in
        let task = Task {
            let result = await VoiceTranscriber.transcribe(url: URL(fileURLWithPath: path), locales: forcedLocale.map { [$0] } ?? preferredLocales, detect: forcedLocale == nil)
            if !Task.isCancelled {
                subscriber.putNext(result)
                subscriber.putCompletion()
            }
        }
        return ActionDisposable {
            task.cancel()
        }
    }
}

private enum VoiceTranscriber {
    static let detectionDuration: Double = 12.0
    static let serverChunkDuration: Double = 50.0

    struct Candidate {
        var locale: String
        var text: String
        var score: Double
    }

    static func transcribe(url: URL, locales: [String], detect: Bool) async -> LocallyTranscribedAudio? {
        sweepStaleVoiceSegments(in: URL(fileURLWithPath: NSTemporaryDirectory()))
        guard var chosen = locales.first, let duration = audioDuration(url) else {
            return nil
        }
        let authorized = await authorize()

        if detect && authorized && locales.count > 1 {
            let clip = duration <= detectionDuration ? url : writeSegment(of: url, start: 0.0, duration: detectionDuration)
            var best: Candidate?
            if let clip {
                best = await detectLanguage(url: clip, locales: locales)
                if clip != url {
                    try? FileManager.default.removeItem(at: clip)
                }
            }
            if let best {
                chosen = best.locale
                if duration <= detectionDuration {
                    return LocallyTranscribedAudio(text: best.text, locale: chosen, isFinal: true)
                }
            }
        }
        if Task.isCancelled {
            return nil
        }

        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if let text = await analyzerTranscribe(url: url, locale: chosen), !text.isEmpty {
                return LocallyTranscribedAudio(text: text, locale: chosen, isFinal: true)
            }
        }
        #endif

        if !authorized {
            // Apple's server recognition goes through SFSpeechRecognizer too, so nothing is left to try.
            return LocallyTranscribedAudio(text: "", locale: chosen, isFinal: true, speechPermissionDenied: true)
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: chosen)) else {
            return nil
        }
        var text = ""
        if recognizer.supportsOnDeviceRecognition || duration <= serverChunkDuration {
            text = await recognize(url: url, locale: chosen)?.text ?? ""
        } else {
            var start = 0.0
            while start < duration && !Task.isCancelled {
                if let chunk = writeSegment(of: url, start: start, duration: serverChunkDuration) {
                    let part = await recognize(url: chunk, locale: chosen)?.text
                    try? FileManager.default.removeItem(at: chunk)
                    if let part {
                        text = join(text, part)
                    }
                }
                start += serverChunkDuration
            }
        }
        if text.isEmpty {
            return nil
        }
        return LocallyTranscribedAudio(text: text, locale: chosen, isFinal: true)
    }

    // MARK: - Detection

    static func detectLanguage(url: URL, locales: [String]) async -> Candidate? {
        let results = await withTaskGroup(of: (Int, (text: String, confidence: Double)?).self) { group in
            for (index, locale) in locales.enumerated() {
                group.addTask {
                    return (index, await recognize(url: url, locale: locale))
                }
            }
            var results: [(Int, (text: String, confidence: Double)?)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        var best: Candidate?
        for (index, result) in results {
            guard let result, !result.text.isEmpty else {
                continue
            }
            let locale = locales[index]
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(result.text)
            let language = String(locale.prefix(2))
            let probability = recognizer.languageHypotheses(withMaximum: 6)[NLLanguage(rawValue: language)] ?? 0.0
            let orderBonus = 0.05 * Double(locales.count - index) / Double(locales.count)
            let score = result.confidence * (0.3 + 0.7 * probability) + orderBonus
            if best == nil || score > best!.score {
                best = Candidate(locale: locale, text: result.text, score: score)
            }
        }
        return best
    }

    // MARK: - SFSpeechRecognizer

    static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    final class RecognitionState {
        let lock = NSLock()
        var recognizer: SFSpeechRecognizer?
        var task: SFSpeechRecognitionTask?
        var continuation: CheckedContinuation<(text: String, confidence: Double)?, Never>?

        func finish(_ value: (text: String, confidence: Double)?) {
            self.lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            self.lock.unlock()
            continuation?.resume(returning: value)
        }

        func cancel() {
            self.lock.lock()
            let task = self.task
            self.lock.unlock()
            task?.cancel()
            self.finish(nil)
        }
    }

    /// One SFSpeech pass over a file: on-device when the locale supports it, else Apple's server.
    static func recognize(url: URL, locale: String) async -> (text: String, confidence: Double)? {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            return nil
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }

        let state = RecognitionState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.lock.lock()
                state.continuation = continuation
                state.recognizer = recognizer
                state.lock.unlock()
                let task = recognizer.recognitionTask(with: request, resultHandler: { result, error in
                    if let result, result.isFinal {
                        let segments = result.bestTranscription.segments
                        let confidence = segments.isEmpty ? 0.0 : Double(segments.reduce(Float(0.0), { $0 + $1.confidence })) / Double(segments.count)
                        state.finish((result.bestTranscription.formattedString, confidence))
                    } else if error != nil {
                        state.finish(nil)
                    }
                })
                state.lock.lock()
                state.task = task
                state.lock.unlock()
                if Task.isCancelled {
                    state.cancel()
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    // MARK: - SpeechAnalyzer (iOS 26)

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    static func analyzerTranscribe(url: URL, locale: String) async -> String? {
        do {
            let requested = Locale(identifier: locale)
            if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
                let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                let collector = Task {
                    var text = ""
                    for try await result in transcriber.results where result.isFinal {
                        text = join(text, String(result.text.characters))
                    }
                    return text
                }
                try await analyze(url: url, modules: [transcriber], collector: collector)
                return try await collector.value
            } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
                let transcriber = DictationTranscriber(locale: supported, preset: .longDictation)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                let collector = Task {
                    var text = ""
                    for try await result in transcriber.results where result.isFinal {
                        text = join(text, String(result.text.characters))
                    }
                    return text
                }
                try await analyze(url: url, modules: [transcriber], collector: collector)
                return try await collector.value
            } else {
                return nil
            }
        } catch {
            return nil
        }
    }

    @available(iOS 26.0, *)
    static func analyze(url: URL, modules: [any SpeechModule], collector: Task<String, Error>) async throws {
        let analyzer = SpeechAnalyzer(modules: modules)
        let file = try AVAudioFile(forReading: url)
        try await withTaskCancellationHandler {
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } onCancel: {
            collector.cancel()
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }
    }
    #endif

    // MARK: - Audio

    static func audioDuration(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
            return nil
        }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Writes `duration` seconds from `start` to a temporary PCM .caf file.
    static func writeSegment(of url: URL, start: Double, duration: Double) -> URL? {
        do {
            let input = try AVAudioFile(forReading: url)
            let format = input.processingFormat
            let startFrame = AVAudioFramePosition(start * format.sampleRate)
            guard startFrame < input.length else {
                return nil
            }
            input.framePosition = startFrame
            var remaining = AVAudioFrameCount(min(Double(input.length - startFrame), duration * format.sampleRate))
            let outputUrl = URL(fileURLWithPath: NSTemporaryDirectory() + voiceSegmentFilePrefix + "\(UInt64.random(in: 0 ... UInt64.max)).caf")
            let output = try AVAudioFile(forWriting: outputUrl, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            while remaining > 0 {
                let count = min(remaining, 32768)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                    break
                }
                try input.read(into: buffer, frameCount: count)
                if buffer.frameLength == 0 {
                    break
                }
                try output.write(from: buffer)
                remaining -= min(remaining, buffer.frameLength)
            }
            return outputUrl
        } catch {
            return nil
        }
    }

    static func join(_ lhs: String, _ rhs: String) -> String {
        let rhs = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if lhs.isEmpty {
            return rhs
        }
        if rhs.isEmpty {
            return lhs
        }
        return lhs + " " + rhs
    }
}
