import Foundation
import XCTest
@testable import VoiceOpsCore

final class RealtimeConversationProtocolTests: XCTestCase {
    // The Python ConversationToolName literals; the wire fixtures in
    // fixtures/ipc/ pin the envelope side of this contract.
    static let sidecarTools = [
        "compile_task", "apply_patch", "get_task_state", "request_approval",
        "confirm_approval", "execute_plan", "get_ledger",
    ]

    func testRegistryMatchesSidecarToolNamesExactly() {
        XCTAssertEqual(
            ConversationToolRegistry.tools.map(\.name), Self.sidecarTools)
    }

    func testSessionUpdateUsesSpeechToSpeechContractWithSemanticVAD() throws {
        let text = try RealtimeConversationWire.sessionUpdate(.init())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "session.update")
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertEqual(session["model"] as? String, "gpt-realtime")
        XCTAssertEqual(session["tool_choice"] as? String, "auto")
        let instructions = try XCTUnwrap(session["instructions"] as? String)
        XCTAssertTrue(instructions.contains("VoiceOps"))
        XCTAssertTrue(instructions.contains("request_approval"))

        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let inputFormat = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(inputFormat["type"] as? String, "audio/pcm")
        XCTAssertEqual(inputFormat["rate"] as? Int, 24_000)
        let vad = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        XCTAssertEqual(vad["type"] as? String, "semantic_vad")
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-realtime-whisper")

        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        let outputFormat = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(outputFormat["type"] as? String, "audio/pcm")
        XCTAssertEqual(output["voice"] as? String, "marin")

        let tools = try XCTUnwrap(session["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, Self.sidecarTools.count)
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, Self.sidecarTools)
        XCTAssertTrue(tools.allSatisfy { ($0["type"] as? String) == "function" })
        let compile = try XCTUnwrap(tools.first)
        let parameters = try XCTUnwrap(compile["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        XCTAssertNotNil(properties["transcript"])
    }

    func testAppendAudioIsBase64() throws {
        let audio = Data([7, 8, 9, 250])
        let append = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(
                try RealtimeConversationWire.appendAudio(audio).utf8)) as? [String: String])
        XCTAssertEqual(append["type"], "input_audio_buffer.append")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(append["audio"])), audio)
    }

    func testFunctionCallOutputEmbedsCallIDAndOutput() throws {
        let text = try RealtimeConversationWire.functionCallOutput(
            callID: "call_9", outputJSON: #"{"status":"ok"}"#)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "conversation.item.create")
        let item = try XCTUnwrap(object["item"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "function_call_output")
        XCTAssertEqual(item["call_id"] as? String, "call_9")
        XCTAssertEqual(item["output"] as? String, #"{"status":"ok"}"#)
    }

    func testResponseCreate() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(
                try RealtimeConversationWire.responseCreate().utf8)) as? [String: String])
        XCTAssertEqual(object, ["type": "response.create"])
    }

    func testParsesEveryServerEventKind() throws {
        XCTAssertEqual(
            try RealtimeConversationWire.parseServerEvent(#"{"type":"session.updated"}"#),
            .sessionReady)
        XCTAssertEqual(
            try RealtimeConversationWire.parseServerEvent(
                #"{"type":"input_audio_buffer.speech_started"}"#),
            .userSpeechStarted)
        XCTAssertEqual(
            try RealtimeConversationWire.parseServerEvent(
                #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i1","transcript":"Take care of this order"}"#),
            .userTranscript("Take care of this order"))
        XCTAssertEqual(
            try RealtimeConversationWire.parseServerEvent(
                #"{"type":"response.output_audio_transcript.delta","delta":"On it. "}"#),
            .agentTranscriptDelta("On it. "))
        XCTAssertEqual(
            try RealtimeConversationWire.parseServerEvent(
                #"{"type":"response.output_audio.delta","delta":"\#(Data([1, 2, 3]).base64EncodedString())"}"#),
            .audioDelta(Data([1, 2, 3])))
        XCTAssertEqual(
            try RealtimeConversationWire.parseServerEvent(
                #"{"type":"response.function_call_arguments.done","call_id":"call_1","name":"compile_task","arguments":"{\"transcript\":\"hello\"}"}"#),
            .functionCall(
                callID: "call_1", name: "compile_task",
                argumentsJSON: #"{"transcript":"hello"}"#))
        XCTAssertEqual(
            try RealtimeConversationWire.parseServerEvent(#"{"type":"response.done"}"#),
            .responseDone)
        XCTAssertEqual(
            try RealtimeConversationWire.parseServerEvent(
                #"{"type":"error","error":{"message":"session expired"}}"#),
            .error(message: "session expired"))
        XCTAssertEqual(
            try RealtimeConversationWire.parseServerEvent(
                #"{"type":"rate_limits.updated"}"#),
            .ignored(type: "rate_limits.updated"))
    }

    func testMalformedEventsThrow() {
        XCTAssertThrowsError(
            try RealtimeConversationWire.parseServerEvent("not json"))
        XCTAssertThrowsError(
            try RealtimeConversationWire.parseServerEvent(
                #"{"type":"response.function_call_arguments.done","name":"compile_task"}"#))
        XCTAssertThrowsError(
            try RealtimeConversationWire.parseServerEvent(
                #"{"type":"response.output_audio.delta","delta":"%%%not-base64%%%"}"#))
    }

    func testPersonaForbidsDirectActionAndScreenInstructionFollowing() {
        let persona = RealtimeConversationConfiguration.crispOperatorPersona
        XCTAssertTrue(persona.contains("tools"))
        XCTAssertTrue(persona.contains("confirm_approval"))
        XCTAssertTrue(persona.lowercased().contains("never"))
    }
}
