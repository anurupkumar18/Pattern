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
    /// Fired when the provider finalizes on its own (e.g. a long pause) while
    /// no end() call is waiting — the app uses this to leave listening state.
    public var onAutoFinal: ((String) -> Void)?
    /// Fired when capture fails while no end() call is waiting — without this
    /// the app would sit in listening state with a dead microphone.
    public var onError: ((Error) -> Void)?

    private let finalizationTimeout: Duration
    private var consumeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var storedFinal: TranscriptUpdate?
    private var lastPartial = ""
    private var pendingEnd: CheckedContinuation<TranscriptUpdate, Error>?
    private var isActive = false
    private var isCancelled = false

    public init(
        transcriber: any Transcriber,
        locale: String,
        finalizationTimeout: Duration = .seconds(2.5)
    ) {
        self.transcriber = transcriber
        self.locale = locale
        self.finalizationTimeout = finalizationTimeout
    }

    public func begin() async throws {
        guard !isActive else { throw VoiceSessionError.alreadyActive }
        isActive = true
        isCancelled = false
        storedFinal = nil
        lastPartial = ""

        let stream = try await transcriber.start()
        consumeTask = Task { [weak self] in
            // Inherits the MainActor context, so handle/streamEnded never hop.
            do {
                for try await update in stream {
                    self?.handle(update)
                }
                self?.streamEnded(error: nil)
            } catch {
                self?.streamEnded(error: error)
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
        // The final may have arrived during the suspension above.
        if let final = storedFinal {
            finishSession()
            return buildRequest(from: final)
        }
        let final = try await withCheckedThrowingContinuation { continuation in
            pendingEnd = continuation
            // Providers are not guaranteed to deliver a final after finish()
            // (SFSpeechRecognizer notoriously). Fall back to the last partial.
            timeoutTask = Task { [weak self, finalizationTimeout] in
                try? await Task.sleep(for: finalizationTimeout)
                guard !Task.isCancelled else { return }
                self?.finalizationTimedOut()
            }
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
                onAutoFinal?(update.text)
            }
        } else {
            lastPartial = update.text
            onPartial?(update.text)
        }
    }

    private func finalizationTimedOut() {
        guard let pendingEnd else { return }
        self.pendingEnd = nil
        if lastPartial.isEmpty {
            pendingEnd.resume(throwing: VoiceSessionError.noSpeech)
        } else {
            pendingEnd.resume(returning: TranscriptUpdate(
                text: lastPartial, isFinal: true, confidence: nil, segments: []))
        }
    }

    private func streamEnded(error: Error?) {
        guard let pendingEnd else {
            if let error, !isCancelled, storedFinal == nil {
                onError?(error)
            }
            return
        }
        self.pendingEnd = nil
        if let final = storedFinal {
            pendingEnd.resume(returning: final)
        } else if isCancelled {
            pendingEnd.resume(throwing: VoiceSessionError.cancelled)
        } else if !lastPartial.isEmpty {
            // Some providers close with a finalization error after already
            // streaming usable words. Preserve the user-visible transcript
            // exactly as the timeout path does instead of discarding it.
            pendingEnd.resume(returning: TranscriptUpdate(
                text: lastPartial, isFinal: true, confidence: nil, segments: []))
        } else {
            // With no final or partial, the task has no usable voice request.
            // Normalize provider-specific "no speech" failures so the app can
            // give one actionable message rather than leaking opaque NSError text.
            pendingEnd.resume(throwing: VoiceSessionError.noSpeech)
        }
    }

    private func finishSession() {
        isActive = false
        consumeTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func buildRequest(from final: TranscriptUpdate) -> VoiceRequest {
        VoiceRequest(
            transcript: final.text,
            locale: locale,
            confidence: final.confidence ?? 0,
            segments: final.segments)
    }
}
