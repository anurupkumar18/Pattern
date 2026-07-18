#!/bin/bash
# Run unit, contract, cross-runtime, and deterministic evaluation checks, then
# regenerate the committed machine- and judge-readable correctness reports.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Python tests"
(cd "$ROOT/agent" && uv run python -m pytest)

echo "==> Swift tests"
swift test --package-path "$ROOT/macos"

echo "==> End-to-end mock exchange"
(cd "$ROOT" && swift run -q --package-path "$ROOT/macos" voiceops-mock-client)

echo "==> Deterministic 20-case evaluation report"
(cd "$ROOT/agent" && uv run voiceops-eval \
  --repo-root "$ROOT" \
  --output-dir "$ROOT/evals/reports" \
  --run-id fixture-baseline-v1)

echo "==> All checks passed"
