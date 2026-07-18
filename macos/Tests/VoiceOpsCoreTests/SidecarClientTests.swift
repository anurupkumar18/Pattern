import XCTest
@testable import VoiceOpsCore

/// Integration tests against the real Python sidecar. Skipped when uv is not
/// on PATH (the plain `swift` CI job); the e2e CI job covers the same path via
/// voiceops-mock-client.
final class SidecarClientTests: XCTestCase {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func requireUV() throws {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let hasUV = path.split(separator: ":").contains {
            FileManager.default.isExecutableFile(atPath: String($0) + "/uv")
        }
        try XCTSkipUnless(hasUV, "uv not on PATH; sidecar integration covered by e2e CI job")
    }

    private func fixtureEnvelope() throws -> Envelope {
        let url = Self.repoRoot.appendingPathComponent("fixtures/ipc/voice_final.json")
        return try Envelope.decode(from: Data(contentsOf: url))
    }

    private func makeClient() -> SidecarClient {
        SidecarClient(agentProjectURL: Self.repoRoot.appendingPathComponent("agent"))
    }

    func testResolvesUVFromExplicitCandidatesBeforePATH() throws {
        // GUI-launched apps get launchd's minimal PATH without Homebrew, so
        // the client must find uv at its known install locations itself.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceops-uv-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeUV = dir.appendingPathComponent("uv")
        FileManager.default.createFile(
            atPath: fakeUV.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755])

        let resolved = SidecarClient.resolveUVExecutable(
            candidates: [dir.appendingPathComponent("missing").path, fakeUV.path],
            environmentPATH: "/usr/bin:/bin")
        XCTAssertEqual(resolved, fakeUV.path)
    }

    func testResolveUVFallsBackToPATHThenNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceops-uv-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeUV = dir.appendingPathComponent("uv")
        FileManager.default.createFile(
            atPath: fakeUV.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755])

        XCTAssertEqual(
            SidecarClient.resolveUVExecutable(candidates: [], environmentPATH: "/nope:\(dir.path)"),
            fakeUV.path)
        XCTAssertNil(
            SidecarClient.resolveUVExecutable(candidates: [], environmentPATH: "/nope"))
    }

    func testAdditionalEnvironmentOverridesOnlyNamedChildValues() {
        let merged = SidecarClient.mergedEnvironment(
            additional: [
                "VOICEOPS_OPENAI_API_KEY": "test-key",
                "VOICEOPS_VLM_MODEL": "gpt-5.6-terra",
            ],
            base: ["PATH": "/usr/bin", "VOICEOPS_VLM_MODEL": "old-model"])

        XCTAssertEqual(merged["PATH"], "/usr/bin")
        XCTAssertEqual(merged["VOICEOPS_OPENAI_API_KEY"], "test-key")
        XCTAssertEqual(merged["VOICEOPS_VLM_MODEL"], "gpt-5.6-terra")
    }

    func testVoiceFinalYieldsPlanThenCompletion() async throws {
        try requireUV()
        let client = makeClient()
        let events = try await client.start()
        try await client.send(fixtureEnvelope())

        var received: [EventType] = []
        for try await envelope in events {
            received.append(envelope.type)
            if received.count == 2 { break }
        }
        XCTAssertEqual(received, [.planReady, .taskCompleted])
        await client.cancel()
    }

    func testGroundedReminderWaitsForNativeActionAndVerification() async throws {
        try requireUV()
        let voice = try fixtureEnvelope()
        let observationURL = Self.repoRoot
            .appendingPathComponent("fixtures/screen/mail_deadline_observation.json")
        let observation = try JSONDecoder().decode(
            Observation.self, from: Data(contentsOf: observationURL))
        let client = makeClient()
        let events = try await client.start()
        try await client.send(Envelope(
            type: .observationReady,
            taskID: voice.taskID,
            payload: .observationReady(observation)))
        try await client.send(voice)

        var iterator = events.makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        let groundingEnvelope = try XCTUnwrap(first)
        let planEnvelope = try XCTUnwrap(second)
        XCTAssertEqual([groundingEnvelope.type, planEnvelope.type], [
            .groundingReady, .planReady,
        ])
        guard case .groundingReady(let grounding) = groundingEnvelope.payload else {
            return XCTFail("expected grounding.ready first")
        }
        XCTAssertEqual(grounding.references.map(\.phrase), ["this email", "the deadline"])
        guard case .planReady(let plan) = planEnvelope.payload,
              let step = plan.steps.first
        else { return XCTFail("expected reminder plan second") }

        let action = ActionResult(
            stepId: step.id, status: .executed,
            startedAt: Date(), endedAt: Date(), channel: "eventkit",
            rawResult: ["calendar_item_id": .string("test-id")],
            stateChangeHint: "fixture action executed")
        try await client.send(Envelope(
            type: .actionFinished, taskID: voice.taskID,
            payload: .actionFinished(action)))
        for predicate in step.postconditions {
            try await client.send(Envelope(
                type: .verificationFinished,
                taskID: voice.taskID,
                payload: .verificationFinished(VerificationResult(
                    predicateId: predicate.id, passed: true,
                    method: "fixture_verifier", confidence: 1,
                    expected: predicate.expected,
                    observed: ["verified": .bool(true)],
                    evidenceIds: ["fixture:test-id"], failureReason: nil))))
        }

        let final = try await iterator.next()
        let completedEnvelope = try XCTUnwrap(final)
        guard case .taskCompleted(let completed) = completedEnvelope.payload else {
            return XCTFail("expected task.completed after all verification")
        }
        XCTAssertEqual(completed.state, .succeeded)
        XCTAssertEqual(completed.verification.count, step.postconditions.count)
        await client.cancel()
    }

    func testCancelInterruptsTaskAndFinishesStream() async throws {
        try requireUV()
        let client = makeClient()
        let events = try await client.start()
        try await client.send(fixtureEnvelope())
        await client.cancel()

        // Stream must finish (not hang) after cancellation.
        var count = 0
        do {
            for try await _ in events { count += 1 }
        } catch {
            // A terminated pipe may surface as an error; finishing is what matters.
        }
        XCTAssertLessThanOrEqual(count, 2)
        let running = await client.isRunning
        XCTAssertFalse(running, "sidecar process must be terminated after cancel()")
    }

    func testSendAfterCancelThrows() async throws {
        try requireUV()
        let client = makeClient()
        _ = try await client.start()
        await client.cancel()
        do {
            try await client.send(fixtureEnvelope())
            XCTFail("send after cancel must throw")
        } catch {}
    }
}
