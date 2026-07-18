# Voice Command Center for Agent Fleets (working title)

**Version:** 1.0 (pivot proposal)
**Status:** For team decision, then build
**One-line pitch:** A developer runs five coding agents at once. This is the voice layer that lets them command the whole fleet without touching a keyboard: hear what needs attention, switch focus, answer a blocked agent, spawn a new one, and see every command verified against real session state.

## 1. Why this pivot

The prior VoiceOps direction (see `docs/PRD.md`) is a general macOS computer-use agent. It is well specified, but it has three structural problems for this hackathon:

1. **Mandatory stack.** The official rules require every team to use Gemma 4 on Cactus. VoiceOps as specified does not use either; its intelligence lives in cloud multimodal models. This pivot puts Gemma-on-Cactus at the center: it is the router that turns speech into fleet commands, fully on-device.
2. **Judged tracks.** The "Deepest Technical Integration" special track explicitly rewards "novel routing, multi-agent on-device setups." A voice-routed multi-agent command center is a literal match. Screen understanding and generic computer actions are examples in the brief, not requirements.
3. **Niche and novelty.** We already agreed in person to niche to developers because judges are developers and general desktop assistants are the named "biggest mistake." Clicky won attention by inventing an interaction primitive (screen as prompt, cursor as pointer). Our primitive: **the agent fleet as a single conversational surface.** Nobody demos talking to five agents as one organism. Everyone will demo talking to one agent that clicks buttons.

## 2. What VoiceOps contributes (this is a surface swap, not a restart)

The VoiceOps scaffolding already in this repo carries over almost entirely, because its spine is action-surface-agnostic:

| VoiceOps component | Role in the command center |
| --- | --- |
| Speak -> Ground -> Plan -> Act -> Verify loop | Identical loop; "ground" resolves utterances against the live fleet snapshot instead of the screen |
| Executor/verifier separation (CLAUDE.md invariant 2) | Kept verbatim: no command reports success until an independent read of Herdr session state proves the outcome |
| Typed IPC envelopes and JSON schemas (`schemas/`) | Kept; new command/verification payload types are added beside the existing ones, same Pydantic-as-source-of-truth pipeline |
| Python sidecar (`agent/`) | Becomes the router host: runs the Gemma-on-Cactus classifier and the verifier |
| Risk gating and approval (invariant 5) | Kept: destructive fleet ops (kill agent, close workspace, interrupt mid-write) require spoken confirmation |
| Evaluation runner and 28-case plan | Re-targeted: the eval suite becomes a command-grammar suite (utterance -> expected command JSON) which is even easier to score objectively |
| Voice capture design (FR-1: push-to-talk, partials < 500 ms, cancel words) | Kept as spec for the voice loop |

What gets dropped: screen capture, OCR, accessibility trees, EventKit/AppleScript/Playwright action channels, the six-channel executor. That is the majority of the risk and the schedule, removed.

## 3. The product

