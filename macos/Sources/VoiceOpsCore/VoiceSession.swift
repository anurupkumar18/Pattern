import Foundation

/// One transcription update from any speech provider (ARD §2: provider
/// adapters, not provider-specific logic). Finals carry confidence + segments.
public struct TranscriptUpdate: Equatable, Sendable {
    public let text: String
    public let isFinal: Bool
    public let confidence: Double?
    public let segments: [TranscriptSegment]

    public init(text: String, isFinal: Bool, confidence: Double?, segments: [TranscriptSegment]) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.segments = segments
    }
}

public protocol Transcriber: Sendable {
    /// Begin capture; the stream ends after the final update (or cancel).
    func start() async throws -> AsyncThrowingStream<TranscriptUpdate, Error>
    /// Stop capture and ask for the final result.
    func finish() async
    /// Tear down without producing a final result.
    func cancel() async
}

public enum VoiceSessionError: Error, Equatable {
    case alreadyActive
    case notStarted
    case cancelled
    case noSpeech
}

/// ARD §4.1 VoiceSessionController: owns one capture session and turns the
/// transcriber's stream into a wire-ready VoiceRequest.
@MainActor
public final class VoiceSessionController {
    private let transcriber: any Transcriber
    private let locale: String

    public var onPartial: ((String) -> Void)?

    private var consumeTask: Task<Void, Never>?
    private var storedFinal: TranscriptUpdate?
    private var pendingEnd: CheckedContinuation<TranscriptUpdate, Error>?
    private var isActive = false
    private var isCancelled = false

    public init(transcriber: any Transcriber, locale: String) {
        self.transcriber = transcriber
        self.locale = locale
    }

    public func begin() async throws {
        guard !isActive else { throw VoiceSessionError.alreadyActive }
        isActive = true
        isCancelled = false
        storedFinal = nil

        let stream = try await transcriber.start()
        consumeTask = Task { [weak self] in
            do {
                for try await update in stream {
                    await self?.handle(update)
                }
                await self?.streamEnded(error: nil)
            } catch {
                await self?.streamEnded(error: error)
            }
        }
    }

    public func end() async throws -> VoiceRequest {
        if isCancelled { throw VoiceSessionError.cancelled }
        guard isActive else { throw VoiceSessionError.notStarted }

        if let final = storedFinal {
            finishSession()
            return buildRequest(from: final)
        }

        await transcriber.finish()
        let final = try await withCheckedThrowingContinuation { continuation in
            pendingEnd = continuation
        }
        finishSession()
        return buildRequest(from: final)
    }

    public func cancel() async {
        guard isActive else { return }
        isCancelled = true
        await transcriber.cancel()
        consumeTask?.cancel()
        pendingEnd?.resume(throwing: VoiceSessionError.cancelled)
        pendingEnd = nil
        finishSession()
    }

    private func handle(_ update: TranscriptUpdate) {
        guard !isCancelled else { return }
        if update.isFinal {
            if let pendingEnd {
                self.pendingEnd = nil
                pendingEnd.resume(returning: update)
            } else {
                storedFinal = update
            }
        } else {
            onPartial?(update.text)
        }
    }

    private func streamEnded(error: Error?) {
        guard let pendingEnd else { return }
        self.pendingEnd = nil
        if isCancelled {
            pendingEnd.resume(throwing: VoiceSessionError.cancelled)
        } else {
            pendingEnd.resume(throwing: error ?? VoiceSessionError.noSpeech)
        }
    }

    private func finishSession() {
        isActive = false
        consumeTask = nil
    }

    private func buildRequest(from final: TranscriptUpdate) -> VoiceRequest {
        VoiceRequest(
            transcript: final.text,
            locale: locale,
            confidence: final.confidence ?? 0,
            segments: final.segments)
    }
}
