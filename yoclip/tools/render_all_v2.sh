#!/bin/bash
# Renders the Fa promo v2 variants (App Preview EN + RU), muxes the v2 music
# bed, and extracts QA frames (1 fps) from every final mp4.
#
# Usage: tools/render_all_v2.sh [en|ru|all]   (default: all)
set -euo pipefail
cd "$(dirname "$0")/.."

CLI=/Users/Uladzimir_Klyshevich/git/yoclip/packages/yoclip_cli
PROJECT="$PWD"
MUSIC=assets/audio/music_v2.m4a
mkdir -p out build/qa_v2

render_variant() {
  local variant="$1" lang="$2"
  local raw="out/fa_promo_v2_app_preview_${lang}_silent.mp4"
  local final="out/fa_promo_v2_app_preview_${lang}.mp4"
  echo "== render $variant =="
  (cd "$CLI" && dart run bin/yoclip.dart render \
    --project "$PROJECT" --variant "$variant" --output "$PROJECT/$raw")
  echo "== mux $lang =="
  ffmpeg -y -v error -i "$raw" -i "$MUSIC" \
    -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k \
    -movflags +faststart -shortest "$final"
  rm -f "$raw"
  echo "== qa frames $lang =="
  mkdir -p "build/qa_v2/$lang"
  ffmpeg -y -v error -i "$final" -vf fps=1 "build/qa_v2/$lang/f%03d.png"
  ffprobe -v error -show_entries format=duration,size -of csv=p=0 "$final"
}

case "${1:-all}" in
  en) render_variant app_preview_en en ;;
  ru) render_variant app_preview_ru ru ;;
  all)
    render_variant app_preview_en en
    render_variant app_preview_ru ru
    ;;
esac
echo "done."
