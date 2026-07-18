import AVFoundation
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
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
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
