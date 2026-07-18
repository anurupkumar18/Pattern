import Foundation

public enum SidecarError: Error, Equatable {
    case notRunning
    case alreadyStarted
    case launchFailed(String)
}

/// Owns the Python sidecar process and speaks NDJSON envelopes with it.
/// cancel() is the panic path: it must always leave the process dead and the
/// event stream finished, even mid-task (Phase 1 exit criterion: stop
/// interrupts any mock task).
public actor SidecarClient {
    private let agentProjectURL: URL
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var pump: NDJSONPump?

    public init(agentProjectURL: URL) {
        self.agentProjectURL = agentProjectURL
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    /// Default uv install locations, checked before PATH. GUI-launched apps
    /// inherit launchd's minimal PATH, which never includes Homebrew.
    public static nonisolated let defaultUVCandidates = [
        ProcessInfo.processInfo.environment["VOICEOPS_UV"],
        "/opt/homebrew/bin/uv",
        "/usr/local/bin/uv",
        NSHomeDirectory() + "/.local/bin/uv",
    ].compactMap(\.self)

    public static nonisolated func resolveUVExecutable(
        candidates: [String] = defaultUVCandidates,
        environmentPATH: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) -> String? {
        let fm = FileManager.default
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        for dir in environmentPATH.split(separator: ":") {
            let path = String(dir) + "/uv"
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    public func start() throws -> AsyncThrowingStream<Envelope, Error> {
        guard process == nil else { throw SidecarError.alreadyStarted }

        guard let uv = Self.resolveUVExecutable() else {
            throw SidecarError.launchFailed(
                "uv not found — install it (https://docs.astral.sh/uv/) or set VOICEOPS_UV")
        }
        let sidecar = Process()
        sidecar.executableURL = URL(fileURLWithPath: uv)
        sidecar.arguments = ["run", "--project", agentProjectURL.path, "voiceops-agent"]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        sidecar.standardInput = stdinPipe
        sidecar.standardOutput = stdoutPipe

        let (stream, continuation) = AsyncThrowingStream<Envelope, Error>.makeStream()
        let pump = NDJSONPump(continuation: continuation)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            pump.consume(handle.availableData, handle: handle)
        }
        sidecar.terminationHandler = { _ in pump.finish() }

        do {
            try sidecar.run()
        } catch {
            continuation.finish(throwing: SidecarError.launchFailed(error.localizedDescription))
            throw SidecarError.launchFailed(error.localizedDescription)
        }

        self.process = sidecar
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.pump = pump
        return stream
    }

    public func send(_ envelope: Envelope) throws {
        guard let stdinHandle, process?.isRunning == true else {
            throw SidecarError.notRunning
        }
        try stdinHandle.write(contentsOf: Data(envelope.ndjsonLine().utf8))
    }

    public func cancel() {
        try? stdinHandle?.close()
        stdinHandle = nil
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        pump?.finish()
        pump = nil
        process = nil
    }
}

/// Accumulates pipe chunks into NDJSON lines and yields decoded envelopes.
/// Runs on FileHandle's callback queue; the lock makes finish() safe to call
/// from the actor and the termination handler concurrently.
private final class NDJSONPump: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: AsyncThrowingStream<Envelope, Error>.Continuation?

    init(continuation: AsyncThrowingStream<Envelope, Error>.Continuation) {
        self.continuation = continuation
    }

    func consume(_ chunk: Data, handle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }

        if chunk.isEmpty {  // EOF
            handle.readabilityHandler = nil
            continuation.finish()
            self.continuation = nil
            return
        }

        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard !line.isEmpty else { continue }
            do {
                continuation.yield(try Envelope.decode(from: Data(line)))
            } catch {
                handle.readabilityHandler = nil
                continuation.finish(throwing: error)
                self.continuation = nil
                return
            }
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        continuation?.finish()
        continuation = nil
    }
}
