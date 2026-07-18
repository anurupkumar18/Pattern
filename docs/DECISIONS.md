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

## ADR-009: System speech recognition behind the Transcriber protocol

**Date:** 2026-07-17 · **Phase:** 1

**Decision:** Phase 1 STT is SFSpeechRecognizer + AVAudioEngine, wrapped in the
`Transcriber` protocol (`VoiceOpsCore`). Session logic lives in
`VoiceSessionController` and is tested against a scripted fake; the system
adapter stays thin and untested-by-unit-tests.

**Reason:** Zero API keys, zero setup, streaming partials out of the box —
and the ARD requires provider adapters, so a Whisper-class endpoint can be
swapped in later without touching session logic. Matches the demo runbook's
"speech service failure → local/system STT" contingency from day one.

## ADR-010: Toggle hotkey ⌃⌥V via Carbon, panel-scoped Escape

**Date:** 2026-07-17 · **Phase:** 1

**Decision:** The global hotkey is ⌃⌥V (press to start listening, press again
to finish), registered with Carbon `RegisterEventHotKey`. Escape cancels when
the companion panel has keyboard focus; the global Escape panic stop at a lower
level than the model loop is implemented by ADR-017 in Phase 6
hardening because it needs an event tap and Accessibility permission.

**Reason:** Carbon hotkeys need no Accessibility permission, so first-run
setup stays at exactly two prompts (microphone, speech recognition). Toggle
beats hold-to-talk for demo reliability: no lost finals when the key is
released mid-word.

## ADR-011: Native observation, sidecar grounding

**Date:** 2026-07-18 · **Phase:** 2

**Decision:** The macOS shell owns ScreenCaptureKit and Accessibility access,
normalizes the active window into the shared `Observation` contract, and stores
the screenshot in a task-scoped temporary directory. It sends
`observation.ready` immediately before `voice.final`. The Python sidecar owns
the `MultimodalGroundingAdapter` boundary and returns `grounding.ready` before
planning. Terminal app states delete the capture directory.

**Reason:** Permissioned native frameworks remain in Swift while provider/model
logic stays in the Python runtime designated by ARD §2. Sending the normalized
observation over the existing NDJSON protocol preserves provenance and avoids a
third runtime or a second transport.

## ADR-012: Deterministic grounding as the offline-safe fallback

**Date:** 2026-07-18 · **Phase:** 2

**Decision:** Phase 2 includes an offline-safe, deliberately narrow semantic
grounder for high-confidence MVP references. It receives the same screenshot
path and accessibility candidates as the live VLM adapter, resolves the golden
Mail/deadline cases with candidate-level provenance, and returns no reference
when evidence is insufficient. It is selected when no provider credential is
configured and is the automatic fallback when a live provider response is
unavailable or fails contract validation.

**Reason:** The architecture explicitly requires provider adapters and Keychain
credentials while deterministic fixtures keep CI stable. Keeping the fallback
as a first-class adapter preserves offline operation and makes provider failure
visible without turning a network outage into a failed task.

## ADR-013: OpenAI Responses API vision with Keychain-backed credentials

**Date:** 2026-07-18 · **Phase:** 2

**Decision:** The live grounding provider is an OpenAI Responses API adapter
using image input and strict JSON Schema output. The app stores the user-supplied
API key as a generic password in the macOS login Keychain and stores only the
non-secret model name in UserDefaults. At task start, the Swift shell reads the
credential and passes it only to the spawned sidecar process. The model can
select a supplied candidate ID and read visible text, but its output is rejected
if the phrase is absent from the spoken request or the candidate ID was not in
the native observation. Provenance is always rebuilt locally.

**Reason:** The adapter boundary keeps the provider replaceable, while strict
output validation prevents the model from inventing native identities or audit
evidence. A settings UI gives the user direct control over the credential and
model without putting secrets in source, the app bundle, defaults, or logs.

## ADR-014: Native reminder execution, independent fetch-back verification

**Date:** 2026-07-18 · **Phase:** 3

**Decision:** A grounded Screen-to-Reminder request produces one reversible
`reminders.create` step with five postconditions: existence, title, due date,
source notes, and visible presentation. The Swift app executes the write through
one long-lived `EKEventStore`, sends an `action.finished` envelope, resets the
store’s in-memory state, fetches the committed reminder by identifier, compares
the normalized fields in a pure verifier, reveals the exact reminder through
Reminders’ documented scripting dictionary, and sends one
`verification.finished` envelope per predicate. The Python sidecar waits for
the action plus all five verifier messages before it may emit `task.completed`.

