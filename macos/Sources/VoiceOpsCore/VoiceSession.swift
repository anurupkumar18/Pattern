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

/// Keeps one VoiceSessionController alive across a provider outage. The
/// primary transcript prefix is retained when capture switches providers, so
/// a network hiccup never silently restarts the spoken command.
public final class FailoverTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private let primary: any Transcriber
    private let fallback: any Transcriber
    private let onFailover: @Sendable (Error) -> Void
    private var active: (any Transcriber)?
    private var bridgeTask: Task<Void, Never>?
    private var cancelled = false
    private var finishRequested = false
    private var primaryPrefix = ""

    public init(
        primary: any Transcriber,
        fallback: any Transcriber,
        onFailover: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        self.primary = primary
        self.fallback = fallback
        self.onFailover = onFailover
    }

    public enum FailoverError: Error, LocalizedError {
        case primaryStreamEnded

        public var errorDescription: String? {
            "The primary voice stream ended before final transcription."
        }
    }

    public func start() async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        lock.withLock {
            cancelled = false
            finishRequested = false
            primaryPrefix = ""
            active = nil
        }
        let (output, continuation) = AsyncThrowingStream<TranscriptUpdate, Error>.makeStream()
        do {
            let stream = try await primary.start()
            let shouldFinish = lock.withLock {
                active = primary
                return finishRequested
            }
            if shouldFinish { await primary.finish() }
            bridgeTask = Task { [weak self] in
                await self?.consumePrimary(stream, output: continuation)
            }
        } catch {
            onFailover(error)
            let stream = try await fallback.start()
            let shouldFinish = lock.withLock {
                active = fallback
                return finishRequested
            }
            if shouldFinish { await fallback.finish() }
            bridgeTask = Task { [weak self] in
                await self?.consumeFallback(stream, output: continuation, prefix: "")
            }
        }
        return output
    }

    public func finish() async {
        let transcriber = lock.withLock {
            finishRequested = true
            return active
        }
        await transcriber?.finish()
    }

    public func cancel() async {
        let transcriber = lock.withLock {
            cancelled = true
            return active
        }
        bridgeTask?.cancel()
        await transcriber?.cancel()
    }

    private func consumePrimary(
        _ stream: AsyncThrowingStream<TranscriptUpdate, Error>,
        output: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation
    ) async {
        var sawFinal = false
        do {
            for try await update in stream {
                if Task.isCancelled { return }
                lock.withLock { primaryPrefix = update.text }
                output.yield(update)
                sawFinal = update.isFinal
            }
            if sawFinal || lock.withLock({ finishRequested || cancelled }) {
                output.finish()
                return
            }
            try await switchToFallback(
                because: FailoverError.primaryStreamEnded, output: output)
        } catch {
            if lock.withLock({ finishRequested || cancelled }) {
                output.finish(throwing: error)
                return
            }
            do {
                try await switchToFallback(because: error, output: output)
            } catch {
                output.finish(throwing: error)
            }
        }
    }

    private func switchToFallback(
        because error: Error,
        output: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation
    ) async throws {
        await primary.cancel()
        onFailover(error)
        let prefix = lock.withLock { primaryPrefix }
        let stream = try await fallback.start()
        let shouldFinish = lock.withLock {
            active = fallback
            return finishRequested
        }
        if shouldFinish { await fallback.finish() }
        await consumeFallback(stream, output: output, prefix: prefix)
    }

    private func consumeFallback(
        _ stream: AsyncThrowingStream<TranscriptUpdate, Error>,
        output: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation,
        prefix: String
    ) async {
        do {
            for try await update in stream {
                if Task.isCancelled { return }
                let combined = [prefix, update.text]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                output.yield(TranscriptUpdate(
                    text: combined,
                    isFinal: update.isFinal,
                    confidence: update.confidence,
                    // Segment timings restart with the fallback microphone;
                    // do not publish misleading offsets across the handoff.
                    segments: prefix.isEmpty ? update.segments : []))
            }
            output.finish()
        } catch {
            output.finish(throwing: error)
        }
    }
}
