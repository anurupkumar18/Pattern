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

## 2026-07-18 - Phase 5: Live console

- Added a Vite/React console and Node WebSocket server. MockHerdr plus the
  deterministic router are the defaults; real Herdr and Gemma transports are
  selected through environment flags.
- Added browser Web Speech API input from the existing
  `cursor/voice-state-pipeline` hook pattern plus a keyboard-only utterance
  path.
- The live surface shows mic/server state, streaming heard text, routed verb,
  target, confidence, routing latency, confirmation gate, fleet state, and a
  verifier-owned command ledger with per-stage latency.
- Design references: Haselwood ledger proof rows and flat charcoal rules,
  Samir's source/caveat-forward hierarchy, and the Podium dashboard SOP's
  table-first operational density. Purple is limited to action/selection.
- Runtime proof: local HTTP loaded, and a text-simulated WebSocket utterance
  (`tell the blocked one to use staging`) returned `SUCCEEDED`, target
  `migration`, with every verifier predicate passing.
- Visual proof: headless Chrome desktop (1440px) and narrow (390px) layouts
  were inspected with no overlap or horizontal overflow. The empty first-load
  state is intentionally sparse; richer value appears after the first command.
- Proof: `npm test` passes 18 tests in 5 files with 1 real-Herdr smoke test
  skipped; TypeScript checks and the production Vite build pass.
- Open questions: Web Speech API availability varies by browser; typed input
  remains the deterministic demo fallback.

## 2026-07-18 - Phase 6: Eval runner and wrap

- Added `npm run eval`, per-case JSON evidence, a concise markdown readout, and
  category, noise false-fire, verifier-success, and stage-latency metrics.
- Added the exact mock, real-Herdr, and Gemma-on-Cactus reviewer/demo commands
  plus the four-minute script in `commandcenter/DEMO.md`.
- Eval result: deterministic 28/28 overall, clear 15/15, fuzzy 5/5, noise 6/6,
  destructive 2/2, 0% noise false-fire, and 28/28 end-to-end verified.
- Gemma seam result: 28/28 through the fixture-oracle transport, 0% noise
  false-fire, and 28/28 end-to-end verified. This proves prompt/parser/control
  plumbing only. It is explicitly not a claim about Gemma model quality.
- Real versus stubbed: command contracts, deterministic router, command loop,
  verifier, console, socket transport, and adapter method mapping are real.
  Herdr runtime calls are mock-backed in automated tests, and Gemma generation
  is mock-backed until local Cactus is configured.
- Proof: `npm test` passes 20 tests in 6 files with 1 real-Herdr smoke test
  skipped; `npm run build` and `npm run eval` pass.
- Open blockers: no local Herdr socket or Cactus/Gemma runtime was configured.
  Both seams and opt-in test commands are documented; no implementation phase
  is blocked.
## 2026-07-18 (overnight follow-up) - Real Herdr validated, adapter fixed

- Installed Herdr 0.7.4 (brew) and started `herdr server`; socket at
  `~/.config/herdr/herdr.sock`.
- Ran the previously skipped integration test for real:
  `RUN_HERDR_INTEGRATION=1 HERDR_SOCKET_PATH=~/.config/herdr/herdr.sock npx vitest run test/herdr.integration.test.ts` passes.
- Found and fixed a real-API mismatch in `HerdrAdapter.spawn`: the live
  `agent.start` schema requires `{ name, argv }` and accepts
  `workspace_id`/`cwd`/`focus`; the previous `kind`/`pane_id`/`args`/`timeout_ms`
  shape was invented and would have failed on real Herdr. Verified against
  `herdr api schema --json` (protocol 16) and the live server.
- Added `commandcenter/scripts/smoke-herdr.ts`: end-to-end
  snapshot -> spawn -> verify -> send -> focus -> verify against the real
  server. All six checks pass (SMOKE OK).
- `pane.send_keys` with `ctrl+c` for interrupt matches the documented key-combo
  grammar; no change needed.
- Remaining environment gap: local Gemma runtime. Ollama 0.15 installed and
  serving, but no model pulled yet (download needs approval). Once a Gemma
  model is present: `GEMMA_COMMAND=ollama GEMMA_ARGS='["run","<model>"]'
  npm run eval` exercises the real-model path via the exec transport.
