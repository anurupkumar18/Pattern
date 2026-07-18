# VoiceOps Conversational Order Rescue — Current Handoff

**Date:** 2026-07-18  
**Branch:** `main`  
**Implementation plan:** [2026-07-18-conversational-order-rescue.md](superpowers/plans/2026-07-18-conversational-order-rescue.md)  
**Approved design:** [2026-07-18-conversational-order-rescue-design.md](superpowers/specs/2026-07-18-conversational-order-rescue-design.md)

## Current state

The 17-task conversational plan is implemented through the automated freeze
gate. The hero opens a bounded OpenAI Realtime S2S session, supports semantic
turn taking and barge-in, drives the Python authority only through seven typed
tools, renders persistent task versions and patches, binds spoken/click approval
to the exact action-set hash, and preserves the active task when voice falls
back to Apple Speech.

Shopify and Slack adapters are live only when all five Keychain values exist
and both health probes succeed. Selection and fallback reasons are recorded in
the ledger. Customer email remains sandboxed. In live mode the follow-up is a
native EventKit plan; completion waits for its action result and five native
verification results. Fixture mode remains offline-safe.

## Release gate

Run one command from the repository root:

```sh
scripts/rehearse_order_rescue.sh
```

It runs Python and Swift tests, cross-runtime IPC, the 27-case correctness
catalog, the 27-run Order Rescue safety rehearsal, report/dashboard generation,
and the signed native replay receipt/screenshot. The expected invariants are
zero false successes, duplicate effects, unapproved actions, and post-stop
effects.

For a read-only live commerce readiness check:

```sh
cd agent && uv run python -m tests.live_shopify_probe
```

## Key decisions

- [ADR-022](DECISIONS.md): S2S conversation is session-scoped and has only typed tool authority.
- [ADR-023](DECISIONS.md): live commerce is credential- and health-gated with labeled fixture fallback.
- [ADR-024](DECISIONS.md): spoken and click approval share one hash-bound confirmation path.
- ADR-017/018 remain the stop/recovery and evidence-honesty boundaries.

## Remaining external acceptance

No code or deterministic gate is known incomplete. The following cannot be
claimed from CI and remain deliberately marked **NOT RUN** in [DEMO.md](DEMO.md):

- three consecutive full live conversational runs with the product owner;
- speaker/microphone echo and barge-in on the actual stage setup;
- network kill mid-session and visible task-preserving fallback;
- Shopify/Slack credential revoke and labeled fixture selection;
- live forced mishear and CGEvent Escape delivery during execution.

Record those outcomes in the DEMO freeze-week table. Fix only observed defects,
with a regression test first.
