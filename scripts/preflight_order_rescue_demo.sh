#!/bin/bash
# Read-only go/no-go gate for the live Conversational Order Rescue demo.
# Never prints credential values or performs Shopify/Slack writes.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/macos/build/Build/Products/Debug/VoiceOps.app"
KEYCHAIN_SERVICE="com.voiceops.vlm"
FAILURES=0

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
note() { printf 'CHECK %s\n' "$1"; }

keychain_value() {
  security find-generic-password \
    -s "$KEYCHAIN_SERVICE" \
    -a "$1" \
    -w 2>/dev/null
}

printf 'VoiceOps live Order Rescue preflight\n\n'

for command in uv swift security; do
  if command -v "$command" >/dev/null 2>&1; then
    pass "$command is available"
  else
    fail "$command is not installed"
  fi
done

if [[ -x "$APP/Contents/MacOS/VoiceOps" ]]; then
  pass "native VoiceOps.app is built"
else
  fail "native VoiceOps.app is missing; run scripts/run_app.sh on a Mac with full Xcode"
fi

if keychain_value "openai-api-key" >/dev/null; then
  pass "OpenAI credential is present in Keychain"
else
  fail "OpenAI credential is missing from Voice & Intelligence Settings"
fi

declare -a COMMERCE_ACCOUNTS=(
  "voiceops-shopify-shop:VOICEOPS_SHOPIFY_SHOP"
  "voiceops-shopify-token:VOICEOPS_SHOPIFY_TOKEN"
  "voiceops-shopify-order-id:VOICEOPS_SHOPIFY_ORDER_ID"
  "voiceops-slack-bot-token:VOICEOPS_SLACK_BOT_TOKEN"
  "voiceops-slack-channel-id:VOICEOPS_SLACK_CHANNEL_ID"
)

COMMERCE_READY=true
for mapping in "${COMMERCE_ACCOUNTS[@]}"; do
  account="${mapping%%:*}"
  variable="${mapping#*:}"
  if value="$(keychain_value "$account")" && [[ -n "$value" ]]; then
    export "$variable=$value"
    pass "$variable is present in Keychain"
  else
    COMMERCE_READY=false
    fail "$variable is missing from Voice & Intelligence Settings"
  fi
done

if [[ "$COMMERCE_READY" == true ]] && command -v uv >/dev/null 2>&1; then
  PROBE_OUTPUT="$(mktemp -t voiceops-live-probe)"
  if (
    cd "$ROOT/agent"
    uv run python -m tests.live_shopify_probe
  ) >"$PROBE_OUTPUT" 2>&1; then
    pass "Shopify and Slack read-only health probes selected shopify.live+slack.live"
  else
    reason="$(
      python3 - "$PROBE_OUTPUT" <<'PY'
import json
import sys

text = open(sys.argv[1], encoding="utf-8").read()
try:
    payload = json.loads(text[: text.rfind("}") + 1])
    print(payload.get("reason", "live adapter probe failed"))
except Exception:
    print("live adapter probe failed; run the documented probe for details")
PY
    )"
    fail "$reason"
  fi
  rm -f "$PROBE_OUTPUT"
else
  fail "live Shopify/Slack probe could not run because credentials or uv are missing"
fi

printf '\n'
note "In Voice & Intelligence Settings, Microphone must say Ready"
note "In Voice & Intelligence Settings, Screen Recording must say Ready"
note "In Voice & Intelligence Settings, Accessibility must say Ready"
note "Slack bot must belong to #shipping-escalations"
note "Order #1842 must be reset before the live run"

printf '\n'
if [[ "$FAILURES" -eq 0 ]]; then
  printf 'READY Automated preflight passed. Complete the five CHECK items above before the demo.\n'
  exit 0
fi

printf 'BLOCKED %d automated preflight check(s) failed. Do not claim a live run yet.\n' "$FAILURES"
exit 1
