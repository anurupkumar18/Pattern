# VoiceOps Decision Log

Deviations from the phase plan and notable engineering decisions. ADR-001..005 live in `docs/ARD.md` §11; numbering here continues from there.

## ADR-006: SPM package now, Xcode project in Phase 1

**Date:** 2026-07-17 · **Phase:** 0

**Decision:** Phase 0 ships the Swift side as a Swift Package (`macos/VoiceOpsCore`) with a `voiceops-mock-client` executable, not the `VoiceOps.xcodeproj` shown in the target repo tree.

**Reason:** Phase 0's deliverable is a mock client that exchanges one request and one completion event with the Python sidecar. An SPM package builds and tests headlessly (`swift build` / `swift test`), which is exactly what CI needs and keeps the IPC layer reusable. The Xcode app project is created in Phase 1 when the hotkey/UI shell begins, and will depend on `VoiceOpsCore` for all IPC types so nothing is thrown away.

## ADR-007: Python Pydantic models are the schema source of truth

**Date:** 2026-07-17 · **Phase:** 0

**Decision:** IPC message and task object schemas are defined once as Pydantic v2 models in `agent/voiceops_agent/schemas.py`. JSON Schema files in `schemas/` are generated from them (`uv run voiceops-export-schemas`) and committed. Swift `Codable` types mirror the models and are held to the contract by shared fixtures in `fixtures/ipc/` that both test suites must round-trip.

**Reason:** One authoritative definition avoids silent drift between runtimes. Generated JSON Schema gives Swift (and CI) something machine-checkable without adding a codegen dependency during the hackathon.

## ADR-008: NDJSON over stdin/stdout for Phase 0 IPC

**Date:** 2026-07-17 · **Phase:** 0

**Decision:** The sidecar speaks newline-delimited JSON envelopes on stdin/stdout, per ARD §7. The localhost WebSocket option is deferred until streaming voice partials (Phase 1) proves it necessary.

**Reason:** Lowest-overhead transport that the ARD explicitly endorses; trivially testable from both runtimes and from the shell.
