#!/bin/bash
# One-time developer setup: Python env + Swift build. Idempotent.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v uv >/dev/null || { echo "bootstrap: install uv first (https://docs.astral.sh/uv/)"; exit 1; }
command -v swift >/dev/null || { echo "bootstrap: install Xcode command line tools first"; exit 1; }

echo "==> Syncing Python sidecar (agent/)"
uv sync --project "$ROOT/agent"

echo "==> Building Swift package (macos/)"
swift build --package-path "$ROOT/macos"

echo "==> Bootstrap complete. Try: scripts/run_sidecar.sh"
