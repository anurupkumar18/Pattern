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
## 2026-07-18 (overnight follow-up 2) - Live end-to-end loop SUCCEEDED

- Fixed the deterministic router's reference resolution to match spoken
  aliases against hyphen/underscore agent names ("smoke shell" now resolves
  agent "smoke-shell").
- Ran the full console path against the real Herdr server
  (`HERDR_MODE=real ... npm run dev`, WebSocket utterance
  "switch to the smoke shell"): routed 9.5ms, acted 111ms, verified 110ms,
  final state SUCCEEDED with predicate "focused agent is w2:p2" passing.
- Live artifacts: the herdr session has a `smoke` workspace (w2) with a
  `smoke-shell` agent created by `scripts/smoke-herdr.ts`; the console server
  is running at http://127.0.0.1:4180 against real Herdr.
- Only remaining environment gap: pull a local Gemma model (approval-gated
  download), then `GEMMA_COMMAND=ollama GEMMA_ARGS='["run","<model>"]'` to
  exercise the real-model router path.

## 2026-07-18 (real-model tuning) - Untuned Gemma 4 baseline

- Pulled and loaded `gemma4:latest` through Ollama 0.15. Basic stdin inference
  succeeded with an exact `OK` response; the first cold inference took about
  48 seconds.
- Ran the unchanged real-model command:
  `GEMMA_COMMAND=ollama GEMMA_ARGS='["run","gemma4"]' npm run eval`.
- Baseline accuracy: 0/28 overall; clear 0/15, fuzzy 0/5, noise 0/6,
  destructive 0/2. Noise false-fire rate is reported as 0%, but that is not a
  useful safety result because all 28 routes failed before producing a typed
  command.
- Failure split: 15 outputs failed strict JSON parsing and 13 routes exhausted
  the transport's 30-second timeout. Route p50/p95 are unavailable because the
  evaluator records latency only for completed typed outcomes.
- A direct prompt probe showed that the semantic response was a valid command
  object, but `ollama run` interleaved ANSI cursor-control sequences into
  stdout while streaming JSON. The next isolated change is robust JSON-object
  extraction after terminal-sequence removal, without weakening
  `FleetCommandSchema` validation.
- Baseline artifacts: `commandcenter/eval-report.json` and
  `commandcenter/eval-report.md` (generated `2026-07-18T07:56:36.516Z`).

## 2026-07-18 (real-model tuning) - Gemma 4 plateau at 27/28

- Retained configuration:
  `GEMMA_COMMAND=ollama GEMMA_ARGS='["run","gemma4","--nowordwrap","--think=false"]' npm run eval`.
- Kept code changes: remove ANSI terminal sequences, extract the first balanced
  JSON object from surrounding model text, preserve strict
  `FleetCommandSchema` validation, and make routing boundaries explicit in the
  prompt.
- Measured one-change-at-a-time sequence:
  - Robust JSON extraction: 0/28 -> 1/28. The one completed route took
    13.18s; wrapped newlines inside JSON strings still broke most output.
  - Add `--nowordwrap`: 1/28 -> 16/28. Clear 9/15, fuzzy 1/5, noise 4/6,
    destructive 2/2; route p50 9.50s, p95 14.29s.
  - Add `--think=false`: 16/28 -> 20/28. Clear 9/15, fuzzy 3/5, noise 6/6,
    destructive 2/2; route p50 9.25s, p95 12.84s; all parser/timeouts cleared.
  - Add explicit routing semantics: 20/28 -> 27/28. Clear 14/15, fuzzy 5/5,
    noise 6/6, destructive 2/2; route p50 11.43s, p95 15.59s.
  - Tell the model to omit unspoken optional spawn fields: regressed to 25/28
    (clear 13/15, fuzzy 4/5, noise 6/6, destructive 2/2); reverted.
  - Add one spawn few-shot example: regressed to 24/28 (clear 12/15, fuzzy
    4/5, noise 6/6, destructive 2/2) and introduced three timeouts; reverted.
- The last two changes did not improve the 27/28 best, so tuning stopped under
  the two-change plateau rule.
- Final confirmation on the retained configuration: 27/28 overall; clear
  14/15, fuzzy 5/5, noise 6/6, destructive 2/2; 0% noise false-fire; 27/28
  end-to-end verified. Route latency p50 is 10.46s and p95 is 13.19s.
