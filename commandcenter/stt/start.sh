#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_NAME="${1:-base.en}"
MODEL="$HERE/models/ggml-$MODEL_NAME.bin"

if [[ ! -x "$HERE/vendor/whisper.cpp/build/bin/whisper-server" ]]; then
  echo "whisper-server is not built; run ./build.sh" >&2
  exit 1
fi
if [[ ! -s "$MODEL" ]]; then
  echo "model is missing: $MODEL; run ./download-models.sh" >&2
  exit 1
fi

export WHISPER_MODEL="$MODEL"
exec node "$HERE/bridge.mjs"
