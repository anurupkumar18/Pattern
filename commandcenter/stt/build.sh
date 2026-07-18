#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR="$HERE/vendor/whisper.cpp"
WHISPER_TAG="v1.7.6"
WHISPER_COMMIT="a8d002cfd879315632a579e73f0148d06959de36"

command -v cmake >/dev/null || {
  echo "cmake is required (Homebrew: brew install cmake)" >&2
  exit 1
}

mkdir -p "$HERE/vendor" "$HERE/models" "$HERE/samples" "$HERE/tmp" "$HERE/logs"

if [[ ! -d "$VENDOR/.git" ]]; then
  git clone --branch "$WHISPER_TAG" --depth 1 \
    https://github.com/ggml-org/whisper.cpp.git "$VENDOR"
fi

actual_commit="$(git -C "$VENDOR" rev-parse HEAD)"
if [[ "$actual_commit" != "$WHISPER_COMMIT" ]]; then
  echo "unexpected whisper.cpp revision: $actual_commit" >&2
  echo "expected pinned $WHISPER_TAG at $WHISPER_COMMIT" >&2
  exit 1
fi

cmake -S "$VENDOR" -B "$VENDOR/build" \
  -DGGML_METAL=ON \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_BUILD_SERVER=ON \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$VENDOR/build" --config Release -j "$(sysctl -n hw.logicalcpu)"

"$VENDOR/build/bin/whisper-server" --help >/dev/null
echo "Metal whisper.cpp build ready: $VENDOR/build/bin/whisper-server"
