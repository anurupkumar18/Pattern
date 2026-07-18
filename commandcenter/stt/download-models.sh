#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="$HERE/models"
BASE_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

mkdir -p "$MODEL_DIR"

download() {
  local name="$1"
  local destination="$MODEL_DIR/ggml-$name.bin"
  if [[ -s "$destination" ]]; then
    echo "already present: $destination"
    return
  fi
  curl -L --fail --retry 3 --continue-at - \
    -o "$destination.part" "$BASE_URL/ggml-$name.bin"
  mv "$destination.part" "$destination"
  echo "downloaded: $destination"
}

download "base.en"
download "small.en"
