#!/bin/bash
# Build and launch VoiceOps.app from the command line — no Xcode IDE needed,
# only the command-line toolchain. Build output stays in macos/build/.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$ROOT/macos/build"
APP="$DERIVED/Build/Products/Debug/VoiceOps.app"

strip_app_metadata() {
  xattr -cr "$APP"
  xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
  xattr -d com.apple.ResourceFork "$APP" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$APP" 2>/dev/null || true
}

echo "==> Building VoiceOps.app (ad-hoc signed — required for microphone access)"
if [[ -d "$APP" ]]; then strip_app_metadata; fi
xcodebuild -project "$ROOT/macos/VoiceOps.xcodeproj" -scheme VoiceOps \
  -configuration Debug -derivedDataPath "$DERIVED" \
  build CODE_SIGNING_ALLOWED=NO -quiet

SIGNED=false
for _ in {1..5}; do
  strip_app_metadata
  if codesign --force --deep --sign - "$APP"; then
    SIGNED=true
    break
  fi
done
test "$SIGNED" = true

echo "==> Launching $APP"
open "$APP"
echo "==> VoiceOps is running: look for the waveform icon in the menu bar, then press ⌃⌥V and speak."
