@preconcurrency import AVFoundation
import Foundation
import VoiceOpsCore

/// Full-duplex audio boundary for the conversational Realtime session. One
/// engine owns capture and playback so voice processing can cancel speaker echo
/// before server VAD sees it.
final class ConversationAudioIO: @unchecked Sendable {
    enum AudioError: Error, LocalizedError {
        case noAudioInput
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .noAudioInput: "No usable audio input device was found."
            case .conversionFailed: "Conversation audio could not be converted to 24 kHz PCM."
            }
        }
    }

    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Int
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var onPCM: (@Sendable (Data) -> Void)?
    private var tapInstalled = false

    init(sampleRate: Int = 24_000) {
        self.sampleRate = sampleRate
    }

    func start(onPCM: @escaping @Sendable (Data) -> Void) throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.noAudioInput
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target)
        else { throw AudioError.conversionFailed }

        if !engine.attachedNodes.contains(player) { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: target)
        lock.withLock {
            self.converter = converter
            self.targetFormat = target
            self.onPCM = onPCM
        }
        input.installTap(onBus: 0, bufferSize: 2_400, format: inputFormat) {
            [weak self] buffer, _ in self?.consume(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    func enqueue(_ pcm16: Data) {
        guard !pcm16.isEmpty, pcm16.count.isMultiple(of: 2),
              let format = lock.withLock({ targetFormat })
        else { return }
        let frames = AVAudioFrameCount(pcm16.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.int16ChannelData?.pointee
        else { return }
        pcm16.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            memcpy(channel, source, pcm16.count)
        }
        buffer.frameLength = frames
        lock.withLock {
            player.scheduleBuffer(buffer)
            if !player.isPlaying { player.play() }
        }
    }

    /// Barge-in must discard already-scheduled speech immediately.
    func stopPlayback() {
        lock.withLock { player.stop() }
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        stopPlayback()
        lock.withLock {
            converter = nil
            targetFormat = nil
            onPCM = nil
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        let state = lock.withLock { (converter, targetFormat, onPCM) }
        guard let converter = state.0, let target = state.1, let onPCM = state.2
        else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 8
        guard let output = AVAudioPCMBuffer(
            pcmFormat: target, frameCapacity: max(1, capacity))
        else { return }
        let source = ConversationConverterInput(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) {
            _, inputStatus in source.next(inputStatus)
        }
        guard status != .error, conversionError == nil, output.frameLength > 0,
              let samples = output.int16ChannelData?.pointee
        else { return }
        onPCM(Data(
            bytes: samples,
            count: Int(output.frameLength) * MemoryLayout<Int16>.size))
    }
}

private final class ConversationConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(
        _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.withLock {
            guard let buffer else {
                status.pointee = .noDataNow
                return nil
            }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }
}
