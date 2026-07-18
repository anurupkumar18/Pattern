# VoiceOps Deterministic Evaluation Report

**Run:** `fixture-baseline-v1`

**Status:** **PASSED**

**Scope:** `deterministic_offline_cross_runtime_correctness`

## Summary

| Metric | Result |
|---|---:|
| Case pass rate | 20/20 (100.0%) |
| False successes | 0 |
| Duplicate side effects | 0 |
| Recovery success | 2/2 (100.0%) |
| Provenance coverage | 7/7 (100.0%) |
| Live task latency | Not measured by this offline suite |

## Cases

| Case | Workflow | Result | Evidence |
|---|---|---:|---|
| `reminder_clear_plan` | screen-to-reminder | PASS | Clear grounded deadline produced a five-predicate EventKit plan. |
| `reminder_ambiguous_year_fails_closed` | screen-to-reminder | PASS | A deadline without a year failed closed for clarification. |
| `grounding_deictic_provenance` | grounding | PASS | Deictic email and deadline references retained native provenance. |
| `reminder_waits_for_verifier` | screen-to-reminder | PASS | Executor completion emitted no task success before verification. |
| `reminder_all_predicates_complete` | screen-to-reminder | PASS | All five independent reminder predicates produced verified success. |
| `reminder_failed_predicate_is_partial` | screen-to-reminder | PASS | A failed visible-state predicate returned partial, never success. |
| `failed_action_never_succeeds` | safety | PASS | A native action failure became task.failed with no success claim. |
| `meeting_real_plan` | meeting-briefing | PASS | Meeting Briefing produced an idempotent five-predicate Notes plan. |
| `research_requires_approval` | research-follow-up | PASS | Exactly three cited recommendations remained behind approval. |
| `research_candidates_bounded_to_eight` | research-follow-up | PASS | Twelve visible links were bounded to eight reads and three results. |
| `research_unavailable_source_labeled` | research-follow-up | PASS | Unavailable sources remained visibly labeled in every recommendation. |
| `research_private_target_blocked` | safety | PASS | Loopback, private, and non-HTTP research targets were blocked. |
| `invalid_ipc_fails_closed` | protocol | PASS | Malformed IPC produced typed INVALID_MESSAGE failure. |
| `grounding_provider_failure_typed` | grounding | PASS | Grounding provider failure became typed fail-closed output. |
| `orphan_verification_rejected` | protocol | PASS | Verification without a pending plan was rejected. |
| `native_bounded_recovery` | recovery | PASS | A reversible no-op receives one ledger-bounded retry. |
| `native_uncertain_never_retries` | safety | PASS | Uncertain state routes to verification and the ledger rejects another write. |
| `native_completed_duplicate_suppressed` | safety | PASS | A completed task-scoped write cannot be claimed again. |
| `native_panic_stop_policy` | safety | PASS | Only Escape while armed triggers the lower-level panic policy. |
| `native_trace_evidence` | evidence | PASS | The task trace retains stage order, elapsed time, and recovery count. |

## Gates

- PASS — `case_pass_rate_at_least_85_percent`
- PASS — `false_successes_zero`
- PASS — `duplicates_zero`
- PASS — `recovery_success_at_least_70_percent`
- PASS — `provenance_coverage_100_percent`

## Limitations

- No live microphone, TCC permission, EventKit, Notes, Reminders, or network trial is performed.
- Latency targets require repeated permissioned runs on a dedicated macOS account.
- The native probe exercises recovery policy and duplicate guards, not CGEvent delivery by macOS.

This report is correctness evidence, not a claim of completed live acceptance testing.
