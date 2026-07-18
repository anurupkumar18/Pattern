# Conversational Order Rescue — Design

**Date:** 2026-07-18 · **Status:** Approved by product owner · **Runway:** ~2 weeks to judged demo

## 1. Goal

Evolve the Order Rescue hero from a hotkey-transcription demo with fixture execution into a
conversational agent that a judge experiences as: press ⌃⌥V, hold a natural two-way spoken
conversation with a crisp-sounding operator agent that reads the live screen, compiles speech into a
versioned task, accepts a mid-flight correction as a visible v1→v2 patch, asks for spoken
confirmation by reading back exactly what it will do, executes against a **real Shopify dev store**
and a **real Slack workspace**, and proves completion — including what it deliberately did not do —
by refetching live state.

The headline differentiator to perfect and open with: **the mid-flight voice patch (v1→v2)** —
interrupting a running task by voice revises the plan with a visible diff and preserved constraints,
without restarting anything.

## 2. Decisions this design implements

Recorded from the 2026-07-18 product-owner session; ADR entries land in `docs/DECISIONS.md`
as ADR-022..024 during implementation.

1. **Demo realism:** live Shopify sandbox (Partners dev store, test orders) + live Slack, with the
   existing fixture adapters retained as an armed, visibly labeled fallback. Customer email stays
   fixture/sandbox. The follow-up reminder becomes a real EventKit write.
2. **Voice UX:** full speech-to-speech (S2S) Realtime conversation — the agent listens and speaks
   natively, with barge-in.
3. **Live model use on stage:** live LLM task/patch compilation and live VLM screen grounding as the
   primary path; deterministic implementations demoted to fallback.
4. **S2S wiring:** the S2S agent drives the existing task machine **only** through typed tool calls;
   the sidecar remains the sole authority over plans, patches, approvals, execution, and verification.
5. **Turn-taking:** ⌃⌥V opens a bounded conversational session (server VAD, barge-in); hotkey or a
   spoken close ends it. The microphone is never hot outside an explicit session.
6. **Approval UX:** spoken approval with a read-back binding, on-screen button retained as fallback.
7. **Persona:** crisp operator — terse, competent, zero filler.
8. **Judge model:** presenter-only but deliberately improvised phrasing; robustness to off-script
   speech matters, judge-accent robustness does not.
9. **Triage priority if the final days force cuts:** conversational voice + live compile survive at
   full quality; live adapters and live grounding fall back to today's paths with honest disclosure.

## 3. Architecture

```
⌃⌥V ──> RealtimeConversationSession (Swift, S2S audio, VAD, barge-in, persona)
              │  function-call events only
              ▼
        ConversationToolBridge (Swift)
              │  conversation.tool_call / conversation.tool_result envelopes (NDJSON)
              ▼
        Python sidecar — unchanged authority:
          compile_task · apply_patch · get_task_state · request_approval · execute_plan · get_ledger
              │
              ├─ LLM compiler (strict structured output) ─ fallback → deterministic compiler
              ├─ VersionedTaskSpec / PlanPatch validation (ADR-019, unchanged)
              ├─ Approval gate + read-back binding (action-set hash)
              ├─ Adapters: ShopifyAdmin(live) · Slack(live) · customer-msg(fixture) · reminders(EventKit)
              │             └─ fixture fallback, selection by credential presence, visibly labeled
              └─ Verifier: live fetch-back + negative checks (owns success, ADR-020, unchanged)
```

**The conversation layer has no direct power.** Its only side-effect path is the typed tool calls
above. The model's speech is presentation; the validated task state is law. Everything the UI renders
today — raw request, compiled objective, constraints, v1→v2 diff, execution ledger, 5/5 + 2 negative
checks — renders identically; the S2S agent just makes producing it feel like conversation.

### 3.1 Components

**Swift (`VoiceOpsCore` + app):**

