# Build Spec: Voice Command Center core (overnight run)

Read `docs/PRD-command-center.md` first. This spec is the execution contract for the automated builder.

## Mission

Build the command-center core on branch `cursor/voice-command-center`: Herdr control plane adapter (with mock), typed FleetCommand routing with a deterministic classifier plus a Gemma/Cactus adapter seam, an independent verifier, a live console, and an eval suite. Ship it phase by phase with green tests at every commit.

## Hard constraints

1. **Never modify or delete existing VoiceOps files:** `docs/PRD.md`, `docs/ARD.md`, `docs/DECISIONS.md`, `docs/EVALUATION.md`, `docs/DEMO.md`, `docs/RESEARCH.md`, `CLAUDE.md`, `agent/**`, `macos/**`, `schemas/**`, `fixtures/**`, `scripts/**`, `.github/**`, `README.md`. All new work is additive.
2. New code lives in `commandcenter/` (TypeScript, Node 20+, Vitest). Command schemas live in `commandcenter/schemas/` (zod as source of truth, JSON Schema exported), not in the top-level `schemas/` directory, which is generated from Anurup's Pydantic models.
3. Respect the CLAUDE.md invariants that apply here, especially: only the verifier may mark a command `SUCCEEDED`; destructive commands (`interrupt`, future `kill`) require a confirmation step; small commits with tests after every meaningful change.
4. Work only on branch `cursor/voice-command-center`. Never commit to `main`. Never force-push.
5. Do not send anything to Slack, email, or any external service. GitHub pushes to this repo's feature branch are the only allowed external writes.

## Overnight protocol (anti-spin rules)

- After each phase: run the full test suite; if green, commit (`feat(cc): <phase summary>`) and append a dated entry to `docs/PROGRESS.md` (phase, what shipped, test counts, open questions).
- If blocked on one problem for more than ~30 minutes of effort: write the blocker to `docs/PROGRESS.md`, stub the interface so dependents compile, and move to the next phase. Do not loop.
- Push the branch after Phase 2 and again after the final phase.
- If the real Herdr integration cannot be completed (install trouble, API mismatch), the mock-backed system is the deliverable; document the delta in `PROGRESS.md`.

## Phases

### Phase 0: Scaffold

- `commandcenter/package.json` (private), TypeScript strict, Vitest, ESLint optional. `npm test` and `npm run build` work from `commandcenter/`.
- `commandcenter/README.md` with run instructions, updated as phases land.

### Phase 1: FleetCommand contract

- Zod schemas: `FleetSnapshot` (agents: id, name, harness, status working|idle|blocked|done, cwd, lastActivity summary), `FleetCommand` (discriminated union over verbs `status | focus | send | spawn | interrupt | listen_ctl | dictate | noise`, each with typed payload, plus `confidence`, `rawUtterance`, `resolvedTargetId`), `CommandOutcome` (executor result vs verifier verdict kept separate), `VerificationResult` (predicate, pass/fail, evidence string).
- Export JSON Schemas to `commandcenter/schemas/*.json` via a script.
- Fixture set: `commandcenter/fixtures/utterances.json` with at least 25 cases: clear commands, fuzzy references ("the one that's blocked", "the second claude"), ambient noise, destructive commands. Each case: utterance, snapshot, expected command.

### Phase 2: Control plane

- `FleetControl` interface: `snapshot()`, `focus(agentId)`, `send(agentId, text)`, `spawn(spec)`, `interrupt(agentId)`, `subscribe(handler)`.
- `MockHerdr` implementing `FleetControl` fully in-memory with realistic async behavior and mutable agent states; used by all tests.
- `HerdrAdapter` implementing the same interface against the real Herdr socket API (see https://github.com/ogulcancelik/herdr docs: socket API, session state, concepts). You may install Herdr locally to integration-test; guard integration tests behind an env flag so CI/tests pass without it.

### Phase 3: Router

- `Router` interface: `route(utterance, snapshot) -> FleetCommand`.
- `DeterministicRouter`: rule/grammar based, must pass every non-fuzzy fixture and correctly classify noise. This is the ablation baseline and the demo fallback.
- `GemmaRouter`: adapter seam for Gemma 4 on Cactus. Implement the full prompt construction (compressed snapshot + utterance + closed-verb output format), a strict JSON output parser with schema validation and one retry, and a transport interface with two backends: (a) `exec` backend calling a configurable local command, (b) HTTP backend for a local inference server. If no local Gemma runtime is available tonight, ship the seam with the transport mocked in tests and document exactly what the Cactus wiring needs in `PROGRESS.md`.

### Phase 4: Command loop + verifier

- `CommandLoop`: utterance in -> route -> (confirmation gate for destructive or low-confidence) -> execute via `FleetControl` -> verify -> emit `CommandOutcome` events.
- `Verifier`: independent `snapshot()` re-read with per-verb outcome predicates (focus changed, message present in target agent's activity, new agent exists with spec, status transitioned, mic state changed). Executor success without verifier pass must yield `UNVERIFIED`, never `SUCCEEDED`.
- Tests: full-loop tests over the fixture set against `MockHerdr`, including a false-success injection test proving the verifier catches a lying executor.

### Phase 5: Console

- Vite + React app in `commandcenter/console/`: dark, minimal, Podium-adjacent styling. Live panels: mic state, last utterance (streaming), routed command card (verb, target, confidence, routing latency), confirmation prompt, fleet snapshot grid, verified command log with per-stage latency (stt/route/act/verify).
- Console talks to a small Node server (`commandcenter/src/server.ts`) over WebSocket; server hosts the CommandLoop against MockHerdr by default, real Herdr behind a flag.
- Browser speech (Web Speech API) as the MVP STT input, plus a text input that simulates utterances for keyboard-only testing and demos. Reuse the `useSpeechRecognition` hook pattern from branch `cursor/voice-state-pipeline` if useful.

### Phase 6: Eval runner + wrap

- `npm run eval`: runs all fixtures through both routers, reports accuracy per category (clear/fuzzy/noise/destructive), false-fire rate on noise, and per-stage latency stats; writes `commandcenter/eval-report.json` and a markdown summary.
- Demo walkthrough doc `commandcenter/DEMO.md` mirroring the PRD's four-minute script, with exact commands to run.
- Final: full test suite green, `PROGRESS.md` complete, push branch.

## Success criteria (the run is judged by these)

1. `cd commandcenter && npm test` green with meaningful coverage of router, loop, verifier.
2. `npm run eval` produces the report; DeterministicRouter >= 100% on clear fixtures and correctly rejects all noise fixtures.
3. Console runs locally (`npm run dev`) and a text-simulated utterance flows end to end: route -> act on MockHerdr -> verified log entry.
4. Zero modifications to the protected VoiceOps files.
5. `docs/PROGRESS.md` tells tomorrow-morning readers exactly what exists, what is stubbed, and what the Cactus wiring still needs.
