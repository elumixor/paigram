import AVFoundation
import Foundation

/// A call's sound: the microphone through Apple's voice processing (echo cancellation, so the agent never hears
/// itself on the speaker) as 24 kHz mono PCM16 chunks of ~100 ms, and the agent's voice played in order, flushable
/// the moment the user cuts in. The audio session is the caller's (CallKit activates it); this only runs the engine.
final class PaiCallAudio {
    static let sampleRate: Double = 24000
    /// 100 ms of 16-bit mono at 24 kHz.
    private static let chunkBytes = 4800

    /// Called on the audio thread with each chunk of microphone audio.
    var onCapture: ((Data) -> Void)?

    private let lock = NSLock()
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private var pending = Data()
    private var running = false
    private var mutedFlag = false
    private var configObserver: NSObjectProtocol?
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: PaiCallAudio.sampleRate, channels: 1)!
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: PaiCallAudio.sampleRate, channels: 1, interleaved: true)!

    var isRunning: Bool { running }

    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return mutedFlag }
        set { lock.lock(); mutedFlag = newValue; pending.removeAll(); lock.unlock() }
    }

    /// The category a call needs: both ways, the voice-chat mode (Apple's echo canceller), Bluetooth headsets for
    /// AirPods, the loudspeaker when nothing else is connected.
    static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
        try? session.setPreferredIOBufferDuration(0.02)
    }

    func start() throws {
        guard !running else { return }
        try build()
        running = true
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            // A route change (AirPods in or out) stops the engine and can change the input's format: build it again.
            guard let self, self.running, (note.object as AnyObject?) === self.engine else { return }
            self.teardownEngine()
            try? self.build()
        }
    }

    func stop() {
        guard running else { return }
        running = false
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        teardownEngine()
    }

    private func build() throws {
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw PaiClientError(message: "No microphone")
        }
        // Voice processing can report several input channels; the first one is the processed voice.
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate, channels: 1, interleaved: false)!
        monoFormat = mono
        converter = AVAudioConverter(from: mono, to: wireFormat)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inFormat.sampleRate / 20), format: inFormat) { [weak self] buffer, _ in
            self?.captured(buffer)
        }
        engine.prepare()
        try engine.start()
        player.play()
    }

    private func teardownEngine() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        lock.lock()
        pending.removeAll()
        lock.unlock()
    }

    private func captured(_ buffer: AVAudioPCMBuffer) {
        guard !muted, let converter, let mono = monoFormat, let source = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength), let target = monoBuffer.floatChannelData else { return }
        monoBuffer.frameLength = buffer.frameLength
        memcpy(target[0], source[0], Int(buffer.frameLength) * MemoryLayout<Float>.size)

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * wireFormat.sampleRate / mono.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return monoBuffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
        let data = Data(bytes: samples[0], count: Int(out.frameLength) * 2)

        lock.lock()
        pending.append(data)
        var chunks: [Data] = []
        while pending.count >= Self.chunkBytes {
            chunks.append(Data(pending.prefix(Self.chunkBytes)))
            pending = Data(pending.dropFirst(Self.chunkBytes))
        }
        lock.unlock()
        for chunk in chunks { onCapture?(chunk) }
    }

    /// Queues a chunk of the agent's voice (PCM16LE mono 24 kHz) after whatever is already playing.
    func play(_ data: Data) {
        guard running else { return }
        let frames = data.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)), let target = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<frames {
                let sample = Int16(littleEndian: base.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                target[0][i] = Float(sample) / 32768.0
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    /// The user cut in: everything queued goes, now.
    func flush() {
        guard running else { return }
        player.stop()
        player.play()
    }
}
