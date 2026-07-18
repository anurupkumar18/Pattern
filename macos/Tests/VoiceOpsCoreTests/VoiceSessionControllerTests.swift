import XCTest
@testable import VoiceOpsCore

/// Scriptable transcriber so session logic is tested without a microphone.
/// The real SFSpeechRecognizer adapter stays thin behind the same protocol.
actor FakeTranscriber: Transcriber {
    private var continuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?
    private(set) var finishCalled = false
    private(set) var cancelCalled = false

    func start() async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        let (stream, continuation) = AsyncThrowingStream<TranscriptUpdate, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func finish() async { finishCalled = true }

    func cancel() async {
        cancelCalled = true
        continuation?.finish()
        continuation = nil
    }

    func emit(_ update: TranscriptUpdate) {
        continuation?.yield(update)
        if update.isFinal {
            continuation?.finish()
            continuation = nil
        }
    }

    func failStream(_ error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}

@MainActor
final class VoiceSessionControllerTests: XCTestCase {
    private func makeFinal(_ text: String) -> TranscriptUpdate {
        TranscriptUpdate(
            text: text, isFinal: true, confidence: 0.9,
            segments: [TranscriptSegment(text: text, startMs: 0, endMs: 900, confidence: 0.9)])
    }

    func testPartialsAreForwardedInOrder() async throws {
        let fake = FakeTranscriber()
        let controller = VoiceSessionController(transcriber: fake, locale: "en-US")
        var partials: [String] = []
        controller.onPartial = { partials.append($0) }

        try await controller.begin()
        await fake.emit(TranscriptUpdate(text: "remind", isFinal: false, confidence: nil, segments: []))
        await fake.emit(TranscriptUpdate(text: "remind me", isFinal: false, confidence: nil, segments: []))
        await fake.emit(makeFinal("remind me tomorrow"))
        _ = try await controller.end()

        XCTAssertEqual(partials, ["remind", "remind me"])
    }

    func testEndReturnsVoiceRequestBuiltFromFinalUpdate() async throws {
        let fake = FakeTranscriber()
        let controller = VoiceSessionController(transcriber: fake, locale: "en-GB")
        try await controller.begin()

        async let request = controller.end()
        await fake.emit(makeFinal("remind me tomorrow"))
        let voiceRequest = try await request

        XCTAssertEqual(voiceRequest.transcript, "remind me tomorrow")
        XCTAssertEqual(voiceRequest.locale, "en-GB")
        XCTAssertEqual(voiceRequest.confidence, 0.9)
        XCTAssertEqual(voiceRequest.segments.count, 1)
        let finishCalled = await fake.finishCalled
        XCTAssertTrue(finishCalled, "end() must ask the transcriber to finalize")
    }

    func testFinalArrivingBeforeEndIsNotLost() async throws {
        let fake = FakeTranscriber()
        let controller = VoiceSessionController(transcriber: fake, locale: "en-US")
        try await controller.begin()

        await fake.emit(makeFinal("done early"))
        try await Task.sleep(for: .milliseconds(50))  // let the consume task store it
        let voiceRequest = try await controller.end()
        XCTAssertEqual(voiceRequest.transcript, "done early")
    }

    func testAutoFinalWithoutEndFiresCallback() async throws {
        // Recognizer can finalize on its own (long pause). The app needs a
        // signal to leave the listening state without a hotkey tap.
        let fake = FakeTranscriber()
        let controller = VoiceSessionController(transcriber: fake, locale: "en-US")
        var autoFinals: [String] = []
        controller.onAutoFinal = { autoFinals.append($0) }
        try await controller.begin()

        await fake.emit(makeFinal("auto ended"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(autoFinals, ["auto ended"])
        _ = try await controller.end()
    }

    func testEndFallsBackToLastPartialWhenFinalNeverArrives() async throws {
        // SFSpeechRecognizer is not guaranteed to deliver a final after
        // endAudio; the session must not hang in planning forever.
        let fake = FakeTranscriber()
        let controller = VoiceSessionController(
            transcriber: fake, locale: "en-US", finalizationTimeout: .milliseconds(100))
        try await controller.begin()
        await fake.emit(TranscriptUpdate(text: "remind me tomorrow", isFinal: false, confidence: nil, segments: []))

        let request = try await controller.end()  // no final ever emitted
        XCTAssertEqual(request.transcript, "remind me tomorrow")
        XCTAssertEqual(request.confidence, 0)
    }

    func testEndThrowsNoSpeechWhenNothingWasHeard() async throws {
        let fake = FakeTranscriber()
        let controller = VoiceSessionController(
            transcriber: fake, locale: "en-US", finalizationTimeout: .milliseconds(100))
        try await controller.begin()
        do {
            _ = try await controller.end()  // no partials, no final
            XCTFail("expected noSpeech")
        } catch VoiceSessionError.noSpeech {
        } catch {
            XCTFail("expected .noSpeech, got \(error)")
        }
    }

    func testCaptureErrorWhileListeningFiresOnError() async throws {
        // A recognizer failure with no end() waiting must reach the app —
        // otherwise the UI sits in "Listening…" forever.
        struct MicFailure: Error {}
        let fake = FakeTranscriber()
        let controller = VoiceSessionController(transcriber: fake, locale: "en-US")
        var errors: [String] = []
        controller.onError = { errors.append(String(describing: $0)) }
        try await controller.begin()

        await fake.failStream(MicFailure())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("MicFailure"), errors[0])
    }

    func testCancelDiscardsSessionAndEndThrows() async throws {
        let fake = FakeTranscriber()
        let controller = VoiceSessionController(transcriber: fake, locale: "en-US")
        try await controller.begin()
        await controller.cancel()

        let cancelCalled = await fake.cancelCalled
        XCTAssertTrue(cancelCalled, "cancel must reach the transcriber")
        do {
            _ = try await controller.end()
            XCTFail("end() after cancel must throw")
        } catch VoiceSessionError.cancelled {
        } catch {
            XCTFail("expected .cancelled, got \(error)")
        }
    }

    func testBeginWhileActiveThrows() async throws {
        let fake = FakeTranscriber()
        let controller = VoiceSessionController(transcriber: fake, locale: "en-US")
        try await controller.begin()
        do {
            try await controller.begin()
            XCTFail("second begin must throw")
        } catch VoiceSessionError.alreadyActive {
        } catch {
            XCTFail("expected .alreadyActive, got \(error)")
        }
    }
}
