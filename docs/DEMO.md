# VoiceOps Conversational Order Rescue — Judge Runbook v2

## Demo goal

In under four minutes, show a natural spoken correction changing a persistent
task from v1 to v2, bind approval to the exact revised actions, execute through
honestly labeled channels, and prove five required outcomes plus two prohibited
outcomes by fresh reads.

## Pre-demo checklist

- Use a dedicated macOS profile and seed the local Order #1842 workspace with
  `scripts/seed_order_rescue_demo.sh`.
- In **Voice & Intelligence Settings…**, require Microphone, Screen Recording,
  and Accessibility to say **Ready**. Apple Speech must also be ready as the
  contingency provider.
- Save the OpenAI key, enable **Conversational voice**, and confirm the companion
  opens as `OpenAI Realtime Conversation · LIVE`.
- For live commerce, save all five Shopify/Slack sandbox values. Run the
  read-only probe and require `channel: shopify.live+slack.live`:

  ```sh
  cd agent && uv run python -m tests.live_shopify_probe
  ```

- Verify the Slack bot is a member of `#shipping-escalations`. Use only test
  order #1842 and remove prior demo note/tag/credit/message artifacts through
  the sandbox UIs before a clean run.
- Run `scripts/rehearse_order_rescue.sh`; require 27/27 in both deterministic
  reports, zero false successes, zero duplicates, zero unapproved actions, zero
  post-stop effects, and `NATIVE ORDER RESCUE REPLAY VERIFIED`.
- Open `evals/dashboard.html` on a secondary Space. Keep the tested replay and
  Apple Speech paths ready; never change credentials during the hero.

## Opening (20 seconds)

“VoiceOps lets an operator speak the outcome, correct the plan in flight, and
prove the resulting state. The voice model can converse, but it has no direct
power: every plan, approval, action, and verification crosses typed tools into
the task machine.”

Show: **Speak → Ground → Version → Approve exact actions → Act → Refetch → Prove**.

## Conversational hero (2 minutes 20 seconds)

Keep Order #1842 visible. Press **⌃⌥V** once; this opens the bounded S2S session.
Say naturally, without reading word-for-word:

> “Take care of this delayed order. Check whether it has moved recently. She’s a
> valuable customer, so if it has been stuck for more than three days, prepare
> an expedited replacement, apologize, update the order, and remind me tomorrow
> to verify the new tracking.”

Point out the live user transcript, terse agent response, task ID, v1 objective,
actions, constraints, and compiler label. No action is complete yet.

While VoiceOps is speaking, interrupt it:

> “Actually, don’t create the replacement yet. Ask whether she wants a
> replacement or a refund, add a twenty-dollar credit, and notify Sarah in Slack
> because this is the third delay from this carrier.”

The playback must stop immediately. Point out that the task ID did not change,
the UI shows **v1 → v2**, replacement creation is removed, three consequential
actions are added, and the original constraints remain.

VoiceOps calls `request_approval` and reads the returned text verbatim. Point to
the bound approval card and hash prefix. Answer clearly:

> “Yes, go ahead.”

An ambiguous phrase such as “yeah, maybe” must not authorize. The click button
is only a fallback and sends the same hash-bound `confirm_approval` tool call.

## Live verification beat (35 seconds)

Expand the channel-selection ledger event before describing external effects.

- If it says `shopify.live+slack.live`, show the Shopify test order note/tag and
  $20 test credit, then the marked Slack escalation. State that customer email
  is still a local sandbox channel.
- If it says `fixture`, read the displayed reason aloud and say that no merchant
  account was touched. Continue; this is the designed deterministic fallback.
- In live mode, show the EventKit reminder and its five native fetch-back and UI
  checks. The sidecar cannot complete while any of those results is missing.

Finish on **ORDER RESCUE COMPLETED — 5/5 CHECKS PASSED**. Call out the two
negative checks: **no refund issued** and **no replacement created**. A failed
native reminder check must say `partial` / `NOT VERIFIED`, never success.

## Safety and recovery moment (25 seconds)

Expand the approval ledger entry:

“This SHA-256 binding names the task version and exact pending consequential
actions. A patch invalidates it. The 27-case rehearsal forces a spoken mishear,
a stale hash, an unknown tool, an execute replay, an unhealthy live adapter,
and Escape during conversation; all fail closed.”

If demonstrating stop, press Escape while the session is active. The expected
order is Realtime socket cancellation, audio stop, playback flush, then sidecar
termination. Reseed and rehearse before another hero run.

## Contingency matrix

| Failure | Presenter action | Honest label / preserved evidence |
|---|---|---|
| S2S socket fails or network dies | Continue with hotkey-per-utterance Apple Speech | `FALLBACK`; active task/version is preserved |
| Shopify or Slack credential/probe fails | Continue through deterministic adapters | Ledger says `fixture` plus the exact reason; do not claim external writes |
| Live LLM or VLM fails | Continue with deterministic compiler/grounder | Compiler/grounding outcome says `FALLBACK` |
| Conversation and live credentials both unavailable | Choose **Replay Tested Order Rescue** | `REPLAY`; proves native UI/sidecar contract, not microphone or merchant accounts |
| Native reminder fetch-back or reveal fails | Stop on the partial result | Never narrate the task as complete |

## Evaluation proof (30 seconds)

Open the dashboard and show 27/27 cross-runtime cases plus 27/27 Order Rescue
runs, zero false successes, zero duplicate effects, zero unapproved actions,
zero post-stop effects, and the explicit unmeasured live-latency field.

Key line: “The automated evidence is offline correctness. The live drill record
below is separate because permissions, accounts, acoustics, and networks cannot
be fabricated by CI.”

## Freeze-week drill record

| Drill | Current outcome |
|---|---|
| Deterministic 27-case suites | Automated on this checkout; refresh before demo |
| Signed native replay and screenshot | Automated on this checkout; refresh before demo |
| Full conversational hero ×3 | **NOT RUN** — requires product-owner sandbox credentials and a permissioned live session |
| Network kill mid-session | **NOT RUN** — requires a permissioned live session |
| Shopify/Slack credential revoke | **NOT RUN** — requires product-owner sandbox credentials |
| Forced approval mishear | Covered deterministically; live acoustic drill **NOT RUN** |
| Escape during live execution | Core ordering covered deterministically; permissioned CGEvent delivery drill **NOT RUN** |

Record dates, channel labels, failures, and fixes here after each product-owner
drill. Do not convert an unrun manual item into a pass based on automated tests.

## Known limitations to state proactively

- Live customer email is out of scope; the customer-message channel is sandboxed.
- Production distribution still needs ephemeral Realtime credentials rather
  than a long-lived API key.
- The hero is optimized for the delayed high-value order exception, not every
  ecommerce workflow.
- Live microphone/TCC, stage acoustics, external-account health, and latency are
  manual acceptance items, not claims made by the deterministic report.
