#!/bin/bash
# Run every automated check. The deterministic evaluation suite (evals/) lands
# in Phase 7; until then this runs unit, contract, and end-to-end mock checks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Python tests"
(cd "$ROOT/agent" && uv run python -m pytest)

echo "==> Swift tests"
swift test --package-path "$ROOT/macos"

echo "==> End-to-end mock exchange"
(cd "$ROOT" && swift run -q --package-path "$ROOT/macos" voiceops-mock-client)

echo "==> All checks passed"
