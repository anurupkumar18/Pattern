import XCTest
@testable import VoiceOpsCore

/// Contract tests against the shared wire fixture in fixtures/ipc/.
/// The Python suite round-trips the same file; a change that breaks either side
/// is a protocol change and must update both suites plus schemas/.
final class EnvelopeTests: XCTestCase {
    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // VoiceOpsCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // macos
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("fixtures/ipc/voice_final.json")

    private func fixtureData() throws -> Data {
        try Data(contentsOf: Self.fixtureURL)
    }

    private func fixtureObject(mutating mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testDecodesVoiceFinalFixtureIntoTypedPayload() throws {
        let envelope = try Envelope.decode(from: fixtureData())
        XCTAssertEqual(envelope.type, .voiceFinal)
        XCTAssertEqual(envelope.taskID, UUID(uuidString: "B3E9A1C2-6D4F-4A8B-9C0D-1E2F3A4B5C6D"))
        guard case .voiceFinal(let request) = envelope.payload else {
            return XCTFail("expected a voiceFinal payload, got \(envelope.payload)")
        }
        XCTAssertTrue(request.transcript.hasPrefix("Using this email"))
        XCTAssertEqual(request.segments.count, 3)
        XCTAssertEqual(request.locale, "en-US")
    }

    func testRoundTripIsLossless() throws {
        let envelope = try Envelope.decode(from: fixtureData())
        let decodedAgain = try Envelope.decode(from: envelope.encodeWire())
        XCTAssertEqual(envelope, decodedAgain)
    }

    func testRoundTripsVoicePartialPayload() throws {
        let taskID = UUID(uuidString: "B3E9A1C2-6D4F-4A8B-9C0D-1E2F3A4B5C6D")!
        let envelope = Envelope(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            type: .voicePartial,
            taskID: taskID,
            timestamp: Date(timeIntervalSince1970: 1_784_329_200),
            payload: .voicePartial(TranscriptPartial(
                transcript: "Check order eighteen forty-two",
                confidence: 0.97,
                locale: "en-US")))

        let decoded = try Envelope.decode(from: envelope.encodeWire())
        XCTAssertEqual(decoded, envelope)
        guard case .voicePartial(let partial) = decoded.payload else {
            return XCTFail("expected voicePartial payload")
        }
        XCTAssertEqual(partial.transcript, "Check order eighteen forty-two")
        XCTAssertEqual(partial.confidence, 0.97)
        XCTAssertEqual(partial.locale, "en-US")
    }

    func testEncodesPythonCompatibleWireFormat() throws {
        let envelope = try Envelope.decode(from: fixtureData())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: envelope.encodeWire()) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? String, "1.0")
        XCTAssertEqual(object["task_id"] as? String, "b3e9a1c2-6d4f-4a8b-9c0d-1e2f3a4b5c6d")
        XCTAssertEqual(object["timestamp"] as? String, "2026-07-17T22:00:00Z")
    }

    func testRejectsUnknownEventType() throws {
        let data = try fixtureObject { $0["type"] = "voice.telepathy" }
        XCTAssertThrowsError(try Envelope.decode(from: data))
    }

    func testRejectsUnsupportedVersion() throws {
        let data = try fixtureObject { $0["version"] = "2.0" }
        XCTAssertThrowsError(try Envelope.decode(from: data))
    }

    func testNDJSONLineIsSingleLineWithTrailingNewline() throws {
        let envelope = try Envelope.decode(from: fixtureData())
        let line = try envelope.ndjsonLine()
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertFalse(line.dropLast().contains("\n"))
    }

    func testDecodesSidecarPlanReadyAndTaskCompleted() throws {
        // Wire shapes as emitted by voiceops_agent.main.build_mock_plan.
        let planJSON = """
        {"version":"1.0","id":"11111111-2222-4333-8444-555555555555","type":"plan.ready",\
        "task_id":"b3e9a1c2-6d4f-4a8b-9c0d-1e2f3a4b5c6d","timestamp":"2026-07-17T22:00:01Z",\
        "payload":{"goal":"g","summary":"s","steps":[{"id":"step-1","description":"d",\
        "tool":"reminders.create","arguments":{"title":"x"},"preconditions":[],\
        "postconditions":[{"id":"p1","description":"exists","expected":{"title":"x"}}],\
        "risk":"reversible_write","requires_confirmation":false,"fallback_tools":[],\
        "max_attempts":2,"timeout_seconds":30,\
        "verifier":{"kind":"structured","description":"fetch back"}}]}}
        """
        let plan = try Envelope.decode(from: Data(planJSON.utf8))
        guard case .planReady(let taskPlan) = plan.payload else {
            return XCTFail("expected planReady payload")
        }
        XCTAssertEqual(taskPlan.steps.count, 1)
        XCTAssertEqual(taskPlan.steps[0].risk, .reversibleWrite)

        let completedJSON = """
        {"version":"1.0","id":"11111111-2222-4333-8444-555555555556","type":"task.completed",\
        "task_id":"b3e9a1c2-6d4f-4a8b-9c0d-1e2f3a4b5c6d","timestamp":"2026-07-17T22:00:02Z",\
        "payload":{"state":"succeeded","summary":"ok","verification":[{"predicate_id":"p1",\
        "passed":true,"method":"schema_validation","confidence":1.0,"expected":{},\
        "observed":{"steps":1},"evidence_ids":[],"failure_reason":null}]}}
        """
        let completed = try Envelope.decode(from: Data(completedJSON.utf8))
        guard case .taskCompleted(let payload) = completed.payload else {
            return XCTFail("expected taskCompleted payload")
        }
        XCTAssertEqual(payload.state, .succeeded)
        XCTAssertTrue(payload.verification.allSatisfy(\.passed))
    }

    func testRoundTripsObservationAndGroundingPayloads() throws {
        let taskID = UUID(uuidString: "B3E9A1C2-6D4F-4A8B-9C0D-1E2F3A4B5C6D")!
        let candidate = UIElementCandidate(
            id: "deadline", role: "AXStaticText", label: "Deadline",
            value: "July 31, 2026", bounds: .init(x: 10, y: 20, width: 100, height: 20),
            source: .accessibility, confidence: 1, actions: [],
            appBundleID: "com.apple.mail", stableAttributes: ["AXIdentifier": "deadline"])
        let observation = Observation(
            captureID: UUID(), timestamp: Date(timeIntervalSince1970: 1_784_329_200),
            activeApp: AppReference(bundleID: "com.apple.mail", name: "Mail"),
            window: WindowReference(
                title: "Hackathon details", bounds: .init(x: 0, y: 0, width: 900, height: 700)),
            focusedElementID: "deadline", pointer: .init(x: 20, y: 30),
            elements: [candidate], screenshotPath: "file:///tmp/capture.png")
        let observationEnvelope = Envelope(
            type: .observationReady, taskID: taskID, payload: .observationReady(observation))
        XCTAssertEqual(
            try Envelope.decode(from: observationEnvelope.encodeWire()), observationEnvelope)

        let result = GroundingResult(
            references: [ResolvedReference(
                phrase: "that deadline", candidateID: "deadline",
                resolvedText: "July 31, 2026", confidence: 0.99,
                provenance: [
                    "capture_id": .string(observation.captureID.uuidString.lowercased())
                ])],
            adapter: .deterministic)
        let groundingEnvelope = Envelope(
            type: .groundingReady, taskID: taskID, payload: .groundingReady(result))
        XCTAssertEqual(
            try Envelope.decode(from: groundingEnvelope.encodeWire()), groundingEnvelope)
    }

    func testRoundTripsNativeActionAndVerificationPayloads() throws {
        let taskID = UUID(uuidString: "B3E9A1C2-6D4F-4A8B-9C0D-1E2F3A4B5C6D")!
        let action = ActionResult(
            stepId: "create-screen-reminder", status: .executed,
            startedAt: Date(timeIntervalSince1970: 1_784_329_201),
            endedAt: Date(timeIntervalSince1970: 1_784_329_202),
            channel: "eventkit",
            targetProvenance: ["capture_id": .string("capture")],
            rawResult: ["calendar_item_id": .string("created-id")],
            stateChangeHint: "Reminder committed", error: nil)
        let actionEnvelope = Envelope(
            type: .actionFinished, taskID: taskID, payload: .actionFinished(action))
        XCTAssertEqual(
            try Envelope.decode(from: actionEnvelope.encodeWire()), actionEnvelope)

        let verification = VerificationResult(
            predicateId: "reminder-exists", passed: true,
            method: "eventkit_fetch_back", confidence: 1,
            expected: ["task_marker": .string("voiceops-task:123")],
            observed: ["calendar_item_id": .string("created-id")],
            evidenceIds: ["eventkit:created-id"], failureReason: nil)
        let verificationEnvelope = Envelope(
            type: .verificationFinished, taskID: taskID,
            payload: .verificationFinished(verification))
        XCTAssertEqual(
            try Envelope.decode(from: verificationEnvelope.encodeWire()), verificationEnvelope)
    }
}
