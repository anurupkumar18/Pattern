import AVFoundation
import Foundation
import Speech
import VoiceOpsCore

/// System speech adapter (ARD §2: zero-setup STT for the MVP). Thin by design:
/// session logic lives in VoiceOpsCore.VoiceSessionController and is tested
/// against a fake; this file only bridges SFSpeechRecognizer + AVAudioEngine
/// into the Transcriber protocol.
public final class SpeechTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?

    public init() {}

    public enum SpeechError: Error {
        case speechRecognitionDenied
        case microphoneDenied
        case recognizerUnavailable
    }

    public static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func start() async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable
        else { throw SpeechError.recognizerUnavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        let (stream, continuation) = AsyncThrowingStream<TranscriptUpdate, Error>.makeStream()
        lock.withLock {
            self.recognizer = recognizer
            self.request = request
            self.continuation = continuation
        }

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
        lock.withLock { self.task = task }
        return stream
    }

    public func finish() async {
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

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        if let result {
            let transcription = result.bestTranscription
            let segments = transcription.segments.map { segment in
                TranscriptSegment(
                    text: segment.substring,
                    startMs: Int(segment.timestamp * 1000),
                    endMs: Int((segment.timestamp + segment.duration) * 1000),
                    confidence: Double(segment.confidence))
            }
            let averageConfidence = segments.isEmpty
                ? 0 : segments.map(\.confidence).reduce(0, +) / Double(segments.count)
            let update = TranscriptUpdate(
                text: transcription.formattedString,
                isFinal: result.isFinal,
                confidence: result.isFinal ? averageConfidence : nil,
                segments: result.isFinal ? segments : [])
            continuation.yield(update)
            if result.isFinal {
                self.continuation = nil
                self.task = nil
                self.request = nil
                lock.unlock()
                continuation.finish()
                return
            }
        } else if let error {
            self.continuation = nil
            self.task = nil
            self.request = nil
            lock.unlock()
            continuation.finish(throwing: error)
            return
        }
        lock.unlock()
    }

    private func stopAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }
}
