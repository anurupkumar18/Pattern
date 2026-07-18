import Foundation

/// Maps Realtime function calls to sidecar envelopes and tool results back to
/// function_call_output JSON. Anything outside the typed registry is rejected
/// locally — the model can never invent a side-effect path, and a rejection
/// never reaches the sidecar.
public struct ConversationToolBridge: Sendable {
    public struct BridgeRejection: Error, Equatable, Sendable {
        public let outputJSON: String
    }

    private let taskID: UUID
    private let toolNames: Set<String>

    public init(
        taskID: UUID,
        registry: [ConversationToolDefinition] = ConversationToolRegistry.tools
    ) {
        self.taskID = taskID
        self.toolNames = Set(registry.map(\.name))
    }

    public func envelope(
        for call: (callID: String, name: String, argumentsJSON: String)
    ) -> Result<Envelope, BridgeRejection> {
        guard toolNames.contains(call.name) else {
            return .failure(rejection(
                "unknown tool \(call.name); only registered tools can run"))
        }
        let arguments: [String: JSONValue]
        if call.argumentsJSON.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments = [:]
        } else {
            guard
                let data = call.argumentsJSON.data(using: .utf8),
                let decoded = try? JSONDecoder().decode(
                    [String: JSONValue].self, from: data)
            else {
                return .failure(rejection(
                    "arguments for \(call.name) were not a valid JSON object"))
            }
            arguments = decoded
        }
        return .success(Envelope(
            type: .conversationToolCall,
            taskID: taskID,
            payload: .conversationToolCall(ConversationToolCall(
                callID: call.callID, tool: call.name, arguments: arguments))))
    }

    public func output(for result: ConversationToolResult) -> String {
        var object: [String: JSONValue] = [
            "status": .string(result.status),
            "result": .object(result.result),
        ]
        if let error = result.error {
            object["error"] = .string(error.message)
        }
        return Self.encodeJSON(object)
    }

    private func rejection(_ message: String) -> BridgeRejection {
        BridgeRejection(outputJSON: Self.encodeJSON([
            "status": .string("rejected"),
            "error": .string(message),
        ]))
    }

    private static func encodeJSON(_ object: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let data = try? encoder.encode(object),
            let text = String(data: data, encoding: .utf8)
        else {
            return #"{"status":"failed","error":"tool output could not be encoded"}"#
        }
        return text
    }
}
