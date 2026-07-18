@preconcurrency import AVFoundation
import Foundation
import Speech
import VoiceOpsCore
import os

private let log = Logger(subsystem: "com.voiceops.VoiceOps", category: "speech")

/// System speech adapter (ARD §2: zero-setup STT for the MVP). Thin by design:
/// session logic lives in VoiceOpsCore.VoiceSessionController and is tested
/// against a fake; this file only bridges SFSpeechRecognizer + AVAudioEngine
/// into the Transcriber protocol.
///
/// SFSpeechRecognizer finalizes on its own after short pauses. Those internal
/// finals are treated as segment boundaries: the text is committed, a fresh
/// recognition task continues listening, and partials always carry the full
/// accumulated transcript. Only finish() produces the session-final update.
public final class SpeechTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?
    private var committedText = ""
    private var committedSegments: [TranscriptSegment] = []
    private var segmentOffsetMs = 0
    private var finishRequested = false
    private var restartCount = 0

    public init() {}

    public enum SpeechError: Error, LocalizedError {
        case speechRecognitionDenied
        case microphoneDenied
        case recognizerUnavailable
        case noAudioInput

        public var errorDescription: String? {
            switch self {
            case .speechRecognitionDenied: "Speech recognition permission was denied."
            case .microphoneDenied: "Microphone permission was denied."
            case .recognizerUnavailable: "Speech recognition is unavailable for the current locale."
            case .noAudioInput: "No usable audio input device was found."
            }
        }
    }

    public static func requestPermissions() async -> Bool {
        let speech = await requestSpeechPermission()
        guard speech else { return false }
        return await requestMicrophonePermission()
    }

    public static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        } == .authorized
    }

    public static func requestMicrophonePermission() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            return true
        }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func start() async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        log.info("mic auth: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue), speech auth: \(SFSpeechRecognizer.authorizationStatus().rawValue)")
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable
        else {
            log.error("recognizer unavailable for locale \(Locale.current.identifier)")
            throw SpeechError.recognizerUnavailable
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        log.info("input format: \(format.sampleRate) Hz, \(format.channelCount) ch")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            log.error("no usable audio input")
            throw SpeechError.noAudioInput
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.lock.withLock { self?.request }?.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        let (stream, continuation) = AsyncThrowingStream<TranscriptUpdate, Error>.makeStream()
        lock.withLock {
            self.recognizer = recognizer
            self.continuation = continuation
            self.committedText = ""
            self.committedSegments = []
            self.segmentOffsetMs = 0
            self.finishRequested = false
            self.restartCount = 0
        }
        startRecognitionSegment()
        return stream
    }

    public func finish() async {
        lock.withLock { finishRequested = true }
        stopAudio()
        // Recognizer delivers the final result after audio ends.
        lock.withLock { request }?.endAudio()
    }

    public func cancel() async {
        stopAudio()
        let (task, continuation) = lock.withLock {
            defer {
                self.task = nil
                self.request = nil
                self.continuation = nil
            }
            return (self.task, self.continuation)
        }
        task?.cancel()
        continuation?.finish()
    }

    /// One recognizer task per speech segment; restarted after every internal final.
    private func startRecognitionSegment() {
        guard let recognizer = lock.withLock({ self.recognizer }) else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        lock.withLock { self.request = request }
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
        lock.withLock { self.task = task }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let transcription = result.bestTranscription
            let offset = lock.withLock { segmentOffsetMs }
            let segments = transcription.segments.map { segment in
                TranscriptSegment(
                    text: segment.substring,
                    startMs: offset + Int(segment.timestamp * 1000),
                    endMs: offset + Int((segment.timestamp + segment.duration) * 1000),
                    confidence: Double(segment.confidence))
            }
            let (continuation, joined, allSegments, isSessionFinal) = lock.withLock {
                () -> (AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?, String, [TranscriptSegment], Bool) in
                let joined = [committedText, transcription.formattedString]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                return (self.continuation, joined, committedSegments + segments, finishRequested && result.isFinal)
            }
            guard let continuation else { return }

            if isSessionFinal {
                log.info("session final: \(joined, privacy: .private)")
                let confidence = allSegments.isEmpty
                    ? 0 : allSegments.map(\.confidence).reduce(0, +) / Double(allSegments.count)
                lock.withLock {
                    self.continuation = nil
                    self.task = nil
                    self.request = nil
                }
                continuation.yield(TranscriptUpdate(
                    text: joined, isFinal: true, confidence: confidence, segments: allSegments))
                continuation.finish()
            } else if result.isFinal {
                // Internal pause boundary: commit and keep listening.
                log.debug("segment committed, continuing to listen")
                lock.withLock {
                    committedText = joined
                    committedSegments += segments
                    segmentOffsetMs = committedSegments.last?.endMs ?? segmentOffsetMs
                }
                continuation.yield(TranscriptUpdate(
                    text: joined, isFinal: false, confidence: nil, segments: []))
                startRecognitionSegment()
            } else {
                continuation.yield(TranscriptUpdate(
                    text: joined, isFinal: false, confidence: nil, segments: []))
            }
        } else if let error {
            let (finishRequested, restarts) = lock.withLock {
                restartCount += 1
                return (self.finishRequested, restartCount)
            }
            // Silence and per-utterance hiccups are normal while listening;
            // restart unless the session is ending or errors are runaway.
            if !finishRequested && restarts <= 10 {
                log.info("recognition segment error (restart \(restarts)): \(error.localizedDescription)")
                startRecognitionSegment()
                return
            }
            log.error("recognition failed: \(error.localizedDescription)")
            let continuation = lock.withLock {
                defer {
                    self.continuation = nil
                    self.task = nil
                    self.request = nil
                }
                return self.continuation
            }
            // A failure after finish() with words already accumulated is a
            // usable result, not an error — surface what we heard.
            let committed = lock.withLock { (committedText, committedSegments) }
            if finishRequested, !committed.0.isEmpty {
                continuation?.yield(TranscriptUpdate(
                    text: committed.0, isFinal: true, confidence: 0, segments: committed.1))
                continuation?.finish()
            } else {
                continuation?.finish(throwing: error)
            }
        }
    }

    private func stopAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }
}

