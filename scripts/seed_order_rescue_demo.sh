#!/bin/bash
# Open the exact local Order Rescue evidence surface used by the hero demo.
# The page is credential-free and performs no writes or network requests.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SURFACE="$ROOT/fixtures/web/order_rescue.html"

test -f "$SURFACE"
open -a Safari "$SURFACE"

echo "seed_order_rescue_demo: opened local Order #1842 / Maya Chen workspace"
echo "Initial voice request and correction: docs/DEMO.md"
echo "Preflight gate: scripts/rehearse_order_rescue.sh"
