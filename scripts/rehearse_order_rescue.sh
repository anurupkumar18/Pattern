#!/bin/bash
# One-command deterministic release gate for the delayed-order rescue demo.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/scripts/run_evals.sh"

cd "$ROOT/agent"
if [[ $# -eq 0 ]]; then
    set -- --runs 20
fi
uv run python -m voiceops_agent.evals.order_rescue "$@"
