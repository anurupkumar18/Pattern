# Voice Command Center Eval

Generated: 2026-07-18T11:47:53.806Z

Fixtures: 28

## Summary

- Deterministic router: 28/28 (100.0%)
- Gemma router (ollama-http:gemma4): 27/28 (96.4%)
- Cascade router: 28/28 (100.0%)
- Cascade escalations: 6/28 (0 fallback failures)
- Deterministic noise false-fire rate: 0.0%
- Gemma noise false-fire rate: 0.0%
- Cascade noise false-fire rate: 0.0%
- Deterministic end-to-end verified: 100.0%
- Gemma end-to-end verified: 96.4%
- Cascade end-to-end verified: 100.0%

> Gemma results came from the configured local runtime.

## Accuracy by category

| Router | Clear | Fuzzy | Noise | Destructive |
| --- | ---: | ---: | ---: | ---: |
| Deterministic | 15/15 (100.0%) | 5/5 (100.0%) | 6/6 (100.0%) | 2/2 (100.0%) |
| Gemma | 14/15 (93.3%) | 5/5 (100.0%) | 6/6 (100.0%) | 2/2 (100.0%) |
| Cascade | 15/15 (100.0%) | 5/5 (100.0%) | 6/6 (100.0%) | 2/2 (100.0%) |

## Latency

| Router | Route p50 | Route p95 | Act p50 | Verify p50 | Total p50 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Deterministic | 0.07 ms | 0.59 ms | 0.01 ms | 0.01 ms | 0.10 ms |
| Gemma | 10496.36 ms | 13520.83 ms | 0.35 ms | 0.17 ms | 10501.03 ms |
| Cascade | 0.12 ms | 10259.37 ms | 0.02 ms | 0.01 ms | 0.22 ms |

## Cascade tier latency

| Answering tier | Cases | Route p50 | Route p95 |
| --- | ---: | ---: | ---: |
| Deterministic answered | 22 | 0.09 ms | 2.03 ms |
| Gemma answered | 6 | 9364.08 ms | 10595.54 ms |
| Gemma failed, deterministic noise fallback | 0 | 0.00 ms | 0.00 ms |

Per-case expected/actual commands, errors, outcomes, and stage timings are in `eval-report.json`.
