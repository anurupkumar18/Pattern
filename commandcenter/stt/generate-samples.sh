#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/samples"
TMP="$HERE/tmp"

command -v say >/dev/null || {
  echo "macOS say is required" >&2
  exit 1
}
command -v ffmpeg >/dev/null || {
  echo "ffmpeg is required (Homebrew: brew install ffmpeg)" >&2
  exit 1
}

mkdir -p "$OUT" "$TMP"

generate() {
  local slug="$1"
  local phrase="$2"
  local aiff="$TMP/$slug.aiff"
  say -v Samantha -r 190 -o "$aiff" "$phrase"
  ffmpeg -hide_banner -loglevel error -y -i "$aiff" \
    -af "adelay=300:all=1,apad=pad_dur=1.4" \
    -ar 16000 -ac 1 -c:a pcm_s16le "$OUT/$slug.wav"
  echo "$OUT/$slug.wav <- $phrase"
}

generate "move-to-evals" "move to evals"
generate "switch-to-noah" "switch to Noah"
generate "tell-design-agent-use-staging" "tell the design agent to use staging"
