#!/bin/bash
# Renders all promo variants (silent video via yoclip CLI) and muxes the
# voiceover + music bed per language. Outputs land in out/ (gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."

CLI=/Users/Uladzimir_Klyshevich/git/yoclip/packages/yoclip_cli
PROJ=$(pwd)
mkdir -p out build/render

render_one() { # <name> <lang> <variant-or-empty>
  local name=$1 lang=$2 variant=$3
  local silent="$PROJ/build/render/${name}_silent.mp4"
  local args=(render --project "$PROJ" --output "$silent")
  [ -n "$variant" ] && args+=(--variant "$variant")
  (cd "$CLI" && dart run bin/yoclip.dart "${args[@]}")
  ffmpeg -y -v error -i "$silent" \
    -i "assets/voiceover/vo_${lang}.wav" -i assets/audio/music_bed.wav \
    -filter_complex "[1:a]volume=1.0[vo];[2:a]volume=0.25[mu];[vo][mu]amix=inputs=2:normalize=0[a]" \
    -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k \
    -movflags +faststart -pix_fmt yuv420p \
    "out/${name}.mp4"
  echo "== out/${name}.mp4"
  ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,r_frame_rate,pix_fmt -of csv "out/${name}.mp4"
}

render_one fa_promo_app_preview_en en app_preview_en
render_one fa_promo_app_preview_ru ru app_preview_ru
render_one fa_promo_social_en      en social_en
render_one fa_promo_social_ru      ru social_ru
render_one fa_promo_youtube_en     en ""
render_one fa_promo_youtube_ru     ru youtube_ru
