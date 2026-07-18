# Order Rescue deterministic evaluation

- Cases: 27
- Passed: 27
- False successes: 0
- Constraint retention: 100%
- Patch accuracy: 100%
- Unapproved consequential actions: 0
- Post-stop side effects: 0

| Case | Result | Evidence |
|---|---:|---|
| golden | PASS | ORDER RESCUE COMPLETED — 5/5 CHECKS PASSED |
| constraint_retention | PASS | retained=4 |
| stale_patch | PASS | stale base version rejected |
| approval_denied | PASS | approval preflight blocked every write |
| stop_barrier | PASS | post_stop_side_effects=0 |
| replacement_negative_verifier | PASS | prohibited replacement detected |
| refund_negative_verifier | PASS | prohibited refund detected |
| missing_slack_verifier | PASS | missing Slack state prevented success |
| idempotent_replay | PASS | replay produced no duplicate effects |
| ledger_contract | PASS | event_types=acted,decided,interpreted,observed,verified |
| spoken_approval_mishear | PASS | ambiguous speech authorized zero writes |
| stale_approval_hash | PASS | plan patch invalidated the old read-back hash before any write |
| barge_in_correction | PASS | v2→v3 patch preserved constraints and invalidated approval |
| unknown_tool_rejected | PASS | schema-invalid tool failed before router state was created |
| live_adapter_unhealthy_fallback | PASS | channel=fixture; fixture (live probe failed: Shopify returned HTTP 503 for GET /shop.json: b'{"ok":false,"error":"down"}') |
| execute_replay_rejected | PASS | second execute was rejected with unchanged side-effect ledger |
| panic_stop_during_conversation | PASS | Conversation stop cancels and tears down socket/audio before the sidecar. |
| golden | PASS | ORDER RESCUE COMPLETED — 5/5 CHECKS PASSED |
| constraint_retention | PASS | retained=4 |
| stale_patch | PASS | stale base version rejected |
| approval_denied | PASS | approval preflight blocked every write |
| stop_barrier | PASS | post_stop_side_effects=0 |
| replacement_negative_verifier | PASS | prohibited replacement detected |
| refund_negative_verifier | PASS | prohibited refund detected |
| missing_slack_verifier | PASS | missing Slack state prevented success |
| idempotent_replay | PASS | replay produced no duplicate effects |
| ledger_contract | PASS | event_types=acted,decided,interpreted,observed,verified |