- The remaining miss is `spawn-clear-3`: Gemma supplies
  `initialMessage: ""` when no initial message was spoken, and strict schema
  validation correctly rejects it. No schema relaxation was accepted.
- Final artifacts: `commandcenter/eval-report.json` contains each utterance's
  expected/actual command and per-route latency; `commandcenter/eval-report.md`
  contains the aggregate readout. Generated `2026-07-18T10:41:24.656Z`.

## 2026-07-18 (routing latency pass) - HTTP retained, model generation dominates

- Starting retained exec result:
  `GEMMA_COMMAND=ollama GEMMA_ARGS='["run","gemma4","--nowordwrap","--think=false"]'`.
  Accuracy 27/28; clear 14/15, fuzzy 5/5, noise 6/6, destructive
  2/2; noise false-fire 0%; route p50 10.46s, p95 13.19s.
- Added an Ollama-native HTTP transport for `/api/generate`, selected by
  `GEMMA_OLLAMA_MODEL`. It sends `stream:false`, keeps the model loaded for
  30 minutes, validates the Ollama `response` field, and has mocked-fetch
  unit coverage. The eval runner makes one untimed warm-up request before
  collecting latency. Server and eval retain the generic exec and HTTP modes.
- One-change-at-a-time measurements:
  - Warmed Ollama HTTP alone (`gemma4`, default generation options): 25/28;
    clear 13/15, fuzzy 4/5, noise 6/6, destructive 2/2; false-fire 0%;
    p50 10.62s, p95 14.53s. Process spawning was not the bottleneck.
  - Add temperature 0, `num_predict:200`, and `think:false`: 27/28; clear
    14/15, fuzzy 5/5, noise 6/6, destructive 2/2; false-fire 0%; p50 10.25s,
    p95 14.06s. No truncation occurred.
  - Compress the prompt and fleet field names: 12/28; clear 6/15, fuzzy 4/5,
    noise 2/6, destructive 0/2; false-fire 0%; p50 10.61s, p95 14.79s.
    Reverted. Although prompt tokens fell from roughly 418 to 305, validation
    retries erased the input-time savings.
  - Pulled and tested `gemma4:e2b-it-qat` (4.3 GB): 23/28; clear 12/15,
    fuzzy 3/5, noise 6/6, destructive 2/2; false-fire 0%; p50 4.82s,
    p95 6.45s. Faster but below the 27/28 accuracy floor, so not retained.
- A later full-model confirmation immediately after the smaller-model and
  repeated sustained runs held 27/28 but thermally degraded to p50 19.23s,
  p95 28.65s. `ollama ps` showed only `gemma4` loaded, so this is recorded as
  runtime variance, not an improvement claim. A clean retained-config rerun
  after the runtime recovered produced 27/28, 0% false-fire, p50 10.03s, and
  p95 12.99s. That is the final and best qualifying result.
- Plateau stop: prompt compression and the smaller model were two consecutive
  non-qualifying attempts. The under-2-second target was not achievable with
  the qualifying `gemma4` model on this machine. Ollama logs show about
  4-5 seconds each for prompt evaluation and 39-46 output tokens near the
  best run, so persistent HTTP removes little of the dominant work.
- Recommended invocation:
  `GEMMA_OLLAMA_MODEL=gemma4 GEMMA_OLLAMA_TEMPERATURE=0 GEMMA_OLLAMA_NUM_PREDICT=200 GEMMA_OLLAMA_THINK=false npm run eval`
  (or `npm run dev`). The retained final measurement is 27/28, 0% noise
  false-fire, p50 10.03s, p95 12.99s.

## 2026-07-18 (cascade routing) - Fast path plus honest fallback numbers

- Added a provenance-stamped `CascadeRouter`: deterministic actionable
  commands return immediately; every deterministic noise result escalates,
  including unresolved command-shaped speech and no-grammar matches. Gemma
  errors or the configurable 20-second deadline fall back to deterministic
  noise without throwing.
- Full warmed-model command:
  `GEMMA_OLLAMA_MODEL=gemma4 GEMMA_OLLAMA_TEMPERATURE=0 GEMMA_OLLAMA_NUM_PREDICT=200 GEMMA_OLLAMA_THINK=false npm run eval`.
