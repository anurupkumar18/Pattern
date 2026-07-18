import Foundation

public enum RealtimeTranscriptionDelay: String, Codable, Sendable {
    case minimal, low, medium, high, xhigh
}

public struct RealtimeTranscriptionConfiguration: Equatable, Sendable {
    public let model: String
    public let language: String
    public let delay: RealtimeTranscriptionDelay
    public let sampleRate: Int

    public init(
        model: String = "gpt-realtime-whisper",
        language: String = "en",
        delay: RealtimeTranscriptionDelay = .medium,
        sampleRate: Int = 24_000
    ) {
        self.model = model
        self.language = language
        self.delay = delay
        self.sampleRate = sampleRate
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
