# Voice Command Center Build Progress

This log records phase completion, proof, integration gaps, and overnight
blockers for `cursor/voice-command-center`.

## 2026-07-17 - Phase 0: Scaffold

- Added an isolated Node 20+, strict TypeScript, and Vitest project under
  `commandcenter/`.
- Added setup, build, and test instructions.
- Proof: `npm test` passes 1 test in 1 file; `npm run build` passes.
- Open questions: none.

## 2026-07-17 - Phase 1: FleetCommand contract

- Added strict Zod contracts for fleet snapshots, all eight command verbs,
  executor results, verifier verdicts, and command outcomes.
- Added a 28-case utterance matrix spanning clear, fuzzy-reference, noise, and
  destructive-command categories.
- Exported four draft-07 JSON Schemas from the Zod source of truth.
- Proof: `npm test` passes 5 tests in 2 files; `npm run build` and
  `npm run schema` pass.
- Open questions: none.

## 2026-07-18 - Phase 2: Control plane

- Added the `FleetControl` interface and a mutable, async `MockHerdr` with
  focus, send, spawn, interrupt, snapshot, and subscription behavior.
- Added a real newline-delimited Unix socket transport and `HerdrAdapter`
  against documented Herdr methods. Consulted Herdr's Socket API, Session
  State, Concepts, and generated API schema from `ogulcancelik/herdr`.
- Real code: Unix socket request/subscription transport, session snapshot
  mapping, and all control calls. Mock-backed: automated adapter tests and the
  default runtime.
- Real-Herdr smoke test is guarded by `RUN_HERDR_INTEGRATION=1` and
  `HERDR_SOCKET_PATH`; it was not run because no local Herdr socket was
  configured. This is an integration delta, not a compile/test blocker.
- Proof: `npm test` passes 9 tests in 3 files with 1 real-Herdr smoke test
  skipped; `npm run build` passes.
- Open questions: verify the configured socket path and installed agent kinds
  on the demo machine.

## 2026-07-18 - Phase 3: Router

- Added the async `Router` contract and deterministic grammar baseline. It
  passes all 23 non-fuzzy fixtures, including all 6 ambient-noise cases.
- Added `GemmaRouter` with compressed fleet context, a closed-verb prompt,
  strict FleetCommand parsing, schema validation, one correction retry, and
  fail-closed behavior.
- Added executable-command and local-HTTP transports so the router is not tied
  to one Cactus host shape.
- Real code: prompt, parser, retry policy, transports, and deterministic
  fallback. Mock-backed: Gemma generation tests.
- Cactus delta: install the Cactus CLI/SDK and Gemma 4 weights (the documented
  macOS quickstart is `brew install cactus-compute/cactus/cactus` followed by
  `cactus run google/gemma-4-E2B-it`), then add a thin non-interactive wrapper
  that reads the prompt from stdin and prints only the model text, or expose
  that same completion through the documented local HTTP contract. Configure
  the wrapper in `ExecGemmaTransport` or the endpoint in
  `HttpGemmaTransport`. No local Cactus runtime was configured tonight.
- Proof: `npm test` passes 14 tests in 4 files with 1 real-Herdr smoke test
  skipped; `npm run build` passes.
- Open questions: choose E2B versus E4B Gemma 4 weights based on demo-machine
  latency, then tune temperature/max tokens for JSON reliability.

## 2026-07-18 - Phase 4: Command loop and verifier

- Added the route, confirmation, act, independent-read, verify, and evidence
  loop with typed routed/outcome/snapshot events.
- Interrupts and commands below the confidence threshold stop in
  `AWAITING_CONFIRMATION` until explicitly confirmed.
- Added per-verb predicates for focus, delivered text, spawn specification,
  interrupt status transition, listening state, status reads, and noise
  no-op behavior.
- Ran all 28 utterance fixtures end to end against `MockHerdr`.
- Proved the executor/verifier invariant with a lying focus executor: executor
  returned `ok: true`, independent state did not change, and the loop returned
  `UNVERIFIED`, never `SUCCEEDED`.
- Proof: `npm test` passes 18 tests in 5 files with 1 real-Herdr smoke test
  skipped; `npm run build` passes.
- Open questions: none.
