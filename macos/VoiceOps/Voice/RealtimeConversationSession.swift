import Foundation
import VoiceOpsCore

/// App-side networking for the typed S2S wire. The sidecar remains a separate
/// authority owned by AppCoordinator, which lets a socket failure fall back to
/// per-utterance speech without discarding the task or its version.
final class RealtimeConversationSession: @unchecked Sendable {
    enum SessionError: Error, LocalizedError {
        case invalidCredential
        case invalidSocketMessage
        case connectionTimedOut
        case server(String)

        var errorDescription: String? {
            switch self {
            case .invalidCredential: "The OpenAI API credential is empty."
            case .invalidSocketMessage: "OpenAI Realtime returned an unreadable message."
            case .connectionTimedOut: "OpenAI Realtime did not become ready in time."
            case .server(let message): "OpenAI Realtime: \(message)"
            }
        }
    }

    private let lock = NSLock()
    private let apiKey: String
    private let configuration: RealtimeConversationConfiguration
    private let urlSession: URLSession
    private let audio: ConversationAudioIO
    private let sidecar: SidecarClient
    private let bridge: ConversationToolBridge
    private let onEvent: @Sendable (RealtimeConversationServerEvent) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private var socket: URLSessionWebSocketTask?
    private var receiverTask: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyReceived = false
    private var terminal = false

    init(
        apiKey: String,
        taskID: UUID,
        sidecar: SidecarClient,
        configuration: RealtimeConversationConfiguration = .init(),
        urlSession: URLSession = URLSession(configuration: .ephemeral),
        audio: ConversationAudioIO = ConversationAudioIO(),
        onEvent: @escaping @Sendable (RealtimeConversationServerEvent) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.apiKey = apiKey
        self.configuration = configuration
        self.urlSession = urlSession
        self.audio = audio
        self.sidecar = sidecar
        self.bridge = ConversationToolBridge(taskID: taskID)
        self.onEvent = onEvent
        self.onFailure = onFailure
    }

    func start() async throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionError.invalidCredential
        }
        guard let url = URL(string:
            "wss://api.openai.com/v1/realtime?model=\(configuration.model)")
        else { throw SessionError.invalidSocketMessage }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let socket = urlSession.webSocketTask(with: request)
        lock.withLock {
            self.socket = socket
            terminal = false
            readyReceived = false
        }
        socket.resume()
        try await socket.send(.string(
            try RealtimeConversationWire.sessionUpdate(configuration)))
        receive(from: socket)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await withCheckedThrowingContinuation {
                        continuation in
                        let alreadyReady = self.lock.withLock { () -> Bool in
                            if self.readyReceived { return true }
                            self.readyContinuation = continuation
                            return false
                        }
                        if alreadyReady { continuation.resume() }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(8))
                    throw SessionError.connectionTimedOut
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            cancel()
            throw error
        }

        try audio.start { [weak self] chunk in
            Task { try? await self?.sendAudio(chunk) }
        }
        try await socket.send(.string(try RealtimeConversationWire.responseCreate()))
    }

    func sendTool(
        name: String, arguments: [String: JSONValue], callID: String = UUID().uuidString
    ) async throws {
        let data = try JSONEncoder().encode(arguments)
        let json = String(decoding: data, as: UTF8.self)
        switch bridge.envelope(for: (callID, name, json)) {
        case .success(let envelope):
            try await sidecar.send(envelope)
        case .failure(let rejection):
            try await sendFunctionOutput(callID: callID, output: rejection.outputJSON)
        }
    }

    func accept(_ result: ConversationToolResult) async throws {
        // Click-fallback calls are app-originated and have no matching model
        // function-call item. Their result still flows through the same sidecar
        // tool gate, but must not fabricate a Realtime call id.
        guard !result.callID.hasPrefix("ui-") else { return }
        try await sendFunctionOutput(
            callID: result.callID, output: bridge.output(for: result))
    }

    /// Socket first, then engine/playback. AppCoordinator cancels the sidecar
    /// only after this returns, enforcing the panic-stop ordering contract.
    func cancel() {
        let state = lock.withLock { () -> (URLSessionWebSocketTask?, CheckedContinuation<Void, Error>?) in
            terminal = true
            let ready = readyContinuation
            readyContinuation = nil
            let socket = self.socket
            self.socket = nil
            return (socket, ready)
        }
        state.0?.cancel(with: .goingAway, reason: nil)
        state.1?.resume(throwing: CancellationError())
        receiverTask?.cancel()
        receiverTask = nil
        audio.stop()
    }

    private func receive(from socket: URLSessionWebSocketTask) {
        receiverTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let text: String
                    switch message {
                    case .string(let value): text = value
                    case .data(let value):
                        guard let decoded = String(data: value, encoding: .utf8) else {
                            throw SessionError.invalidSocketMessage
                        }
                        text = decoded
                    @unknown default: throw SessionError.invalidSocketMessage
                    }
                    try await handle(RealtimeConversationWire.parseServerEvent(text))
                }
            } catch {
                fail(error)
            }
        }
    }

    private func handle(_ event: RealtimeConversationServerEvent) async throws {
        switch event {
        case .sessionReady:
            let continuation = lock.withLock {
                readyReceived = true
                let value = readyContinuation
                readyContinuation = nil
                return value
            }
            continuation?.resume()
        case .userSpeechStarted:
            audio.stopPlayback()
            onEvent(event)
        case .audioDelta(let pcm16):
            audio.enqueue(pcm16)
            onEvent(event)
        case .functionCall(let callID, let name, let argumentsJSON):
            switch bridge.envelope(for: (callID, name, argumentsJSON)) {
            case .success(let envelope): try await sidecar.send(envelope)
            case .failure(let rejection):
                try await sendFunctionOutput(
                    callID: callID, output: rejection.outputJSON)
            }
            onEvent(event)
        case .error(let message):
            throw SessionError.server(message)
        default:
            onEvent(event)
        }
    }

    private func sendAudio(_ pcm16: Data) async throws {
        guard let socket = lock.withLock({ self.socket }),
              !lock.withLock({ terminal })
        else { return }
        try await socket.send(.string(try RealtimeConversationWire.appendAudio(pcm16)))
    }

    private func sendFunctionOutput(callID: String, output: String) async throws {
        guard let socket = lock.withLock({ self.socket }) else { return }
        try await socket.send(.string(try RealtimeConversationWire.functionCallOutput(
            callID: callID, outputJSON: output)))
        try await socket.send(.string(try RealtimeConversationWire.responseCreate()))
    }

    private func fail(_ error: Error) {
        let shouldReport = lock.withLock { () -> Bool in
            guard !terminal else { return false }
            terminal = true
            let ready = readyContinuation
            readyContinuation = nil
            ready?.resume(throwing: error)
            return true
        }
        guard shouldReport else { return }
        audio.stop()
        onFailure(error)
    }
}
