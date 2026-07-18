# VoiceOps

Speak the outcome. VoiceOps sees the current screen, completes the work on the real Mac, and proves the requested result occurred.

VoiceOps is a voice-first macOS action agent: press a hotkey, speak a goal, and VoiceOps interprets the live screen, plans a safe sequence of actions, operates native Mac applications, and independently verifies the resulting state.

**Core loop:** Speak → Ground → Plan → Preview risk → Act → Observe → Verify → Report evidence

## Status

Phase 7 — Evaluation and demo hardening is implemented. `scripts/run_evals.sh` now runs the complete unit/contract suites, the Swift↔Python exchange, and a 20-case cross-runtime correctness evaluation, then regenerates [latest.md](evals/reports/latest.md) and [latest.json](evals/reports/latest.json). The baseline passes 20/20 with zero false successes, zero duplicate side effects, 2/2 recovery probes, and 7/7 provenance cases. These are deterministic offline correctness results; live microphone/TCC/native-app latency trials remain explicitly unmeasured and are not presented as automated evidence.

Phase 6 — Recovery and hardening is implemented. During every active state, a CGEvent-level global Escape panic stop cancels the sidecar and queued work even when the companion is not focused (with the panel shortcut as a fallback). A deterministic recovery policy classifies permissions, stale targets, closed apps, no-op/timeouts, ambiguous state, and uncertain writes; reversible reminder/briefing actions receive at most one retry, while consequential, destructive, or uncertain actions never retry. Task-marker lookups make those retries idempotent, and the expandable task timeline exposes action channels, durations, recoveries, verification, and final outcome.

Phase 5 — Research-to-Follow-Up is implemented. VoiceOps extracts at most eight visible public-web company links, rejects local/private targets, researches with at most four concurrent bounded reads, ranks exactly three recommendations, and previews three next-week dates. Nothing is written until the user selects **Approve Schedule**. It then creates one escaped, cited Notes comparison and exactly three EventKit reminders, refetches both stores, and requires all five predicates before reporting success. A denied approval produces no writes; an uncertain partial write is never retried automatically.

Phase 4 — Meeting Briefing is implemented as the hero workflow. VoiceOps selects the next upcoming non-all-day event through EventKit, creates a structured Apple Note with Meeting, Participants, Context, Open Questions, and Sources sections, escapes all untrusted screen content before it enters Notes HTML, reveals the exact note, then refetches both the event and note for five independent checks. A moved event, stale note, missing section, or failed UI reveal cannot produce success.

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

cd agent && uv run pytest     # Python tests
cd macos && swift test        # Swift tests
cd macos && swift run voiceops-mock-client   # end-to-end mock exchange
scripts/run_evals.sh          # all checks + 20-case JSON/Markdown report
```

### Run the app

```sh
scripts/run_app.sh            # builds with the CLI toolchain and launches — no Xcode IDE needed
```

(Opening `macos/VoiceOps.xcodeproj` in Xcode works too, but is optional.) On first use, grant the Microphone, Speech Recognition, Screen Recording, Accessibility, Calendars, Reminders, and Automation prompts. Then:

1. Press **⌃⌥V** anywhere and speak a goal — the floating companion shows the live transcript.
2. Press **⌃⌥V** again (or pause) to finish. VoiceOps captures the active window, shows any grounded reference chips, and then walks through planning → acting → result with spoken progress.
3. **Stop** or **Escape from any app** cancels capture and any running task. The global panic stop becomes available with Accessibility permission; the focused companion shortcut remains a fallback.

### Run the Screen-to-Reminder slice

```sh
scripts/reset_demo_state.sh
scripts/seed_demo_state.sh
```

With the seeded Mail compose window active, press **⌃⌥V** and say: “Using this email, remind me two days before the deadline and include the important details.” Press **⌃⌥V** again. VoiceOps should reveal the created reminder due July 29, 2026 and show five passing checks. Run `scripts/reset_demo_state.sh` afterward to remove only the exact demo artifacts.

For the Meeting Briefing hero, keep the seeded Calendar event active and say: “Prepare me for my next meeting using what’s already open.” VoiceOps should reveal a `VoiceOps Brief — …` note with all five required sections and five passing checks. The seed script schedules the demo meeting 15 minutes ahead, so reseed immediately before a demo.

For Research-to-Follow-Up, keep the seeded Safari page active and say: “Research the companies on this page, put the best three in Notes, and schedule follow-ups next week.” Review the proposed Monday/Wednesday/Friday dates and select **Approve Schedule**. VoiceOps should reveal a `VoiceOps Research — Top 3 Companies` note and show five passing checks for the marked note, exactly three cited recommendations, exactly three matching reminders, and the visible note. Select **Cancel** at the approval gate to verify that no Notes or Reminders writes occur. Live source failures are labeled in the recommendation rationale; they are never presented as successful research.

### Optional live vision grounding

VoiceOps works without a network credential using its deterministic grounder. To enable the OpenAI Responses API vision adapter:

1. Create an API key at [platform.openai.com/api-keys](https://platform.openai.com/api-keys).
2. Open the VoiceOps menu-bar item and choose **Vision Settings…**.
3. Paste the key, keep the default `gpt-5.6-terra` model (or enter another image-capable model), and select **Save**.

The secret is stored in the macOS login Keychain, never in UserDefaults or the repository. It is passed only in the environment of the per-task local sidecar. Live grounding sends the task-scoped active-window image and pruned Accessibility candidates to OpenAI; the capture is deleted when the task reaches a terminal state. Provider failures are visible in the companion and fall back to deterministic grounding.

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
