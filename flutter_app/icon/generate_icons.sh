#!/usr/bin/env bash
# Regenerates every app icon from the brand SVGs in this directory.
# Requires: rsvg-convert (brew install librsvg) and ImageMagick (brew install imagemagick).
#
# Variants:
#   icon.svg            master — dark rounded square + gradient tile + dark ">_" glyph
#   icon_ios.svg        full-bleed opaque square (Apple applies the rounded mask; no alpha)
#   icon_maskable.svg   full-bleed dark bg, composition fits the maskable safe zone
#   icon_foreground.svg Android adaptive-icon foreground (glyph only, safe-zone padding)
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"

render() { # render <svg> <size> <out>
  rsvg-convert -w "$2" -h "$2" "$1" -o "$3"
}

# Keep the master PNG next to the SVGs for reference.
render icon.svg 1024 icon_1024.png

# --- Android -----------------------------------------------------------------
AND="$ROOT/android/app/src/main/res"
for spec in "mdpi 48" "hdpi 72" "xhdpi 96" "xxhdpi 144" "xxxhdpi 192"; do
  set -- $spec
  render icon.svg "$2" "$AND/mipmap-$1/ic_launcher.png"
done
for spec in "mdpi 108" "hdpi 162" "xhdpi 216" "xxhdpi 324" "xxxhdpi 432"; do
  set -- $spec
  render icon_foreground.svg "$2" "$AND/mipmap-$1/ic_launcher_foreground.png"
done

# --- iOS (opaque, no alpha) --------------------------------------------------
IOS="$ROOT/ios/Runner/Assets.xcassets/AppIcon.appiconset"
for spec in "Icon-App-20x20@1x.png 20" "Icon-App-20x20@2x.png 40" "Icon-App-20x20@3x.png 60" \
            "Icon-App-29x29@1x.png 29" "Icon-App-29x29@2x.png 58" "Icon-App-29x29@3x.png 87" \
            "Icon-App-40x40@1x.png 40" "Icon-App-40x40@2x.png 80" "Icon-App-40x40@3x.png 120" \
            "Icon-App-60x60@2x.png 120" "Icon-App-60x60@3x.png 180" \
            "Icon-App-76x76@1x.png 76" "Icon-App-76x76@2x.png 152" "Icon-App-83.5x83.5@2x.png 167" \
            "Icon-App-1024x1024@1x.png 1024"; do
  set -- $spec
  rsvg-convert -w "$2" -h "$2" icon_ios.svg -o "$IOS/$1"
  magick "$IOS/$1" -alpha remove -alpha off "$IOS/$1"
done

# --- Web ---------------------------------------------------------------------
WEB="$ROOT/web"
render icon.svg 192 "$WEB/icons/Icon-192.png"
render icon.svg 512 "$WEB/icons/Icon-512.png"
render icon_maskable.svg 192 "$WEB/icons/Icon-maskable-192.png"
render icon_maskable.svg 512 "$WEB/icons/Icon-maskable-512.png"
render icon.svg 64 "$WEB/favicon.png"

# --- macOS -------------------------------------------------------------------
MAC="$ROOT/macos/Runner/Assets.xcassets/AppIcon.appiconset"
for size in 16 32 64 128 256 512 1024; do
  render icon.svg "$size" "$MAC/app_icon_$size.png"
done

# --- Windows (multi-size ICO) -------------------------------------------------
WIN="$ROOT/windows/runner/resources"
TMP_ICO="$(mktemp -d)"
for size in 16 24 32 48 64 128 256; do
  render icon.svg "$size" "$TMP_ICO/$size.png"
done
magick "$TMP_ICO/16.png" "$TMP_ICO/24.png" "$TMP_ICO/32.png" "$TMP_ICO/48.png" \
       "$TMP_ICO/64.png" "$TMP_ICO/128.png" "$TMP_ICO/256.png" "$WIN/app_icon.ico"
rm -rf "$TMP_ICO"

echo "All icons regenerated."