- `RealtimeConversationSession` — S2S Realtime client (WebSocket): opens on hotkey, streams mic
  audio with AVAudioEngine voice-processing (echo cancellation) so barge-in works while the agent is
  speaking; server VAD turn detection **enabled** for this session type (deliberate reversal of the
  transcription session's manual commit — recorded in ADR-022); session instructions carry the
  crisp-operator persona and the tool definitions; emits typed events (agent speaking, user turn,
  function call, session error).
- `ConversationToolBridge` — converts Realtime function-call events into
  `conversation.tool_call` envelopes, awaits `conversation.tool_result`, and returns the result to
  the model. Rejects any tool name/schema not in the registry.
- Session lifecycle — `SessionStateMachine` gains conversational states; Escape panic stop
  (ADR-017) additionally tears down the S2S WebSocket and audio engine; the ADR-021
  transcription-only pipeline is **retained intact** as the armed on-stage fallback (walkie-talkie
  contingency, already rehearsed and CI-proven).
- Spoken-approval UI — companion shows the read-back text and the pending action-set hash state;
  the Approve button remains as the click fallback.

**Python sidecar:**

- Tool endpoints — `compile_task`, `apply_patch`, `get_task_state`, `request_approval`,
  `execute_plan`, `get_ledger` as NDJSON handlers over the existing protocol. Deterministic
  implementations first (wrapping the existing Order Rescue task machine), live LLM behind them.
- LLM compiler — live model call with strict structured output validated against the existing
  `VersionedTaskSpec` / `PlanPatch` schemas. Validation failure or provider outage falls back to the
  deterministic compiler; the outcome (LIVE / FALLBACK) is labeled in the ledger. Patch-validation
  rules (stale-base rejection, constraint retention, cannot remove completed work) stay
  deterministic checks regardless of which compiler produced the patch.
- Approval binding — `request_approval` computes a canonical hash over the pending consequential
  action set and returns the exact read-back text. A spoken affirmative approves **only that hash**
  within a bounded window; any plan change or hash mismatch invalidates the window and forces a
  re-read. A mishear can never authorize.
- Live adapters — `ShopifyAdminAdapter` (dev store: order note, tag, store credit on test orders)
  and `SlackAdapter` (bot post to `#shipping-escalations`) implement the same interface as the
  ADR-020 fixture adapters. Selection: live when credentials are present and healthy, fixture
  otherwise, always visibly labeled. Credentials follow the existing Keychain → spawned-sidecar
  plumbing; nothing in source, defaults, or logs.
- Live verifier — refetches order note/tag/credit and the Slack message through the real APIs
  (fetch-back, never executor echo), plus the negative checks (no refund, no replacement) against
  live store state. The reminder check reuses the Phase 3 EventKit fetch-back.

### 3.2 Data flow (hero path)

1. ⌃⌥V opens the S2S session; the agent greets tersely and listens.
2. Operator speaks the delayed-order request. The agent calls `compile_task`; sidecar grounds
   against the current observation (live VLM primary), compiles v1 (live LLM primary), returns the
   spec; the agent voices a compact summary while the UI renders the full v1 card.
3. Operator barge-ins with the correction. The agent calls `apply_patch` with the transcribed
   correction; sidecar validates the patch against base v1, increments to v2, returns the diff; the
   agent voices what changed; UI shows v1→v2.
4. The agent calls `request_approval`; sidecar returns read-back text + hash; the agent reads it
   back verbatim; operator says yes; the agent calls `request_approval` confirm with the hash.
5. `execute_plan` runs the gated actions through the live adapters, streaming ledger events.
6. The verifier refetches everything live; only it can emit success; the agent voices the final
   5/5 + 2-negative report.

## 4. Error handling and fallback matrix

| Failure | Behavior |
|---|---|
| S2S session fails to open / dies midstream | Fall back to ADR-021 transcription pipeline (per-utterance hotkey), visibly labeled; task state survives. |
| LLM compile invalid/timeout | Deterministic compiler result, labeled FALLBACK in ledger. |
| VLM grounding invalid/timeout | Deterministic grounder (ADR-012), labeled. |
| Live adapter credential missing/unhealthy | Fixture adapter, visibly labeled; disclosure line in demo. |
| Live write fails mid-plan | Existing recovery policy (ADR-017): bounded retry only for reversible actions; consequential never auto-retried; uncertain fails closed. |
| Approval hash mismatch / plan changed after read-back | Approval window invalidated; re-read required. |
| Ambiguous / non-affirmative reply to read-back | Not approval; agent asks once, then falls back to on-screen button. |
| Escape at any point | Panic stop: S2S teardown, sidecar termination, queued work cleared, no post-stop effects (rehearsal-asserted). |

## 5. Testing

TDD throughout (repo convention). New coverage:

- Contract: new envelope fixtures round-tripped by both suites (tool call/result, approval binding).
- Unit: tool endpoint validation, approval hash canonicalization + stale-hash rejection, adapter
  selection logic, LLM-output schema rejection → fallback, bridge tool-registry rejection.
- Protocol-level Swift tests for `RealtimeConversationSession` mirroring the existing
  `RealtimeTranscriptionProtocol` test style (no live network in CI).
- Rehearsal additions: spoken-approval mishear cannot authorize; barge-in correction mid-execution;
  live-adapter failure produces labeled fixture fallback, not silent success; S2S tool-call schema
  violation rejected; stale approval hash rejected; panic stop tears down the S2S session with zero
  post-stop effects. The 20-case deterministic rehearsal stays green and grows.
- Live acceptance (manual, permissioned): mic + speaker echo/barge-in drill, live Shopify/Slack
  writes + fetch-back on the dev store, latency feel. Never claimed by the automated report (ADR-018
  honesty boundary).

## 6. Sequencing

- **Week 1:** schemas → sidecar tool endpoints (deterministic) → S2S session + bridge + persona +
  turn model (the triage-protected layer) → LLM compiler behind schemas. In parallel, product owner
  creates the Shopify Partners dev store and Slack workspace (account creation is theirs); adapters
  are built against mocked HTTP meanwhile.
- **Week 2, first half:** live adapters wired to real credentials; live verifier fetch-back; real
  EventKit reminder; live grounding primary; spoken-approval protocol end-to-end; eval/rehearsal
  extensions.
- **Final 3–4 days:** feature freeze; rehearsal + failure drills (kill network, revoke credential,
  force mishear); DEMO.md v2; ADR-022..024; README refresh.

## 7. Out of scope

Live customer-email sending; judges speaking to the agent directly; wake-word / open mic outside a
session; production credential exchange (ephemeral Realtime tokens remain a stated
production-hardening note); app packaging/distribution; workflows other than Order Rescue gaining
conversation support.

## 8. Risks

1. **Stage acoustics** — echo/barge-in with open speakers is the top demo risk; mitigated by
   AVAudioEngine voice processing, early live drills, and the retained transcription fallback.
2. **Realtime S2S flakiness** — mitigated by the fallback pipeline and the deterministic compile path.
3. **Sandbox setup latency** — live adapters block on product-owner-created credentials; mocked-HTTP
   development keeps the critical path moving.
4. **Scope pressure** — triage order is pre-agreed: conversational voice + live compile survive;
   adapters/grounding fall back with disclosure.
