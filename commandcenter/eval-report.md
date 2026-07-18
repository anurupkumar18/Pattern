# Voice Command Center Eval

Generated: 2026-07-18T11:33:11.879Z

Fixtures: 28

## Summary

- Deterministic router: 28/28 (100.0%)
- Gemma router (ollama-http:gemma4): 27/28 (96.4%)
- Deterministic noise false-fire rate: 0.0%
- Gemma noise false-fire rate: 0.0%
- Deterministic end-to-end verified: 100.0%
- Gemma end-to-end verified: 96.4%

> Gemma results came from the configured local runtime.

## Accuracy by category

| Router | Clear | Fuzzy | Noise | Destructive |
| --- | ---: | ---: | ---: | ---: |
| Deterministic | 15/15 (100.0%) | 5/5 (100.0%) | 6/6 (100.0%) | 2/2 (100.0%) |
| Gemma | 14/15 (93.3%) | 5/5 (100.0%) | 6/6 (100.0%) | 2/2 (100.0%) |

## Latency

| Router | Route p50 | Route p95 | Act p50 | Verify p50 | Total p50 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Deterministic | 0.10 ms | 0.75 ms | 0.01 ms | 0.01 ms | 0.13 ms |
| Gemma | 10027.65 ms | 12986.59 ms | 0.19 ms | 0.09 ms | 10027.83 ms |

Per-case expected/actual commands, errors, outcomes, and stage timings are in `eval-report.json`.
