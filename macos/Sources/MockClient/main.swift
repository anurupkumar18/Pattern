import Foundation
import VoiceOpsCore

// voiceops-mock-client: Phase 0 exit-criteria check, run from anywhere inside
// the repo. Spawns the Python sidecar, sends the shared voice.final fixture,
// and validates the plan.ready + task.completed reply. Exit 0 only on a fully
// validated exchange. Hang protection is the caller's timeout (CI step).

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("voiceops-mock-client: " + message + "\n").utf8))
    exit(1)
}

func findRepoRoot() -> URL {
    if let override = ProcessInfo.processInfo.environment["VOICEOPS_ROOT"] {
        return URL(fileURLWithPath: override)
    }
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<8 {
        let marker = dir.appendingPathComponent("fixtures/ipc/voice_final.json")
        if FileManager.default.fileExists(atPath: marker.path) { return dir }
        dir.deleteLastPathComponent()
    }
    fail("could not locate the voiceops repo root; set VOICEOPS_ROOT")
}

/// Blocking NDJSON reader over a pipe.
final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(_ handle: FileHandle) { self.handle = handle }

    func nextLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                if line.isEmpty { continue }
                return Data(line)
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }  // sidecar closed stdout
            buffer.append(chunk)
        }
    }
}

let root = findRepoRoot()
let fixtureURL = root.appendingPathComponent("fixtures/ipc/voice_final.json")

guard let fixtureData = try? Data(contentsOf: fixtureURL) else {
    fail("missing fixture at \(fixtureURL.path)")
}
guard let request = try? Envelope.decode(from: fixtureData) else {
    fail("fixture no longer validates against VoiceOpsCore — protocol drift?")
}

print("→ voice.final  \(request.taskID.uuidString.lowercased())")

let sidecar = Process()
sidecar.executableURL = URL(fileURLWithPath: "/usr/bin/env")
sidecar.arguments = ["uv", "run", "--project", root.appendingPathComponent("agent").path, "voiceops-agent"]
let stdinPipe = Pipe()
let stdoutPipe = Pipe()
sidecar.standardInput = stdinPipe
sidecar.standardOutput = stdoutPipe

do {
    try sidecar.run()
} catch {
    fail("could not start sidecar via uv: \(error.localizedDescription)")
}

do {
    try stdinPipe.fileHandleForWriting.write(contentsOf: Data(request.ndjsonLine().utf8))
} catch {
    fail("could not write to sidecar stdin: \(error.localizedDescription)")
}

let reader = LineReader(stdoutPipe.fileHandleForReading)
var responses: [Envelope] = []
while responses.count < 2, let line = reader.nextLine() {
    do {
        let envelope = try Envelope.decode(from: line)
        responses.append(envelope)
        print("← \(envelope.type.rawValue)  \(envelope.taskID.uuidString.lowercased())")
        if envelope.type == .taskFailed { break }
    } catch {
        fail("sidecar sent an invalid envelope: \(error)")
    }
}

try? stdinPipe.fileHandleForWriting.close()
sidecar.waitUntilExit()

switch ExchangeValidator.validate(responses: responses, requestTaskID: request.taskID) {
case .failure(let reason):
    fail(reason)
case .success(let exchange):
    print("plan: \(exchange.plan.summary)")
    for step in exchange.plan.steps {
        print("  step \(step.id): \(step.tool) [risk=\(step.risk.rawValue), verifier=\(step.verifier.kind)]")
    }
    print("completion: \(exchange.completion.state.rawValue) — \(exchange.completion.summary)")
    print("PHASE 0 EXCHANGE VERIFIED")
}