- Cascade accuracy: 28/28 overall; clear 15/15, fuzzy 5/5, noise 6/6,
  destructive 2/2; 0% noise false-fire; 28/28 end-to-end verified.
- The deterministic tier answered 22/28 with route p50 0.09ms and p95 2.03ms.
  Six cases escalated, all ambient-noise fixtures in this matrix; Gemma-tier
  route p50 was 9.36s and p95 was 10.60s. No Gemma call failed or timed out.
- Pure Gemma remained 27/28: clear 14/15, fuzzy 5/5, noise 6/6, destructive
  2/2; route p50 10.50s and p95 13.52s. The unchanged miss was
  `spawn-clear-3`, where Gemma emitted `initialMessage: ""` and strict schema
  validation rejected it.
- Important fixture limitation: the current five fuzzy fixtures are already
  resolved by the deterministic grammar, so this run does not show a
  Gemma-rescued fuzzy case. It proves the cascade fast path, provenance,
  escalation, and safe fallback contract; broader unusual-wording fixtures
  are still needed to measure semantic rescue lift.
- Proof: `npm test` passes 28 tests in 8 files with 1 real-Herdr test skipped;
  `npm run build` passes. Generated reports:
  `commandcenter/eval-report.json` and `commandcenter/eval-report.md`
  (`2026-07-18T11:47:53.806Z`).

## 2026-07-18 (mandatory stack closure) - Gemma 4 running on Cactus

- Installed Cactus 2.0.1 with
  `brew install cactus-compute/cactus/cactus`.
- Downloaded the public 3.8 GB CQ4 bundle with
  `cactus download google/gemma-4-E2B-it --bits 4`; Cactus resolved it to
  `~/.cache/cactus/weights/gemma-4-e2b-it-cq4`. No interactive approval,
  Cactus key, Hugging Face token, or cloud model was required.
- Retained interface: the persistent OpenAI-compatible local server,
  `cactus serve google/gemma-4-E2B-it --bits 4 --backend metal
  --no-cloud-handoff --no-cloud-tele`. The new
  `commandcenter/scripts/cactus-complete.py` bridge reads a prompt on stdin,
  POSTs it to `/v1/chat/completions`, and prints only the completion on stdout.
  Existing `ExecGemmaTransport` is unchanged.
- Hackathon-compliant eval command:
  `GEMMA_COMMAND=python3 GEMMA_ARGS='["scripts/cactus-complete.py"]'
  CACTUS_MODEL=google/gemma-4-E2B-it npm run eval`.
- Initial unchanged-prompt Cactus baseline: Gemma-only 20/28; clear 10/15,
  fuzzy 3/5, noise 6/6, destructive 1/2; route p50 8.42s, p95 20.05s.
  Cascade stayed 28/28; deterministic tier p50 0.36ms/p95 4.05ms and
  Cactus/Gemma tier p50 5.54s/p95 6.42s.
- Used the permitted single tuning round to add a Cactus system instruction
  reinforcing exact message extraction, spawn fields, and interrupt versus
  listen-control semantics. Final Cactus result: Gemma-only 23/28; clear
  13/15, fuzzy 3/5, noise 6/6, destructive 1/2; 0% noise false-fire; route
  p50 11.88s, p95 20.89s. Cascade remained 28/28 across clear 15/15, fuzzy
  5/5, noise 6/6, destructive 2/2; cascade route p50 0.19ms/p95 4.96s,
  deterministic tier p50 0.17ms/p95 2.60ms, and Cactus/Gemma tier p50
  4.81s/p95 5.45s. No Cactus call failed or timed out.
- Honest comparison: Ollama-hosted full `gemma4` remains more accurate and
  more consistent in the pure-model lane at 27/28, p50 10.03s, p95 12.99s.
  Cactus E2B closes the mandatory hackathon stack gap and preserves cascade
  28/28, but pure-model accuracy is four cases lower and tail latency is
  materially worse. Tuning stopped after the one allowed round.
- Final artifacts: `commandcenter/eval-report.json` and
  `commandcenter/eval-report.md` generated `2026-07-18T14:50:23.285Z`.

## 2026-07-18 — Console redesigned verbatim to Herdr