A developer working with an agent fleet in [Herdr](https://github.com/ogulcancelik/herdr) (terminal multiplexer for AI agents: workspaces, panes, agent status, session persistence, socket API) keeps a hot mic open. The system continuously listens, and every utterance is classified on-device by Gemma into one of a small closed set of fleet verbs or discarded as ambient noise.

### Command verbs (MVP grammar)

| Verb | Example utterance | Effect via Herdr |
| --- | --- | --- |
| `status` | "what needs me right now" | Reads fleet snapshot, speaks/renders which agents are blocked or done |
| `focus` | "switch to the migration agent" | Focuses the referenced pane |
| `send` | "tell the test agent to rerun just the auth suite" | Delivers message text to the referenced agent's pane |
| `spawn` | "open a new claude in the api repo" | Creates a new agent pane with the named harness and cwd |
| `interrupt` | "pause the deploy agent" | Sends interrupt to the referenced agent (confirmation required) |
| `listen_ctl` | "stop listening" / "hey, listen up" | Gates the mic loop |
| `dictate` | (while focused) free speech streams into the focused agent | Passthrough mode, the Claude Code "it can hear you" feature generalized to every harness |

### Reference resolution is the hard, demo-visible intelligence

"The migration agent," "the one that's blocked," "the second claude" have no fixed mapping. The router receives the live fleet snapshot (agent names, harnesses, statuses, last-activity summaries) plus the utterance, and Gemma resolves the reference. This is exactly the ambiguity-resolution capability Anurup's PRD prized (FR-2), applied to a tractable, enumerable target space instead of arbitrary screen pixels, which is why it can run on a small on-device model.

### The loop, per utterance

1. **Hear:** streaming transcript (push-to-talk or hot mic with VAD).
2. **Route:** Gemma 4 on Cactus classifies utterance + fleet snapshot into a typed `FleetCommand` JSON (or `noise`). Deterministic grammar fallback exists for dev and as an ablation baseline.
3. **Preview:** console shows heard text, resolved verb, resolved target, confidence. Low confidence or destructive verbs wait for spoken confirmation.
4. **Act:** command executes through the Herdr socket API.
5. **Verify:** independent re-read of session state proves the outcome (focus changed, message appeared, agent spawned, status changed). Verifier result, not executor return, marks success.
6. **Evidence:** command log row with latency breakdown (STT / route / act / verify) and pass-fail predicate.

## 4. Architecture

```
 mic ──▶ Voice loop (streaming STT, VAD, cancel words)
              │ utterance
              ▼
 Router: Gemma 4 on Cactus  ◀── fleet snapshot (agents, statuses, labels)
              │ FleetCommand JSON (typed, schema-validated)
              ▼
 Control plane: Herdr socket API adapter
   focus / send / spawn / interrupt / subscribe
              │
              ▼
 Verifier: independent session-state read, outcome predicates
              │
              ▼
 Console: heard -> resolved -> target -> verified evidence log
```

- **Router host:** Python sidecar (`agent/`), consistent with existing scaffolding. Cactus bindings live here; a deterministic fallback classifier ships first so everything is testable before Cactus wiring.
- **Control plane:** thin adapter over the Herdr socket API, plus a mock Herdr server implementing the same interface so the entire system runs and tests without Herdr installed.
- **Console:** minimal web view. Herdr itself is the primary visible surface in the demo; our console is the "visible thinking" panel the judges require (what was heard, how it was routed, token/latency cost, verification result).

## 5. Rubric mapping (100 points)

- **Value (25):** the "wall behavior" problem: developers babysit agent fleets, scanning panes for the one that is blocked. One spoken sentence replaces find-the-pane, click, type, and the status sweep. Measurable: time from "agent blocked" to "unblocked" with and without voice.
- **Inputs & Data (15):** inputs are the mic and the fleet snapshot, both local, both displayed live in the console with provenance. No screen scraping, no cloud transcripts of your codebase. Clean privacy story: routing never leaves the device.
- **Enablement (20):** zero-setup demo: start herdr, start the command center, talk. States (listening, routing, awaiting confirmation, acting, verifying) visually distinct, inherited from VoiceOps UX spec.
- **Underlying Model (20):** Gemma is load-bearing, not decorative: closed-verb classification plus open reference resolution over a live snapshot. Ablation is built in: deterministic-grammar mode fails the fuzzy-reference test cases that Gemma passes.
- **Evidence & Evaluation (20):** command-grammar eval suite (recorded utterances -> expected command JSON), success rate, false-fire rate on ambient noise, per-stage latency, plus the verifier's zero-false-success invariant carried over from VoiceOps.

## 6. Four-minute demo script

1. (0:00) Herdr session with four agents already working: two Claude Code, one Codex, one test runner. Hot mic on.
2. (0:30) "What needs me?" Fleet status spoken back: one agent blocked on a question.
3. (1:00) "Switch to it. " Focus jumps. "Tell it to use the staging database, not prod." Message lands, agent resumes. Verifier ticks green.
4. (1:45) "Open a new codex in the docs repo and have it draft the readme." Spawn + first instruction, verified.
5. (2:30) Ambient conversation with a teammate. Console shows utterances classified as noise, zero false fires.
6. (3:00) "Pause the deploy agent." Confirmation gate: "That interrupts a running agent, say confirm." "Confirm." Interrupt lands, verified.
7. (3:30) Console recap: command log, latency breakdown, eval suite numbers, all routing on-device.

## 7. Proposed work split

- **Voice loop + router contract + console (Cole side):** streaming STT, hot-mic gating, `FleetCommand` schema, deterministic fallback, console UI.
- **Cactus/Gemma integration + eval suite (Anurup side):** Cactus runtime wiring, prompt/format for the router, the recorded-utterance eval suite, latency tuning. This preserves his eval and contract investment directly.
- Split is a proposal; the interface between the halves is the `FleetCommand` schema plus the classifier interface, so both sides can build in parallel against fixtures immediately.

## 8. Scope

**MVP:** the seven verbs above against real Herdr; Gemma-on-Cactus router with deterministic fallback; verifier; console; eval suite.
**Stretch:** dictation passthrough polish, spoken TTS responses, agent-initiated interjections ("the test agent just failed"), multi-workspace routing.
**Out of scope:** screen understanding, OCR, browser control, general macOS app automation, anything requiring Accessibility permissions.

## 9. Risks

1. **Cactus + Gemma latency for routing.** Mitigation: tiny closed-verb output format, snapshot compression, and the deterministic fallback keeps the demo alive regardless.
2. **Herdr socket API surprises.** Mitigation: adapter interface + mock server; worst case the demo runs against the mock with real terminals visible.
3. **Hot-mic false fires during the demo.** Mitigation: noise class is a first-class eval target; push-to-talk is a one-flag fallback.
4. **STT quality in a noisy demo room.** Mitigation: headset mic; cancel words; confirmation gates on anything destructive.
