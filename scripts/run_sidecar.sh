#!/bin/bash
# Start the Python sidecar: NDJSON envelopes on stdin/stdout (ARD §7).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec uv run --project "$ROOT/agent" voiceops-agent