Cole feedback: console should look exactly like Herdr, with a voice-control
on/off button below the sidebar agent list.

- Extracted Herdr's real design tokens from its source (not approximated):
  - Palette: `Palette::catppuccin()` in `src/app/state.rs` (Catppuccin Mocha,
    panel_bg #181825, surface_dim #1e1e2e, text #cdd6f4, accent/blue #89b4fa,
    green #a6e3a1, yellow #f9e2af, red #f38ba8, teal #94e2d5).
  - State glyphs + colors: `agent_icon`/`state_label_color` in
    `src/ui/status.rs` (blocked ◉ red, working braille spinner yellow,
    done ● teal, idle ✓ green, unknown ○ overlay0). Spinner frames from
    `src/ui.rs` at ~8fps, replicated in React.
  - Sidebar layout: `render_agent_detail` in `src/ui/sidebar.rs` + herdr.dev
    sidebar screenshots (saved to `console/reference/`): "agents" header with
    "all" toggle, row 1 = icon + bold name, row 2 = colored state · agent,
    " · " separators, active row bg surface_dim.
- Rewrote `console/src/App.tsx` and `styles.css`: monospace terminal layout,
  Herdr sidebar left, pane with tab bar + shell-style ❯ prompt right.
- Added voice toggle pinned below the agent list: ○ voice off (overlay0) /
  ● voice on (green dot), herdr-style bordered row. Wired to the existing
  Web Speech recognition start/stop.
- Verified: console tsc clean, WS snapshot live against real Herdr
  (smoke-shell agent renders), headless Chrome screenshot matches reference.

## 2026-07-18 - Unified recent chat sources

- Added one read-only `ChatSourcesProvider` that merges the existing Cursor
  SQLite feed with Claude Code JSONL sessions and Codex CLI rollout JSONL
  sessions, sorted newest first behind the existing `cursor.chats` WebSocket
  event.
- Claude and Codex poll by directory metadata, cache parsed entries by mtime,
  and only reread files that changed. Titles prefer stored summary/session
  metadata and fall back to the first human user message. Files touched within
  two minutes render as working; older file sessions render as done.
- Updated the Herdr-style chat row to show
  `state · cursor|claude|codex · relative time` without changing the rest of
  the console.
- Added 10 focused parser, partial-line, active-state, and merge tests. Full
  proof: 38 tests passed in 9 files, 1 opt-in real-Herdr test skipped;
  `npx tsc -p tsconfig.json` and
  `npx tsc -p console/tsconfig.json --noEmit` passed.
- Live 24-hour WebSocket snapshot on the demo machine: 15 Cursor, 0 Claude,
  and 0 Codex entries. The newest source files were outside the strict window
  (Claude: 2026-07-10T17:56:57Z; Codex: 2026-07-17T14:26:36Z), so fabricating
  entries or widening the product contract was intentionally avoided.
  `/tmp/console-multisource.png` confirms the populated sidebar and source
  label rendering. No source was stubbed.

## 2026-07-18 - Chat sources hardening and live proof

- Tightened the file-session liveness window to 45 seconds (was 2 minutes) so
  a Claude/Codex session only shows the braille working spinner while its
  JSONL file is actively being appended.
- Added a per-source cap (10 newest per source) in the merged broadcast so a
  busy harness (24 Cursor chats today) cannot crowd Claude/Codex entries out
  of the sidebar list.
- Name extraction now skips harness-injected first messages (text starting
  with "<", e.g. `<local-command-caveat>` / `<recommended_plugins>` blocks)
  and falls back to the first human-typed message.
- Added `CHATS_WINDOW_MS` env override on the server. Default stays 24h; the
  demo server on :4180 runs with a 10-day window because the newest Claude
  session on this machine is from 2026-07-10 and the newest Codex rollout from
  2026-07-17, both outside the strict 24h window.
- Live proof over ws://127.0.0.1:4180/ws: merged `cursor.chats` snapshot with
  22 entries (10 cursor, 10 codex, 2 claude); headless Chrome DOM shows all
  three source tokens rendering Herdr-style (`done · codex · 25h ago`);
  screenshots at /tmp/console-allchats.png and /tmp/console-allchats-tall.png.
- Checks: `npx tsc -p tsconfig.json`, `npx tsc -p console/tsconfig.json
  --noEmit`, and `npm run test` (38 passed, 1 opt-in Herdr test skipped) all
  clean, including new parser/merge/cap unit tests in
  `test/chat-sources.test.ts`.

## 2026-07-18 - Dictator console rebuild completed

- Resumed the interrupted uncommitted rebuild rather than replacing it. The
  inherited work already contained the componentized React shell, unified
  Cursor/Claude Code/Codex history, design tokens, source glyphs, voice
  recognition, command staging, verb-chip HUD, help, switcher, toasts, and
  WebSocket reducer.
- Finished the product pass: the live focused agent now controls both selected
  row and main detail, old completed chats no longer appear falsely unseen,
  history groups are exactly Today/Yesterday/Earlier, capture locks its message
  target, Option-Space toggles voice, stopped stays neutral, and command
  outcomes no longer leak into unrelated chat details.
- Fixed two live-only defects found through browser evidence: duplicate Codex
  session IDs are deduplicated newest-first before rendering, and both app
  regions now constrain flex height so the composer and voice footer remain
  inside the viewport.
- The top-right HUD keeps Move, Send, and What needs me visible; cluster hover
  reveals Interrupt, New chat, and Voice; pill hover reveals help text. Routed
  verbs pulse, resolved rows glow, unresolved targets shake, Send gets a
  cancelable hold, and the global bar stages the parse before dispatch.
- No transcript data was fabricated. The detail pane uses a quiet source-app
  handoff state because the current protocol exposes chat metadata but not
  messages.
- Required proof passes:
  `npx tsc -p tsconfig.json`,
  `npx tsc -p console/tsconfig.json --noEmit`,
  `npm test` (42 passed, 1 opt-in real-Herdr test skipped), and
  `npm run build`.
- Visual proof was iterated in headless Chrome against the real feed and
  compared with the Cursor/Codex references. Exact 1440x900 captures:
  `/tmp/dictator-final.png` and `/tmp/dictator-hud.png`.
- Live review server:
  `http://127.0.0.1:4180`, real Herdr socket, seven-day chat window, and
  `gemma4:e2b-it-qat`.
- Honest remaining gaps: chat transcript/message detail still needs a protocol
  addition; read/unseen state is client-local; the feed is a bounded seven-day
  snapshot rather than paged lifetime history; historical file-session rows
  are metadata views, while live control targets remain Herdr agents; Web
  Speech support still varies by browser.

## 2026-07-18 - Read-only conversation history and live refresh

- Added the backward-compatible `chat.messages.request`, `chat.messages`, and
  `chat.messages.error` WebSocket surface for selected Cursor, Claude Code, and
  Codex conversations. The existing `cursor.chats` metadata feed is unchanged.
- Cursor reads the ordered, renderable `fullConversationHeadersOnly` index and
  fetches only visible bubble text through read-only SQLite. Claude and Codex
  readers emit only visible user/assistant text blocks from their JSONL event
  lanes. Thinking, reasoning, system/developer instructions, tool
  calls/results, attachments, simulated messages, and harness-injected records
  are excluded.
- The console requests immediately on selection and polls only that chat every
  2.5 seconds. Claude/Codex cache by file mtime and size; Cursor caches by the
  selected composer's `lastUpdatedAt`; overlapping reads are coalesced and
  unchanged responses are fingerprint-deduplicated.
- The detail pane now renders stable keyed turns with loading, empty, and local
  error states. It preserves manual scroll position and follows new turns only
  when already near the bottom.
- Synthetic parser/protocol/error tests pass. Full proof: 52 tests passed in 11
  files, 1 opt-in real-Herdr test skipped; both required TypeScript checks and
  the production build passed.
- Live `ws://127.0.0.1:4180/ws` proof returned Cursor 185 messages (54 user,
  131 assistant) and Codex 9 messages (1 user, 8 assistant), with zero
  unchanged refresh responses. Claude was unavailable in the configured
  seven-day metadata window; its newest local session predates that window.
  No message text was printed or captured.

## 2026-07-18 - Wave 1B activity and Library cleanup

- Extended the shared chat metadata with optional live `activity` and required
  `human` / `automation` / `system` classification. Claude and Codex labels
  come from the final synthetic event shape (`Thinking`, `Running tools`,
  `Responding`, or `Working…`) and are cleared as soon as the active-mtime
  heuristic expires.
- Kept Cursor inspection read-only (`mode=ro`). Composer and bubble markers
  now produce the same generic labels without exposing hidden reasoning text.
  Replacing the full-table key scan with an indexed composer-key range reduced
  the seven-day live query from timeout to about 3.3 seconds.
- Untitled rows now use the first visible user turn, truncated to 48
  characters, with `New chat` only when no visible turn exists. The live feed
  contained zero `(untitled)` labels.
- The default Library now contains human rows only. Automation chats are in a
  collapsed bottom section with a count; system rows and smoke/test Herdr
  agents are hidden. The sidebar attention row was removed while its command
  and model helpers remain intact.
- Live WebSocket proof after restart: 81 chats total, 31 human, 50 automation,
  0 system; source split 29 Cursor, 2 Claude, 50 Codex. No source was actively
  generating in the final snapshot; an earlier active Claude sample emitted
  the safe fallback `Working…`.
- Verification: backend and console TypeScript checks passed; Vitest passed
  73 tests with 1 opt-in test skipped. The live 1440x2000 screenshot at
  `/tmp/w1b.png` was inspected: no attention row or untitled labels, and the
  collapsed `Automations · 50` section appears at the bottom.

## 2026-07-18 - Wave 1A transcript fidelity and faster sync

- Added a dependency-free, React-escaped markdown renderer for headings,
  emphasis, lists, safe links, inline code, and fenced code blocks. Raw HTML is
  never interpreted, and unsafe link schemes remain plain text.
- Cursor, Claude Code, and Codex readers now emit optional collapsed thinking
  blocks and quiet activity labels. Tool arguments and tool-result content are
  not exposed; only bounded tool names become labels.
- Removed the duplicate title inside the transcript. The app header remains the
  single conversation title, while the transcript stays centered at a readable
  760px measure.
- Added a one-second selected-chat server poll backed by the existing Cursor
  `lastUpdatedAt` and file mtime/size short circuits. Stable message keys,
  memoized turns, and near-bottom-only autoscroll preserve reading position as
  new content arrives.
- Browser iteration caught and fixed two live defects: recursive inline
  formatting could reset a shared regex cursor and stall rendering, and
  response deduplication could suppress a chat when switching away and back.
- Verification passed: both required TypeScript checks, 73 Vitest tests with 1
  opt-in test skipped, and 3 focused synthetic extras tests. A real local chat
  rendered 149 markdown nodes and 27 activity rows with zero duplicate
  transcript titles. The inspected 1440x900 screenshot is
  `/tmp/w1a-final.png`.
- Remaining evidence gap: the selected real Claude sample had activity events
  but no readable thinking text, so collapsed thinking behavior is covered by
  synthetic parser fixtures rather than that screenshot.

## 2026-07-18 - Wave 1E same-session send adapter

- Added a detached, stdin-only send adapter for dormant Claude Code and Codex
  CLI sessions. It resolves the existing JSONL by source/session UUID,
  extracts the original cwd, rejects files modified in the last 10 seconds,
  and holds an in-process lock until the child exits.
- Added WebSocket command
  `{ type: "chat.send", chatId, source: "claude" | "codex", text }` and
  broadcast result `{ type: "chat.send.result", chatId, ok, error? }`.
- Synthetic proof covers Claude project-scoped lookup, Codex dated rollout
  lookup, malformed IDs, truncated JSONL, and source-specific cwd extraction.
- Verification: backend and console TypeScript checks passed; Vitest passed
  73 tests with 1 opt-in test skipped.
- Live Claude smoke selected the most recent session idle for at least 60
  seconds. The user turn appended to the same JSONL, but Claude returned the
  account-level organization monthly spend-limit error instead of `pong`.
  A fresh Sonnet session failed at the same account-level gate.
- Live Codex smoke first exposed a desktop/CLI rollout compatibility error
  (0.144 desktop store versus installed 0.135 CLI). Retrying a 0.135 rollout
  appended the user turn to the same JSONL, but that automation rollout
  completed with no assistant message. Same-file user append is proven for
  both sources; end-to-end assistant reply remains environment-blocked.

## 2026-07-18 - Wave 1D fully local streaming STT

- Replaced the rejected browser/network speech dependency with a standalone
  loopback STT process in `commandcenter/stt/`. It accepts PCM16 mono 16 kHz
  audio at `ws://127.0.0.1:4191`, gates utterances with local RMS VAD, and
  emits `{type:"interim"|"final", text, tMs}`. Finals fire after about one
  second of silence; `stop` flushes immediately.
- Built pinned whisper.cpp `v1.7.6` with `GGML_METAL=ON`. Runtime proof on the
  Apple M4 reports `using Metal backend`, `found device: Apple M4`, and a
  487 MB Metal allocation for `small.en`. Both `ggml-base.en.bin` and
  `ggml-small.en.bin` are downloaded locally and gitignored.
- The bridge keeps whisper.cpp's HTTP backend warm on loopback port 4192,
  transcribes in-memory growing WAV snapshots for interims, and never sends
  audio off the Mac. No console or control-plane file was changed.
- Benchmarked three Samantha-generated command WAVs with visible-chat
  vocabulary hints. `base.en` averaged 1063 ms to first interim and 2475 ms
  from speech end to final, with 2/3 exact transcripts (`evals` became
  `Evels`). Eight-thread `small.en` averaged 2974 ms and 4614 ms, with 3/3
  exact transcripts. Recommendation: `small.en` for demo routing because a
  wrong chat target is worse than its latency cost; retain `base.en` as the
  speed fallback after safe alias matching exists.
- End-to-end WAV proof produced
  `{"type":"interim","text":"Moved","tMs":8034}` then
  `{"type":"final","text":"Move to evals.","tMs":9289}`. Tail latency varied
  under concurrent local model load; the benchmark table and exact console
  integration contract are in `commandcenter/stt/README.md`.
- Validation: shell syntax, Node syntax, Metal linkage, both model downloads,
  VAD interim/final streaming, exact vocabulary-biased final text, and a live
  listener on `127.0.0.1:4191` all pass.
- Honest gap: this is streaming PCM plus repeated utterance-window inference,
  not a stateful incremental Whisper decoder. Native decoder-state reuse is
  the next latency optimization.

## 2026-07-18 - Command Center integration

- Wired the main composer directly to `chat.send` for selected Claude Code and
  Codex chats. It now shows quiet `Sending…`, `Sent`, or CLI error feedback.
  Cursor chats disable the textarea, remove the send button, and show
  `Mirrored from Cursor (read-only)`.
- Routed staged voice `tell` / `send` / `dictate` commands to the same
  `chat.send` path when the resolved sidebar target is a Claude or Codex chat.
  Fleet-agent commands continue through the existing command loop.
- Corrected Wave 1E's detached optimistic result behavior: the adapter now
  waits for the resumed CLI turn, captures bounded CLI diagnostics, and reports
  failure text to the requesting browser only. Codex resumes use
  `--skip-git-repo-check` plus `CODEX_RESUME_MODEL` (default `gpt-5.5`).
- Codex round trip is proven in rollout
  `019f667b-45b5-71f0-8dd7-af6617031f46`. Installed CLI `0.135.0` failed with
  HTTP 400 when inheriting `gpt-5.6-sol` because that model requires a newer
  CLI. Retrying the same rollout with `-m gpt-5.5` appended a new user turn and
  assistant `pong` to the same JSONL; `codex exec` exited 0.
- Restarted port 4180 from the merged tree with real Herdr and the requested
  Gemma/Ollama settings. A live WebSocket opened and returned 81 chats. The
  reconnect banner was absent on initial load and after selecting both Claude
  and Cursor conversations.
- Final Chrome proof is `/tmp/integrator-final.png` at 1440x900 after a 9-second
  virtual-time budget. Inspection shows the cleaned human-chat sidebar with
  activity labels, `Automations · 50` collapsed, a selected Claude transcript,
  readable assistant spend-limit text, and the writable composer. A separate
  live DOM check proved the selected Cursor composer is disabled, has the
  read-only hint, and contains no send button.
- Final verification: both TypeScript checks pass; Vitest passes 73 tests in 13
  files with 1 opt-in test skipped; `git diff --check` passes.
