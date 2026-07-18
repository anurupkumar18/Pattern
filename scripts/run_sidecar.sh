#!/bin/bash
# Start the Python sidecar: NDJSON envelopes on stdin/stdout (ARD §7).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/agent"
exec uv run python -m voiceops_agent.main
