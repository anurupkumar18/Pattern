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

    func testBuildsValidMonoPCM16WAVForFinalRefinement() {
        let pcm = Data([1, 2, 3, 4])
        let wav = HighAccuracyTranscriptionWire.wavFile(
            pcm16: pcm, sampleRate: 24_000)

        XCTAssertEqual(String(data: wav[0..<4], encoding: .utf8), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .utf8), "WAVE")
        XCTAssertEqual(String(data: wav[36..<40], encoding: .utf8), "data")
        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(wav.suffix(pcm.count), pcm)
    }

    func testBuildsMultipartRefinementRequestAndParsesResult() throws {
        let body = HighAccuracyTranscriptionWire.multipartBody(
            wav: Data([82, 73, 70, 70]),
            model: "gpt-4o-transcribe",
            language: "en",
            prompt: "Shopify, Maya Chen, Slack",
            boundary: "voiceops-boundary")
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\ngpt-4o-transcribe"))
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nen"))
        XCTAssertTrue(text.contains("name=\"prompt\"\r\n\r\nShopify, Maya Chen, Slack"))
        XCTAssertTrue(text.contains("filename=\"voiceops.wav\""))
        XCTAssertEqual(
            try HighAccuracyTranscriptionWire.parseTranscript(
                Data(#"{"text":"Order 1842 for Maya Chen"}"#.utf8)),
            "Order 1842 for Maya Chen")
    }
}
