# VoiceOps

Speak the outcome. VoiceOps sees the current screen, completes the work on the real Mac, and proves the requested result occurred.

VoiceOps is a voice-first macOS action agent: press a hotkey, speak a goal, and VoiceOps interprets the live screen, plans a safe sequence of actions, operates native Mac applications, and independently verifies the resulting state.

**Core loop:** Speak → Ground → Plan → Preview risk → Act → Observe → Verify → Report evidence

## Status

The current hero slice is **Conversational VoiceOps: Order Rescue**. With Order #1842 and Maya Chen visible, ⌃⌥V opens a bounded speech-to-speech session with semantic turn taking and barge-in. VoiceOps compiles a persistent v1 task through a typed sidecar tool, accepts an improvised mid-flight correction as a visible v1→v2 patch, reads back the exact consequential action set, and accepts either strict spoken confirmation or the equivalent bound click. It then streams an Observed/Interpreted/Decided/Acted/Verified ledger and reports success only after five positive and two negative refetch checks. Shopify and Slack are live only when their Keychain credentials exist and both health probes pass; otherwise the ledger visibly names the fixture fallback. Customer email remains sandboxed. The live follow-up reminder is a real EventKit write with five native checks.

`scripts/rehearse_order_rescue.sh` is the one-command repository gate: Python and Swift suites, cross-runtime exchange, two 27-case deterministic safety reports, a signed native-app replay receipt, and an app-authored terminal screenshot. GitHub CI independently builds, signs, launches, and retains the evidence artifacts. These automated results do not claim a live microphone, TCC, Shopify, Slack, or stage-acoustics trial.

With **Conversational voice** enabled, OpenAI Realtime uses full-duplex 24 kHz PCM, the `marin` voice, semantic VAD, echo cancellation, and immediate playback flush on user speech. A failed session falls back visibly to the retained ADR-021 pipeline without discarding an active task. That pipeline still uses `gpt-realtime-whisper` plus a bounded `gpt-4o-transcribe` refinement and can fail over to Apple Speech while preserving the transcript prefix. The flagship live vision and LLM compiler default is `gpt-5.6-sol`; deterministic grounding and compilation remain offline-safe.

Phase 7 — Evaluation and demo hardening is implemented. `scripts/run_evals.sh` runs the complete unit/contract suites, Swift↔Python exchange, and a 27-case cross-runtime correctness evaluation, then regenerates [latest.md](evals/reports/latest.md) and [latest.json](evals/reports/latest.json). The full Order Rescue rehearsal adds 27 runs covering spoken mishears, stale approval hashes, v2→v3 barge-in patches, unknown tools, unhealthy live adapters, execute replay, and conversational panic stop, then regenerates the offline [evaluation dashboard](evals/dashboard.html). Thresholds remain zero false successes, duplicate side effects, unapproved actions, and post-stop effects. Live microphone/TCC/native-app latency trials remain explicitly unmeasured.

Phase 6 — Recovery and hardening is implemented. During every active state, a CGEvent-level global Escape panic stop cancels the sidecar and queued work even when the companion is not focused (with the panel shortcut as a fallback). A deterministic recovery policy classifies permissions, stale targets, closed apps, no-op/timeouts, ambiguous state, and uncertain writes; reversible reminder/briefing actions receive at most one retry, while consequential, destructive, or uncertain actions never retry. Task-marker lookups make those retries idempotent, and the expandable task timeline exposes action channels, durations, recoveries, verification, and final outcome.

Phase 5 — Research-to-Follow-Up is implemented. VoiceOps extracts at most eight visible public-web company links, rejects local/private targets, researches with at most four concurrent bounded reads, ranks exactly three recommendations, and previews three next-week dates. Nothing is written until the user selects **Approve Schedule**. It then creates one escaped, cited Notes comparison and exactly three EventKit reminders, refetches both stores, and requires all five predicates before reporting success. A denied approval produces no writes; an uncertain partial write is never retried automatically.

Phase 4 — Meeting Briefing remains available as an additional verified workflow. VoiceOps selects the next upcoming non-all-day event through EventKit, creates a structured Apple Note with Meeting, Participants, Context, Open Questions, and Sources sections, escapes all untrusted screen content before it enters Notes HTML, reveals the exact note, then refetches both the event and note for five independent checks. A moved event, stale note, missing section, or failed UI reveal cannot produce success.

Phase 3 — Screen-to-Reminder is implemented. From the grounded Mail deadline, the sidecar extracts a typed reminder plan, the macOS app performs one reversible EventKit write, opens the exact reminder through Reminders’ scripting interface, fetches the committed item back, and reports five visible predicate checks. An executor result can never complete the task; only unanimous verifier evidence produces `succeeded`. The deterministic fixture, cross-runtime protocol, wrong-date/hidden-UI failures, and app build are automated; a first permissioned live run is still required on each Mac.

Phase 2 — screen context and grounding is complete. The app captures the active window on demand with ScreenCaptureKit, collects and prunes the visible Accessibility tree, and shows grounded-reference chips with native provenance. OpenAI vision grounding uses strict structured output with a Keychain-backed credential; deterministic grounding remains the offline and provider-failure fallback.

Phase 1’s voice shell remains intact: global hotkey (⌃⌥V), streaming system speech capture, floating companion with deterministic session states, global stop/Escape cancellation, and spoken progress. See `docs/` for the full spec:

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

