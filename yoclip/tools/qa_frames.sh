#!/bin/bash
# Frame-QA extraction: ~1 frame/sec from every final mp4 into build/qa/<name>/.
# The app_preview_en pass is additionally covered by `yoclip screenshot`
# (see QA.md); ffmpeg extraction validates what is actually muxed in the file.
set -euo pipefail
cd "$(dirname "$0")/.."
for f in out/*.mp4; do
  name=$(basename "$f" .mp4)
  dir="build/qa/$name"
  mkdir -p "$dir"
  rm -f "$dir"/*.png 2>/dev/null || true
  ffmpeg -y -v error -i "$f" -vf "fps=1,scale=540:-1" "$dir/%02d.png"
  echo "$name: $(ls "$dir" | wc -l | tr -d ' ') frames"
done
