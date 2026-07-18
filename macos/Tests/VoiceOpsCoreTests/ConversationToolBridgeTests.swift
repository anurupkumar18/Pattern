import Foundation
import XCTest
@testable import VoiceOpsCore

final class ConversationToolBridgeTests: XCTestCase {
    let taskID = UUID(uuidString: "18420000-0000-4000-8000-000000000042")!

    func bridge() -> ConversationToolBridge {
        ConversationToolBridge(taskID: taskID)
    }

    func testKnownToolWithValidArgumentsBecomesEnvelope() throws {
        let result = bridge().envelope(for: (
            callID: "call_1", name: "compile_task",
            argumentsJSON: #"{"transcript":"Take care of this delayed order"}"#))
        guard case .success(let envelope) = result else {
            return XCTFail("expected an envelope, got \(result)")
        }
        XCTAssertEqual(envelope.type, .conversationToolCall)
        XCTAssertEqual(envelope.taskID, taskID)
        guard case .conversationToolCall(let call) = envelope.payload else {
            return XCTFail("expected conversationToolCall payload")
        }
        XCTAssertEqual(call.callID, "call_1")
        XCTAssertEqual(call.tool, "compile_task")
        XCTAssertEqual(
            call.arguments["transcript"],
            .string("Take care of this delayed order"))
    }

    func testUnknownToolIsRejectedLocallyWithoutSidecarEnvelope() throws {
        let result = bridge().envelope(for: (
            callID: "call_2", name: "delete_everything", argumentsJSON: "{}"))
        guard case .failure(let rejection) = result else {
            return XCTFail("unknown tool must never produce an envelope")
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(rejection.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "rejected")
        let error = try XCTUnwrap(object["error"] as? String)
        XCTAssertTrue(error.contains("delete_everything"))
    }

    func testMalformedArgumentsAreRejectedLocally() {
        let result = bridge().envelope(for: (
            callID: "call_3", name: "compile_task", argumentsJSON: "{not json"))
        guard case .failure = result else {
            return XCTFail("malformed arguments must never produce an envelope")
        }
    }

    func testToolResultMapsToFunctionCallOutputJSON() throws {
        let toolResult = ConversationToolResult(
            callID: "call_4", tool: "apply_patch", status: "ok",
            result: ["new_version": .number(2), "removed": .array([.string("actions.create_replacement")])])
        let output = bridge().output(for: toolResult)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "ok")
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["new_version"] as? Double, 2)
    }

    func testFailedToolResultCarriesErrorMessage() throws {
        let toolResult = ConversationToolResult(
            callID: "call_5", tool: "confirm_approval", status: "rejected",
            error: StructuredError(
                code: "AMBIGUOUS_STATE",
                message: "utterance is not an unambiguous approval"))
        let output = bridge().output(for: toolResult)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "rejected")
        let error = try XCTUnwrap(object["error"] as? String)
        XCTAssertTrue(error.contains("unambiguous"))
    }
}

final class ConversationSessionStateTests: XCTestCase {
    func testHotkeyOpensConversationFromIdle() {
        XCTAssertEqual(
            SessionStateMachine.reduce(.idle, .conversationOpened),
            .conversing(agentSpeaking: false, planVersion: nil, transcript: ""))
    }

    func testConversingAbsorbsTranscriptAndPlanUpdates() {
        let state = SessionStateMachine.reduce(
            .conversing(agentSpeaking: false, planVersion: nil, transcript: ""),
            .partialTranscript("Take care of this order"))
        XCTAssertEqual(
            state,
            .conversing(
                agentSpeaking: false, planVersion: nil,
                transcript: "Take care of this order"))
        let versioned = SessionStateMachine.reduce(
            state!, .taskSpecReady(version: 2, objective: "Resolve order"))
        XCTAssertEqual(
            versioned,
            .conversing(
                agentSpeaking: false, planVersion: 2,
                transcript: "Take care of this order"))
    }

    func testAgentSpeechTogglesBargeInFlag() {
        let speaking = SessionStateMachine.reduce(
            .conversing(agentSpeaking: false, planVersion: 1, transcript: "t"),
            .agentSpeechStarted)
        XCTAssertEqual(
            speaking,
            .conversing(agentSpeaking: true, planVersion: 1, transcript: "t"))
        XCTAssertEqual(
            SessionStateMachine.reduce(speaking!, .agentSpeechEnded),
            .conversing(agentSpeaking: false, planVersion: 1, transcript: "t"))
    }

    func testStopFromConversingCancels() {
        XCTAssertEqual(
            SessionStateMachine.reduce(
                .conversing(agentSpeaking: true, planVersion: 2, transcript: "t"),
                .stopRequested),
            .result(.cancelled))
    }

    func testConversationClosedWithoutTaskReturnsToIdle() {
        XCTAssertEqual(
            SessionStateMachine.reduce(
                .conversing(agentSpeaking: false, planVersion: nil, transcript: ""),
                .conversationClosed),
            .idle)
    }

    func testTaskCompletionAndFailureSurfaceResults() {
        XCTAssertEqual(
            SessionStateMachine.reduce(
                .conversing(agentSpeaking: false, planVersion: 2, transcript: "t"),
                .taskCompleted(state: .succeeded, summary: "5/5")),
            .result(.completed(state: .succeeded, summary: "5/5")))
        XCTAssertEqual(
            SessionStateMachine.reduce(
                .conversing(agentSpeaking: false, planVersion: 2, transcript: "t"),
                .taskFailed(reason: "sidecar died")),
            .result(.failed(reason: "sidecar died")))
    }

    func testConversationEventsAreNoOpsOutsideTheirStates() {
        XCTAssertNil(SessionStateMachine.reduce(.idle, .conversationClosed))
        XCTAssertNil(SessionStateMachine.reduce(.idle, .agentSpeechStarted))
        XCTAssertNil(SessionStateMachine.reduce(
            .listening(transcript: ""), .conversationOpened))
    }
}