cd agent && uv run python -m pytest     # Python tests
cd macos && swift test        # Swift tests
cd macos && swift run voiceops-mock-client   # end-to-end mock exchange
scripts/run_evals.sh          # all checks + 27-case JSON/Markdown report
scripts/rehearse_order_rescue.sh  # full gate + Order Rescue safety rehearsal
scripts/replay_order_rescue_app.sh # signed native app → sidecar → receipt E2E
```

### Run the app

```sh
scripts/run_app.sh            # builds with the CLI toolchain and launches — no Xcode IDE needed
```

(Opening `macos/VoiceOps.xcodeproj` in Xcode works too, but is optional.) On first use, grant the Microphone, Speech Recognition, Screen Recording, Accessibility, Calendars, Reminders, and Automation prompts. Then:

1. With a Keychain API key and **Conversational voice** enabled, press **⌃⌥V** to open a bounded S2S session. Speak naturally; pause for turns, or speak over VoiceOps to interrupt playback.
2. Without that configuration, the same hotkey uses the retained per-utterance transcription path. The provider badge always labels `LIVE`, `FALLBACK`, or `REPLAY` honestly.
3. **Stop** or **Escape from any app** cancels capture and any running task. The global panic stop becomes available with Accessibility permission; the focused companion shortcut remains a fallback.

### Run the Order Rescue hero

Open the merchant workspace, press **⌃⌥V**, and say naturally:

```sh
scripts/seed_order_rescue_demo.sh
```

> “Take care of this delayed order. Check whether it has moved recently. She looks like a valuable customer, so if it has been stuck for more than three days, prepare an expedited replacement, apologize to her, update the order, and remind me tomorrow to verify the new tracking.”

When VoiceOps summarizes v1, interrupt its speech and say:

> “Actually, don’t create the replacement yet. Ask whether she would prefer the replacement or a full refund. Give her a twenty-dollar store credit either way, and tag Sarah in Slack because this is the third delayed package from this carrier.”

The same task should advance to v2 and show the minimal diff. VoiceOps reads back the bound customer message, $20 credit, and Slack escalation; answer with an unambiguous “yes” or use **Approve exact actions**. Live mode writes Shopify and Slack, then hands the follow-up to EventKit. Fixture mode performs the same semantic verification with a visible fixture label. Both paths finish only with **ORDER RESCUE COMPLETED — 5/5 CHECKS PASSED** plus explicit proof that no refund and no replacement were created.

### Run the Screen-to-Reminder slice

```sh
scripts/reset_demo_state.sh
scripts/seed_demo_state.sh
```

With the seeded Mail compose window active, press **⌃⌥V** and say: “Using this email, remind me two days before the deadline and include the important details.” Press **⌃⌥V** again. VoiceOps should reveal the created reminder due July 29, 2026 and show five passing checks. Run `scripts/reset_demo_state.sh` afterward to remove only the exact demo artifacts.

For the Meeting Briefing hero, keep the seeded Calendar event active and say: “Prepare me for my next meeting using what’s already open.” VoiceOps should reveal a `VoiceOps Brief — …` note with all five required sections and five passing checks. The seed script schedules the demo meeting 15 minutes ahead, so reseed immediately before a demo.

For Research-to-Follow-Up, keep the seeded Safari page active and say: “Research the companies on this page, put the best three in Notes, and schedule follow-ups next week.” Review the proposed Monday/Wednesday/Friday dates and select **Approve Schedule**. VoiceOps should reveal a `VoiceOps Research — Top 3 Companies` note and show five passing checks for the marked note, exactly three cited recommendations, exactly three matching reminders, and the visible note. Select **Cancel** at the approval gate to verify that no Notes or Reminders writes occur. Live source failures are labeled in the recommendation rationale; they are never presented as successful research.

### Live conversation, vision, and commerce sandbox

VoiceOps works without network or commerce credentials using Apple Speech and deterministic adapters. To enable Realtime conversation plus live model grounding/compilation:

1. Create an API key at [platform.openai.com/api-keys](https://platform.openai.com/api-keys).
2. Open the VoiceOps menu-bar item and choose **Voice & Intelligence Settings…**.
3. Paste the key, keep `gpt-5.6-sol`, enable **Conversational voice**, and select **Save**.

For the live commerce path, add all five values in **Commerce Sandbox**: Shopify shop domain, Admin token, test order ID, Slack bot token, and Slack channel ID. The sidecar selects live only after `shop.json` and `auth.test` succeed. Run the read-only readiness check before a demo:

```sh
cd agent && uv run python -m tests.live_shopify_probe
```

Anything missing or unhealthy selects fixtures and records the reason. Never describe fixture output as a merchant-store write. The customer-choice message remains a local sandbox by design; the reminder is native EventKit in live mode.

The settings window also shows Microphone, Apple Speech fallback, Screen Recording, and Accessibility readiness. Secrets are stored in the login Keychain, never UserDefaults, source, screenshots, or logs. Conversational mode streams microphone PCM only while its explicit session is open; voice processing cancels speaker echo and barge-in flushes playback. The retained transcription path may send up to 10 MiB of in-memory PCM once for bounded final refinement. Live grounding sends only the task-scoped active-window image and pruned Accessibility candidates. Production distribution should replace the long-lived API key with ephemeral Realtime credentials.

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
