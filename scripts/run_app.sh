#!/bin/bash
# Build and launch VoiceOps.app from the command line — no Xcode IDE needed,
# only the command-line toolchain. Build output stays in macos/build/.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Building VoiceOps.app (ad-hoc signed — required for microphone access)"
xcodebuild -project "$ROOT/macos/VoiceOps.xcodeproj" -scheme VoiceOps \
  -configuration Debug -derivedDataPath "$ROOT/macos/build" \
  build CODE_SIGN_IDENTITY=- -quiet

APP="$ROOT/macos/build/Build/Products/Debug/VoiceOps.app"
echo "==> Launching $APP"
open "$APP"
echo "==> VoiceOps is running: look for the waveform icon in the menu bar, then press ⌃⌥V and speak."
