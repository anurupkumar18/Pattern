import Foundation
import XCTest
@testable import VoiceOpsCore

final class RealtimeTranscriptionProtocolTests: XCTestCase {
    func testSessionUpdateUsesCurrentStreamingTranscriptionContract() throws {
        let text = try RealtimeTranscriptionWire.sessionUpdate(.init())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "session.update")
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-realtime-whisper")
        XCTAssertEqual(transcription["delay"] as? String, "medium")
        XCTAssertTrue(input["turn_detection"] is NSNull)
    }

    func testAudioMessagesAreBase64AndManuallyCommitted() throws {
        let audio = Data([0, 1, 2, 255])
        let append = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(
                try RealtimeTranscriptionWire.appendAudio(audio).utf8)) as? [String: String])
        XCTAssertEqual(append["type"], "input_audio_buffer.append")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(append["audio"])), audio)

        let commit = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(
                try RealtimeTranscriptionWire.commitAudio().utf8)) as? [String: String])
        XCTAssertEqual(commit, ["type": "input_audio_buffer.commit"])
    }

    func testParsesDeltaCompletionAndTypedErrors() throws {
        XCTAssertEqual(
            try RealtimeTranscriptionWire.parseServerEvent(
                #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_1","delta":"Order "}"#),
            .delta(itemID: "item_1", text: "Order "))
        XCTAssertEqual(
            try RealtimeTranscriptionWire.parseServerEvent(
                #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_1","transcript":"Order 1842"}"#),
            .completed(itemID: "item_1", transcript: "Order 1842"))
        XCTAssertEqual(
            try RealtimeTranscriptionWire.parseServerEvent(
                #"{"type":"error","error":{"message":"bad audio"}}"#),
            .error(message: "bad audio"))
        XCTAssertEqual(
            try RealtimeTranscriptionWire.parseServerEvent(
                #"{"type":"session.updated"}"#),
            .ignored(type: "session.updated"))
    }
}