/// OpenAI's transcription-only Realtime WebSocket. It streams 24 kHz mono
/// PCM16 and manually commits on the same hotkey that ends capture, keeping
/// VoiceOps—not server VAD—in control of task boundaries.
public final class OpenAIRealtimeTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private let audioEngine = AVAudioEngine()
    private let apiKey: String
    private let configuration: RealtimeTranscriptionConfiguration
    private let session: URLSession

    private var socket: URLSessionWebSocketTask?
    private var outputContinuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?
    private var readyContinuation: AsyncThrowingStream<Void, Error>.Continuation?
    private var audioContinuation: AsyncStream<Data>.Continuation?
    private var senderTask: Task<Void, Never>?
    private var receiverTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var transcript = ""
    private var finishRequested = false
    private var cancelled = false
    private var tapInstalled = false

    public init(
        apiKey: String,
        configuration: RealtimeTranscriptionConfiguration = .init(),
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.apiKey = apiKey
        self.configuration = configuration
        self.session = session
    }

    public enum RealtimeError: Error, LocalizedError {
        case invalidCredential
        case noAudioInput
        case conversionFailed
        case invalidSocketMessage
        case connectionTimedOut
        case server(String)

        public var errorDescription: String? {
            switch self {
            case .invalidCredential: "The OpenAI API credential is empty."
            case .noAudioInput: "No usable audio input device was found."
            case .conversionFailed: "Microphone audio could not be converted to 24 kHz PCM."
            case .invalidSocketMessage: "OpenAI Realtime returned an unreadable socket message."
            case .connectionTimedOut: "OpenAI Realtime did not become ready before the timeout."
            case .server(let message): "OpenAI Realtime: \(message)"
            }
        }
    }

    public func start() async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RealtimeError.invalidCredential
        }
        guard let url = URL(string:
            "wss://api.openai.com/v1/realtime?model=\(configuration.model)"),
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(configuration.sampleRate),
                channels: 1,
                interleaved: true)
        else { throw RealtimeError.conversionFailed }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else { throw RealtimeError.noAudioInput }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let socket = session.webSocketTask(with: request)
        let (output, outputContinuation) = AsyncThrowingStream<TranscriptUpdate, Error>.makeStream()
        let (ready, readyContinuation) = AsyncThrowingStream<Void, Error>.makeStream()
        let (audio, audioContinuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingNewest(240))

        lock.withLock {
            self.socket = socket
            self.outputContinuation = outputContinuation
            self.readyContinuation = readyContinuation
            self.audioContinuation = audioContinuation
            self.converter = converter
            self.outputFormat = targetFormat
            self.transcript = ""
            self.finishRequested = false
            self.cancelled = false
            self.tapInstalled = false
        }

        socket.resume()
        senderTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await socket.send(.string(
                    try RealtimeTranscriptionWire.sessionUpdate(configuration)))
                for await chunk in audio {
                    try Task.checkCancellation()
                    try await socket.send(.string(
                        try RealtimeTranscriptionWire.appendAudio(chunk)))
                }
                if !lock.withLock({ cancelled }) {
                    try await socket.send(.string(
                        try RealtimeTranscriptionWire.commitAudio()))
                }
            } catch {
                fail(error)
            }
        }
        receiverTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let text: String
                    switch message {
                    case .string(let value): text = value
                    case .data(let value):
                        guard let decoded = String(data: value, encoding: .utf8) else {
                            throw RealtimeError.invalidSocketMessage
                        }
                        text = decoded
                    @unknown default:
                        throw RealtimeError.invalidSocketMessage
                    }
                    handle(try RealtimeTranscriptionWire.parseServerEvent(text))
                }
            } catch {
                if !lock.withLock({ cancelled }) { fail(error) }
            }
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var iterator = ready.makeAsyncIterator()
                    guard try await iterator.next() != nil else {
                        throw RealtimeError.invalidSocketMessage
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(8))
                    throw RealtimeError.connectionTimedOut
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            await cancel()
            throw error
        }

        inputNode.installTap(
            onBus: 0, bufferSize: 2_400, format: inputFormat
        ) { [weak self] buffer, _ in
            self?.consumeAudio(buffer)
        }
        lock.withLock { tapInstalled = true }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            await cancel()
            throw error
        }
        return output
    }

    public func finish() async {
        lock.withLock { finishRequested = true }
        stopAudio()
        let continuation = lock.withLock { audioContinuation }
        continuation?.finish()
    }

    public func cancel() async {
        lock.withLock { cancelled = true }
        stopAudio()
        let state = lock.withLock {
            defer {
                outputContinuation = nil
                readyContinuation = nil
                audioContinuation = nil
                socket = nil
            }
            return (outputContinuation, audioContinuation, socket, readyContinuation)
        }
        state.1?.finish()
        state.0?.finish()
        state.3?.finish()
        senderTask?.cancel()
        receiverTask?.cancel()
        state.2?.cancel(with: .goingAway, reason: nil)
    }

    private func consumeAudio(_ buffer: AVAudioPCMBuffer) {
        let converter: AVAudioConverter? = lock.withLock { self.converter }
        let outputFormat: AVAudioFormat? = lock.withLock { self.outputFormat }
        let continuation: AsyncStream<Data>.Continuation? = lock.withLock {
            self.audioContinuation
        }
        guard let converter, let outputFormat, let continuation else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 8
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: max(1, capacity))
        else { return }
        let source = RealtimeConverterInput(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) {
            (_: AVAudioPacketCount,
             inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>)
                -> AVAudioBuffer? in
            source.next(inputStatus)
        }
        guard status != AVAudioConverterOutputStatus.error,
              conversionError == nil,
              output.frameLength > 0,
              let samples = output.int16ChannelData?.pointee
        else {
            fail(conversionError ?? RealtimeError.conversionFailed)
            return
        }
        continuation.yield(Data(
            bytes: samples,
            count: Int(output.frameLength) * MemoryLayout<Int16>.size))
    }

    private func handle(_ event: RealtimeTranscriptionServerEvent) {
        switch event {
        case .delta(_, let text):
            let state = lock.withLock { () -> (String, AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?) in
                transcript += text
                return (transcript, outputContinuation)
            }
            state.1?.yield(TranscriptUpdate(
                text: state.0, isFinal: false, confidence: nil, segments: []))
        case .completed(_, let final):
            let state = lock.withLock {
                () -> (Bool, AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?) in
                transcript = final
                guard finishRequested else { return (false, outputContinuation) }
                let continuation = outputContinuation
                outputContinuation = nil
                return (true, continuation)
            }
            if state.0 {
                state.1?.yield(TranscriptUpdate(
                    text: final, isFinal: true, confidence: nil, segments: []))
                state.1?.finish()
                receiverTask?.cancel()
                socket?.cancel(with: .normalClosure, reason: nil)
            }
        case .error(let message):
            fail(RealtimeError.server(message))
        case .ignored(let type):
            // GA transcription sessions currently acknowledge configuration
            // with session.updated. Accept the typed spelling as well so a
            // server-side event-name refinement cannot strand capture behind
            // the readiness timeout.
            if type == "session.updated" || type == "transcription_session.updated" {
                let continuation = lock.withLock {
                    let value = readyContinuation
                    readyContinuation = nil
                    return value
                }
                continuation?.yield(())
                continuation?.finish()
            }
        }
    }

    private func fail(_ error: Error) {
        let state = lock.withLock {
            let value = outputContinuation
            let ready = readyContinuation
            outputContinuation = nil
            readyContinuation = nil
            return (value, ready)
        }
        state.0?.finish(throwing: error)
        state.1?.finish(throwing: error)
    }

    private func stopAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        let shouldRemoveTap = lock.withLock {
            let value = tapInstalled
            tapInstalled = false
            return value
        }
        if shouldRemoveTap { audioEngine.inputNode.removeTap(onBus: 0) }
    }
}

private final class RealtimeConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

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