**Reason:** EventKit is the most reliable semantic action channel on macOS, and
the separate fetch-back path enforces the executor-never-declares-success
invariant across the IPC boundary. A failed visual reveal yields `partial`, not
success, even when the reminder itself was committed correctly. Reminder and
Automation permission failures surface an exact System Settings destination.

## ADR-015: EventKit-to-Notes Meeting Briefing hero

**Date:** 2026-07-18 · **Phase:** 4

**Decision:** Meeting Briefing selects the next upcoming non-all-day event in a
seven-day EventKit window, then creates one structured Apple Note using Notes’
documented scripting interface. The note contains five required sections,
EventKit meeting identity, task provenance, and task-scoped active-screen
context. All observed and EventKit strings are HTML-escaped before entering the
note. The action uses the bounded, idempotent policy in ADR-017; the verifier
resets EventKit, refetches the event by identifier, refetches the note by
identifier, compares title, start time, headings, marker, and visibility, and
returns five predicate results.

**Reason:** EventKit and the Notes object model provide semantic, auditable
channels for the hero workflow. Separating note creation from its UI reveal
lets a reveal/Automation failure report `partial` without hiding a successfully
created note or retrying the write. The deterministic template keeps offline
operation and prompt-injection boundaries testable while preserving the model
adapter seam for later synthesis.

## ADR-016: Bounded research with an approval-gated multi-app write

**Date:** 2026-07-18 · **Phase:** 5

**Decision:** Research-to-Follow-Up extracts at most eight HTTP(S) links from
the task-scoped Accessibility observation and runs at most four concurrent
reads. Each live request revalidates DNS and every redirect, rejects local,
private, reserved, and otherwise non-global addresses, enforces a five-second
timeout, accepts only HTML, and buffers at most 256 KB. Per-source failures are
retained as visible unavailable evidence instead of being treated as fetched.
The planner deterministically ranks exactly three results and proposes the next
Monday, Wednesday, and Friday, but sets `requires_confirmation` before any
write. Only an explicit **Approve Schedule** transition allows the macOS shell
to create one escaped Notes comparison and exactly three EventKit reminders.

After execution, the verifier resets EventKit, refetches all reminder IDs,
refetches the note through Notes Automation, and evaluates five predicates for
marker, exact recommendation count, citations/rationales, exact follow-up count
and dates, and visible note state. Action failures roll back both the task-marked
note and reminders. If a rollback cannot be proven, the action becomes
`uncertain` and is not retried.

**Reason:** Public-web research is useful only when its scope and provenance are
bounded, while calendar/reminder scheduling must remain a human decision. The
approval state makes that boundary visible and testable. Semantic store
fetch-back prevents an executor response, UI click, network failure, or stale
artifact from becoming a false success.

## ADR-017: Lower-level panic stop, idempotent retry, and visible traces

**Date:** 2026-07-18 · **Phase:** 6

**Decision:** While VoiceOps is in any active task state, Escape is registered
through a session-level `CGEvent` tap below the sidecar/model loop and consumed
as a panic stop. If macOS has not yet granted event-tap access, a non-consuming
global monitor plus the panel shortcut provides fallback coverage; the CGEvent
tap is installed again after Accessibility permission becomes available. Stop
cancels voice capture, resolves any approval continuation as denied, terminates
the child sidecar, clears queued attempts, and removes the task-scoped capture.

A pure recovery policy maps the ARD failure taxonomy to deterministic actions.
Permissions always stop at an exact settings path. Reversible
`NO_STATE_CHANGE`, `TIMEOUT`, stale-target, and app-not-running failures may use
only the plan’s bounded budget. Meeting Briefing and Screen-to-Reminder allow a
maximum of two attempts; before either write, the native adapter searches for
the unique task marker and reuses the existing artifact. Research scheduling
remains one attempt. Consequential, destructive, completed, and uncertain
actions are rejected by the task-scoped attempt ledger and never repeated.

