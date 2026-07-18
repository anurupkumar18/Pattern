# VoiceOps

Speak the outcome. VoiceOps sees the current screen, completes the work on the real Mac, and proves the requested result occurred.

VoiceOps is a voice-first macOS action agent: press a hotkey, speak a goal, and VoiceOps interprets the live screen, plans a safe sequence of actions, operates native Mac applications, and independently verifies the resulting state.

**Core loop:** Speak → Ground → Plan → Preview risk → Act → Observe → Verify → Report evidence

## Status

Phase 2 — screen context and grounding is in progress. The app now captures the active window on demand with ScreenCaptureKit, collects and prunes the visible Accessibility tree, sends a typed task-scoped observation to the sidecar, resolves high-confidence screen references with provenance, and shows grounding chips before the mock plan. Golden Mail/deadline grounding is deterministic and offline-safe; a live VLM provider and its Keychain credential UI remain pending.

Phase 1’s voice shell remains intact: global hotkey (⌃⌥V), streaming system speech capture, floating companion with deterministic session states, stop/Escape cancellation, and spoken progress. See `docs/` for the full spec:

| Doc | Contents |
|---|---|
| [PRD.md](docs/PRD.md) | Product requirements, workflows, rubric mapping |
| [ARD.md](docs/ARD.md) | Architecture, components, IPC protocol, ADR-001..005 |
| [EVALUATION.md](docs/EVALUATION.md) | Metrics, test matrix, outcome predicates |
| [DEMO.md](docs/DEMO.md) | Judge demo runbook |
| [DECISIONS.md](docs/DECISIONS.md) | Decision log (ADR-006+) |

## Requirements

- macOS 14.2+ on Apple Silicon (developed against Swift 6 / Xcode 26)
- Python 3.12 via [uv](https://docs.astral.sh/uv/)

## Quick start

```sh
scripts/bootstrap.sh          # uv sync + swift build
scripts/run_sidecar.sh        # start the Python sidecar (NDJSON on stdio)

cd agent && uv run pytest     # Python tests
cd macos && swift test        # Swift tests
cd macos && swift run voiceops-mock-client   # end-to-end mock exchange
```

### Run the app

```sh
scripts/run_app.sh            # builds with the CLI toolchain and launches — no Xcode IDE needed
```

(Opening `macos/VoiceOps.xcodeproj` in Xcode works too, but is optional.) On first use, grant the Microphone, Speech Recognition, Screen Recording, and Accessibility prompts. Then:

1. Press **⌃⌥V** anywhere and speak a goal — the floating companion shows the live transcript.
2. Press **⌃⌥V** again (or pause) to finish. VoiceOps captures the active window, shows any grounded reference chips, and then walks through planning → acting → result with spoken progress.
3. **Stop** (or Escape while the companion has focus) cancels capture and any running task.

## Layout

```
agent/     Python 3.12 sidecar: schemas, orchestration, planning, verification, evals
macos/     Swift 6 shell: VoiceOpsCore package (IPC types, mock client); app project in Phase 1
schemas/   JSON Schema exports generated from the Pydantic models
fixtures/  Shared test fixtures, including fixtures/ipc/ contract fixtures
scripts/   bootstrap, sidecar launch, demo seed/reset, eval runner
evals/     Evaluation cases, expected outcomes, reports
```

## Invariants

Executors never declare success — only the verifier can. Screen content is untrusted data. Consequential actions require explicit approval. See [CLAUDE.md](CLAUDE.md) for the full list.
