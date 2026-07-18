#!/bin/bash
# Launch the signed native app in deterministic replay mode and require an
# app-authored receipt proving the same version patch, ledger, and verifier path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/macos/build"
APP="$DERIVED/Build/Products/Debug/VoiceOps.app"
TEMP_DIR="$(mktemp -d -t voiceops-order-rescue-replay)"
REPORT="$TEMP_DIR/report.json"
SCREENSHOT="${VOICEOPS_REPLAY_SCREENSHOT_OUT:-$TEMP_DIR/companion.png}"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

strip_app_metadata() {
  xattr -cr "$APP"
  xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
  xattr -d com.apple.ResourceFork "$APP" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$APP" 2>/dev/null || true
}

if [[ "${VOICEOPS_SKIP_BUILD:-0}" != "1" ]]; then
  if [[ -d "$APP" ]]; then strip_app_metadata; fi
  xcodebuild -quiet -project "$ROOT/macos/VoiceOps.xcodeproj" -scheme VoiceOps \
    -configuration Debug -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO build
fi
test -x "$APP/Contents/MacOS/VoiceOps"

# Cloud-backed workspaces can attach Finder metadata after a prior build.
# Clear only the generated app bundle before the final ad-hoc signature.
SIGNED=false
for _ in {1..5}; do
  strip_app_metadata
  if codesign --force --deep --sign - "$APP"; then
    SIGNED=true
    break
  fi
done
test "$SIGNED" = true

"$APP/Contents/MacOS/VoiceOps" \
  --replay-order-rescue \
  --replay-report="$REPORT" \
  --replay-screenshot="$SCREENSHOT" &
APP_PID=$!

for _ in {1..200}; do
  if [[ -s "$REPORT" ]]; then break; fi
  if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
  sleep 0.05
done

wait "$APP_PID" || true
test -s "$REPORT"
test -s "$SCREENSHOT"

python3 - "$REPORT" "$SCREENSHOT" <<'PY'
import json
import struct
import sys

report = json.load(open(sys.argv[1]))
assert report["mode"] == "deterministic_replay"
assert report["terminal_state"] == "succeeded", report
assert report["summary"] == "ORDER RESCUE COMPLETED — 5/5 CHECKS PASSED"
assert report["task_version"] == 2
assert report["patch"]["base_version"] == 1
assert report["patch"]["new_version"] == 2
assert len(report["ledger"]) >= 5
assert {event["event_type"] for event in report["ledger"]} == {
    "observed", "interpreted", "decided", "acted", "verified"
}
checks = {item["predicate_id"]: item["passed"] for item in report["verification"]}
assert len(checks) == 7
assert all(checks.values())
assert checks["no-refund-issued"]
assert checks["no-replacement-created"]
png = open(sys.argv[2], "rb").read()
assert png[:8] == b"\x89PNG\r\n\x1a\n"
width, height = struct.unpack(">II", png[16:24])
assert width >= 500 and height >= 600, (width, height)
assert len(png) >= 50_000, len(png)
print("NATIVE ORDER RESCUE REPLAY VERIFIED")
print(report["summary"])
print(f"task_version={report['task_version']} ledger_events={len(report['ledger'])} predicates={len(checks)}")
print(f"companion_screenshot={width}x{height}")
PY