The macOS shell also records an in-memory, privacy-minimal timeline of stages,
native channels, action durations, recovery decisions, verification, and final
outcome. The companion exposes the last entries and automatically expands the
timeline when recovery occurs.

**Reason:** Recovery improves reliability only if it cannot create duplicate
side effects. A hard lower-level interrupt, deterministic budgets, semantic
task markers, and a user-visible trace keep recovery bounded, auditable, and
independent of model judgment. The in-memory trace provides immediate evidence
without retaining raw screen or speech content.

## ADR-018: Cross-runtime deterministic evaluation with honest live gaps

**Date:** 2026-07-18 · **Phase:** 7

**Decision:** The final automated gate contains 20 catalogued correctness cases.
Fifteen execute the Python grounding, planning, research safety, IPC, action,
and verification orchestration directly. Five execute compiled Swift core code
through `voiceops-eval-probe` for bounded recovery, uncertain-write refusal,
completed-action deduplication, panic-stop policy, and task traces. The runner
computes pass rate, false successes, duplicate side effects, recovery success,
and provenance coverage, fails the command when thresholds are missed, and
writes stable JSON and Markdown reports. CI runs the same evaluator after the
cross-runtime mock exchange.

Live microphone/TCC prompts, native application writes, event-tap delivery,
network reliability, and latency are explicitly `null`/unmeasured in the
automated report. They have a separate 20-trial permissioned matrix and cannot
be inferred from fixture success.

**Reason:** A deterministic suite catches regressions and makes the zero-false-
success invariant auditable, but fabricated live metrics would weaken the
evidence. Separating reproducible correctness from permissioned Mac trials gives
judges and engineers a useful report with an honest boundary.

## ADR-019: Persistent Order Rescue tasks and minimal voice patches

**Date:** 2026-07-18 · **Demo hardening**

**Decision:** The Order Rescue hero compiles the initial spoken request and trusted order fixture into an immutable `VersionedTaskSpec`. A correction arrives as `voice.correction` under the original task ID and produces a validated `PlanPatch` against the exact base version. Applying the patch increments the version once, records added/removed/replaced/preserved fields, rejects stale bases, and cannot remove completed work. The app renders raw request, objective, actions, constraints, patch, and the current version.

**Reason:** Mid-flight speech must revise the user's active intent rather than restart a task or regenerate a plan that forgets constraints. Versioned, typed patches make constraint retention and correction accuracy deterministic and visible.

## ADR-020: Fixture semantic adapters with verifier-owned Order Rescue success

**Date:** 2026-07-18 · **Demo hardening**

**Decision:** The demo uses typed, idempotent fixture adapters for carrier tracking, Shopify note/tag/credit state, customer messaging, Slack escalation, and reminders. Every confirmation-gated action is preflighted before the first write. The executor emits structured Observed, Interpreted, Decided, and Acted records but cannot declare completion. A separate verifier refetches five required states and proves two prohibited states—no refund and no replacement—before emitting `succeeded`. The full safety rehearsal runs 20 deterministic cases and exits nonzero on any false success, unapproved action, post-stop effect, stale patch acceptance, duplicate effect, or constraint loss.

**Reason:** A credential-free semantic demo is repeatable and honest, while the same adapter boundary can accept live Shopify, messaging, and Slack implementations later. Positive and negative verification prevents an executor response from being confused with real completion.

## ADR-021: Transcription-specific Realtime voice with transcript-preserving failover

**Date:** 2026-07-18 · **Voice reliability**

**Decision:** When a Keychain credential exists, the macOS shell opens a transcription-only Realtime WebSocket using `gpt-realtime-whisper`, streams 24 kHz mono PCM16, requests balanced delay, disables server turn detection, and commits only when the operator ends capture. Session readiness is required before the microphone starts. Apple Speech remains the zero-setup provider and automatically takes over on a primary start or midstream failure. A midstream handoff preserves the already-displayed transcript prefix, labels the fallback in the UI, and keeps the same `VoiceSessionController`. Narration never runs while capture is open. The live vision default moves to flagship `gpt-5.6-sol`.

**Reason:** The specialized streaming transcription model is a better fit than a speech-to-speech agent model for command capture. Manual commit preserves hotkey semantics; dual providers remove a single network dependency; retaining the partial transcript prevents a provider outage from silently changing the user's request. A distributed production client should use ephemeral Realtime credentials rather than a long-lived API key.
