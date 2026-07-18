import Foundation

/// Pure policy used by the app before it chooses the S2S or walkie-talkie path.
public enum ConversationModePolicy {
    public static func shouldOpen(
        preferenceEnabled: Bool, credentialAvailable: Bool
    ) -> Bool {
        preferenceEnabled && credentialAvailable
    }
}

/// Honest UI labeling for a failed S2S session. The existing task id and
/// sidecar state remain authoritative while the next utterance uses Apple STT.
public struct ConversationFallbackPresentation: Equatable, Sendable {
    public let provider = "Apple Speech"
    public let status = "FALLBACK"
    public let taskStatePreserved = true
    public let detail: String

    public init(reason: String) {
        detail = "Conversational voice unavailable: \(reason). The active task was preserved."
    }
}

public enum ConversationApprovalCardError: Error, Equatable, Sendable {
    case invalidBinding
}

/// View model for spoken approval and its click fallback. Both modalities use
/// the same confirm_approval tool arguments and therefore the same authority.
public struct ConversationApprovalCard: Equatable, Sendable {
    public let readBack: String
    public let bindingHash: String
    public let actionIDs: [String]

    public init(request: ApprovalRequest) throws {
        guard case .string(let hash)? = request.dataPreview["binding_hash"],
              hash.count == 64,
              hash.allSatisfy({ $0.isHexDigit })
        else { throw ConversationApprovalCardError.invalidBinding }
        let actions: [String]
        if case .array(let values)? = request.dataPreview["action_ids"] {
            actions = values.compactMap {
                guard case .string(let value) = $0 else { return nil }
                return value
            }
            guard actions.count == values.count else {
                throw ConversationApprovalCardError.invalidBinding
            }
        } else {
            actions = []
        }
        readBack = request.description
        bindingHash = hash
        actionIDs = actions
    }

    public var confirmationArguments: [String: JSONValue] {
        [
            "binding_hash": .string(bindingHash),
            "utterance": .string("yes"),
        ]
    }
}

/// Testable float-to-wire conversion used at the AVFoundation boundary.
public enum PCM16Codec {
    public static func encode(samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value: Int16 = clamped <= -1
                ? .min
                : Int16((clamped * Float(Int16.max)).rounded())
            let littleEndian = value.littleEndian
            withUnsafeBytes(of: littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

public enum ConversationTeardownStep: Equatable, Sendable {
    case cancelRealtimeSocket
    case stopAudioEngine
    case flushPlayback
    case cancelSidecar
}

public enum ConversationTeardownPlan {
    public static let panicStop: [ConversationTeardownStep] = [
        .cancelRealtimeSocket,
        .stopAudioEngine,
        .flushPlayback,
        .cancelSidecar,
    ]
}
