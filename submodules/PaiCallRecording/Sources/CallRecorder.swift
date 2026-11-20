import AVFoundation
import Foundation

/// Encodes one call's two tracks (`mic` = me, `remote` = peer) into AAC mono 16 kHz m4a files inside the store.
/// Feed it 16-bit mono PCM chunks at whatever rate the audio device runs; all work happens on its own serial queue.
public final class CallRecorder: @unchecked Sendable {
    public static let sampleRate: Double = 16000

    private static let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: CallRecorder.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32000
    ]

    /// One m4a file plus the converter from the device's int16 PCM to the encoder's input format.
    private final class Track {
        var file: AVAudioFile?
        private var converter: AVAudioConverter?
        private var inputRate: Double = 0
        private(set) var framesWritten: AVAudioFramePosition = 0

        private(set) var bytesReceived = 0
        private(set) var failure: String?

        init(url: URL) throws {
            file = try AVAudioFile(forWriting: url, settings: CallRecorder.fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }

        func append(_ samples: Data, rate: Int) {
            guard let file, rate > 0, samples.count >= 2 else { return }
            bytesReceived += samples.count
            let frameCount = samples.count / 2
            if converter == nil || inputRate != Double(rate) {
                guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: 1, interleaved: false) else { return }
                converter = AVAudioConverter(from: inputFormat, to: file.processingFormat)
                inputRate = Double(rate)
            }
            guard let converter, let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
            input.frameLength = AVAudioFrameCount(frameCount)
            samples.withUnsafeBytes { raw in
                if let source = raw.baseAddress, let destination = input.int16ChannelData?[0] {
                    memcpy(destination, source, frameCount * 2)
                }
            }
            convert(input, endOfStream: false)
        }

        func appendSilence(frames: Int) {
            guard let file, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            if let channel = buffer.floatChannelData?[0] {
                channel.initialize(repeating: 0, count: frames)
            }
            write(buffer)
        }

        func finish() {
            if converter != nil {
                convert(nil, endOfStream: true)
            }
            converter = nil
            file = nil
        }

        private func convert(_ input: AVAudioPCMBuffer?, endOfStream: Bool) {
            guard let converter, let file else { return }
            let ratio = file.processingFormat.sampleRate / converter.inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(input?.frameLength ?? 0) * ratio) + 1024
            var consumed = false
            while true {
                guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return }
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, inputStatus in
                    if !consumed, let input {
                        consumed = true
                        inputStatus.pointee = .haveData
                        return input
                    }
                    inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                    return nil
                }
                if output.frameLength > 0 {
                    write(output)
                }
                if status != .haveData || output.frameLength == 0 {
                    return
                }
            }
        }

        private func write(_ buffer: AVAudioPCMBuffer) {
            guard let file else { return }
            do {
                try file.write(from: buffer)
                framesWritten += AVAudioFramePosition(buffer.frameLength)
            } catch {
                failure = "\(error)"
                self.file = nil
            }
        }
    }

    public let store: CallRecordingStore
    public private(set) var meta: CallRecordingMeta
    private let queue = DispatchQueue(label: "org.paigram.call-recorder")
    private let mic: Track
    private let remote: Track
    private var micMuted = false
    private var finished = false
    private var receivedAudio = false

    public init(store: CallRecordingStore, meta: CallRecordingMeta) throws {
        self.store = store
        self.meta = meta
        try store.create(meta)
        do {
            self.mic = try Track(url: store.micURL(meta.callId))
            self.remote = try Track(url: store.remoteURL(meta.callId))
        } catch {
            store.delete(meta.callId)
            CallRecordingLog.log("recording \(meta.callId): files not created: \(error)")
            throw error
        }
        CallRecordingLog.log("recording \(meta.callId): started (\(meta.direction.rawValue)) in \(store.directory(meta.callId).path)")
    }

    public var callId: String {
        return meta.callId
    }

    /// Chunks of 16-bit mono PCM drained from the audio device; either may be empty.
    public func append(mic micSamples: Data, micRate: Int, remote remoteSamples: Data, remoteRate: Int) {
        queue.async {
            guard !self.finished else { return }
            if !self.receivedAudio {
                self.receivedAudio = true
                CallRecordingLog.log("recording \(self.meta.callId): first audio, mic \(micSamples.count) bytes at \(micRate) Hz, remote \(remoteSamples.count) bytes at \(remoteRate) Hz")
            }
            if !micSamples.isEmpty {
                self.mic.append(self.micMuted ? Data(count: micSamples.count) : micSamples, rate: micRate)
            }
            if !remoteSamples.isEmpty {
                self.remote.append(remoteSamples, rate: remoteRate)
            }
        }
    }

    /// While muted the mic track records silence, so the peer's track keeps its timing and nothing private leaks.
    public func setMicMuted(_ muted: Bool) {
        queue.async {
            self.micMuted = muted
        }
    }

    /// Closes both files and marks the recording finished (ready to upload). Completes on the recorder's queue.
    public func finish(endedAt: Date, completion: @escaping @Sendable (String) -> Void) {
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            for track in [self.mic, self.remote] {
                track.finish()
            }
            let callId = self.meta.callId
            for (name, track) in [("mic", self.mic), ("remote", self.remote)] {
                CallRecordingLog.log("recording \(callId): \(name) got \(track.bytesReceived) bytes, wrote \(track.framesWritten) frames" + (track.failure.map { ", write failed: \($0)" } ?? ""))
            }
            // pai refuses an empty part: a track that never got audio gets one second of silence.
            for (track, url) in [(self.mic, self.store.micURL(self.meta.callId)), (self.remote, self.store.remoteURL(self.meta.callId))] where track.framesWritten == 0 {
                if let fresh = try? Track(url: url) {
                    fresh.appendSilence(frames: Int(CallRecorder.sampleRate))
                    fresh.finish()
                }
            }
            self.meta.endedAt = CallRecordingMeta.isoString(endedAt)
            do {
                try self.store.writeMeta(self.meta)
            } catch {
                CallRecordingLog.log("recording \(callId): meta not written: \(error)")
            }
            let size: (URL) -> Int = { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0 }
            CallRecordingLog.log("recording \(callId): finished, mic.m4a \(size(self.store.micURL(callId))) bytes, remote.m4a \(size(self.store.remoteURL(callId))) bytes")
            completion(callId)
        }
    }
}
