# Voice Command Center Eval

Generated: 2026-07-18T07:56:36.516Z

Fixtures: 28

## Summary

- Deterministic router: 28/28 (100.0%)
- Gemma router (local-exec:ollama): 0/28 (0.0%)
- Deterministic noise false-fire rate: 0.0%
- Gemma noise false-fire rate: 0.0%
- Deterministic end-to-end verified: 100.0%
- Gemma end-to-end verified: 0.0%

> Gemma results came from the configured local runtime.

## Accuracy by category

| Router | Clear | Fuzzy | Noise | Destructive |
| --- | ---: | ---: | ---: | ---: |
| Deterministic | 15/15 (100.0%) | 5/5 (100.0%) | 6/6 (100.0%) | 2/2 (100.0%) |
| Gemma | 0/15 (0.0%) | 0/5 (0.0%) | 0/6 (0.0%) | 0/2 (0.0%) |

## Latency

| Router | Route p50 | Route p95 | Act p50 | Verify p50 | Total p50 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Deterministic | 0.26 ms | 3.64 ms | 0.03 ms | 0.03 ms | 0.39 ms |
| Gemma | 0.00 ms | 0.00 ms | 0.00 ms | 0.00 ms | 0.00 ms |

Per-case expected/actual commands, errors, outcomes, and stage timings are in `eval-report.json`.
