import Foundation

public enum RealtimeTranscriptionDelay: String, Codable, Sendable {
    case minimal, low, medium, high, xhigh
}

public struct RealtimeTranscriptionConfiguration: Equatable, Sendable {
    public let model: String
    public let finalModel: String?
    public let finalPrompt: String?
    public let language: String
    public let delay: RealtimeTranscriptionDelay
    public let sampleRate: Int

    public init(
        model: String = "gpt-realtime-whisper",
        finalModel: String? = "gpt-4o-transcribe",
        finalPrompt: String? = (
            "Ecommerce operations command mentioning Shopify, order IDs, tracking, "
            + "expedited replacements, refunds, store credit, Slack, and carrier delays."),
        language: String = "en",
        delay: RealtimeTranscriptionDelay = .medium,
        sampleRate: Int = 24_000
    ) {
        self.model = model
        self.finalModel = finalModel
        self.finalPrompt = finalPrompt
        self.language = language
        self.delay = delay
        self.sampleRate = sampleRate
    }
}

/// Builds the bounded WAV/multipart request used to refine a completed live
/// transcript. The request is pure and deterministic; networking stays in the
/// macOS provider adapter.
public enum HighAccuracyTranscriptionWire {
    public static func wavFile(pcm16: Data, sampleRate: Int) -> Data {
        var output = Data()
        output.appendASCII("RIFF")
        output.appendLE(UInt32(36 + pcm16.count))
        output.appendASCII("WAVE")
        output.appendASCII("fmt ")
        output.appendLE(UInt32(16))
        output.appendLE(UInt16(1))
        output.appendLE(UInt16(1))
        output.appendLE(UInt32(sampleRate))
        output.appendLE(UInt32(sampleRate * 2))
        output.appendLE(UInt16(2))
        output.appendLE(UInt16(16))
        output.appendASCII("data")
        output.appendLE(UInt32(pcm16.count))
        output.append(pcm16)
        return output
    }

    public static func multipartBody(
        wav: Data,
        model: String,
        language: String,
        prompt: String?,
        boundary: String
    ) -> Data {
        var body = Data()
        body.appendFormField("model", value: model, boundary: boundary)
        body.appendFormField("language", value: language, boundary: boundary)
        if let prompt, !prompt.isEmpty {
            body.appendFormField("prompt", value: prompt, boundary: boundary)
        }
        body.appendASCII("--\(boundary)\r\n")
        body.appendASCII(
            "Content-Disposition: form-data; name=\"file\"; filename=\"voiceops.wav\"\r\n")
        body.appendASCII("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        body.appendASCII("\r\n--\(boundary)--\r\n")
        return body
    }

    public static func parseTranscript(_ data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["text"] as? String
        else { throw RealtimeTranscriptionProtocolError.invalidEvent }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw RealtimeTranscriptionProtocolError.invalidEvent
        }
        return text
    }
}

public enum RealtimeTranscriptionServerEvent: Equatable, Sendable {
    case delta(itemID: String, text: String)
    case completed(itemID: String, transcript: String)
    case error(message: String)
    case ignored(type: String)
}

public enum RealtimeTranscriptionWire {
    public static func sessionUpdate(
        _ configuration: RealtimeTranscriptionConfiguration
    ) throws -> String {
        try encode([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": configuration.sampleRate,
                        ],
                        "transcription": [
                            "model": configuration.model,
                            "language": configuration.language,
                            "delay": configuration.delay.rawValue,
                        ],
                        // Manual commit keeps the global hotkey authoritative.
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ])
    }

    public static func appendAudio(_ pcm16: Data) throws -> String {
        try encode([
            "type": "input_audio_buffer.append",
            "audio": pcm16.base64EncodedString(),
        ])
    }

    public static func commitAudio() throws -> String {
        try encode(["type": "input_audio_buffer.commit"])
    }

    public static func parseServerEvent(_ text: String) throws
        -> RealtimeTranscriptionServerEvent
    {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            throw RealtimeTranscriptionProtocolError.invalidEvent
        }
        switch type {
        case "conversation.item.input_audio_transcription.delta":
            guard let itemID = object["item_id"] as? String,
                  let delta = object["delta"] as? String
            else { throw RealtimeTranscriptionProtocolError.invalidEvent }
            return .delta(itemID: itemID, text: delta)
        case "conversation.item.input_audio_transcription.completed":
            guard let itemID = object["item_id"] as? String,
                  let transcript = object["transcript"] as? String
            else { throw RealtimeTranscriptionProtocolError.invalidEvent }
            return .completed(itemID: itemID, transcript: transcript)
        case "error":
            let error = object["error"] as? [String: Any]
            return .error(message: error?["message"] as? String ?? "Realtime transcription failed")
        default:
            return .ignored(type: type)
        }
    }

    private static func encode(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeTranscriptionProtocolError.invalidEvent
        }
        return text
    }
}

public enum RealtimeTranscriptionProtocolError: Error, Equatable {
    case invalidEvent
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(value.data(using: .utf8)!)
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendFormField(
        _ name: String, value: String, boundary: String
    ) {
        appendASCII("--\(boundary)\r\n")
        appendASCII("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendASCII(value)
        appendASCII("\r\n")
    }
}
