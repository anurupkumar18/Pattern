# Voice Command Center Eval

Generated: 2026-07-18T14:50:23.285Z

Fixtures: 28

## Summary

- Deterministic router: 28/28 (100.0%)
- Gemma router (local-exec:python3): 23/28 (82.1%)
- Cascade router: 28/28 (100.0%)
- Cascade escalations: 6/28 (0 fallback failures)
- Deterministic noise false-fire rate: 0.0%
- Gemma noise false-fire rate: 0.0%
- Cascade noise false-fire rate: 0.0%
- Deterministic end-to-end verified: 100.0%
- Gemma end-to-end verified: 100.0%
- Cascade end-to-end verified: 100.0%

> Gemma results came from the configured local runtime.

## Accuracy by category

| Router | Clear | Fuzzy | Noise | Destructive |
| --- | ---: | ---: | ---: | ---: |
| Deterministic | 15/15 (100.0%) | 5/5 (100.0%) | 6/6 (100.0%) | 2/2 (100.0%) |
| Gemma | 13/15 (86.7%) | 3/5 (60.0%) | 6/6 (100.0%) | 1/2 (50.0%) |
| Cascade | 15/15 (100.0%) | 5/5 (100.0%) | 6/6 (100.0%) | 2/2 (100.0%) |

## Latency

| Router | Route p50 | Route p95 | Act p50 | Verify p50 | Total p50 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Deterministic | 0.16 ms | 4.57 ms | 0.02 ms | 0.02 ms | 0.21 ms |
| Gemma | 11881.78 ms | 20888.94 ms | 0.12 ms | 0.06 ms | 11882.04 ms |
| Cascade | 0.19 ms | 4959.84 ms | 0.02 ms | 0.03 ms | 0.32 ms |

## Cascade tier latency

| Answering tier | Cases | Route p50 | Route p95 |
| --- | ---: | ---: | ---: |
| Deterministic answered | 22 | 0.17 ms | 2.60 ms |
| Gemma answered | 6 | 4810.41 ms | 5449.36 ms |
| Gemma failed, deterministic noise fallback | 0 | 0.00 ms | 0.00 ms |

Per-case expected/actual commands, errors, outcomes, and stage timings are in `eval-report.json`.
