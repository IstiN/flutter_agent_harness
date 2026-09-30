#!/usr/bin/env bash
# Package the Flutter web build as a rehostable SPA bundle (issue #1100).
#
#   usage: package_web_spa.sh <build-web-dir> <output-zip>
#
# Takes a flutter build/web produced with the Pages base (`--base-href /app/`,
# the same command as .github/workflows/pages.yml), rewrites <base href> to
# `./` on a COPY, guards the absolute-path touchpoints (AC3), and zips the
# result as fa-web-spa.zip. Never mutates the input directory — the Pages
# deploy must stay byte-identical (AC4).
#
# Verified by the owner's manual rehost pass (2026-09-30): the base tag is
# the ONLY absolute-path touchpoint in the four files below, and a relative
# base runs on path-prefixed hosts and inside sandboxed iframes. See
# docs/web-rehosting.md.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <build-web-dir> <output-zip>" >&2
  exit 64
fi

src="$(cd "$1" && pwd)"
out="$2"; out="$(mkdir -p "$(dirname "$out")" && cd "$(dirname "$out")" && pwd)/$(basename "$out")"
# Pinned absolute base this repo builds with (pages.yml); a future base change
# updates pages.yml AND this guard together.
forbidden='/app/'

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R "$src/." "$stage/"

# The one surgical edit (OQ1): patch the tag, never rebuild with a different
# base — one build shape everywhere, zero divergence from fa1.dev.
sed -i.bak -E 's|<base href="[^"]*">|<base href="./">|' "$stage/index.html"
rm -f "$stage/index.html.bak"

# AC3 guard: relative base present, zero absolute /app/ references left in
# the four touchpoint files. Failing here fails the release pipeline.
for f in index.html flutter_service_worker.js flutter_bootstrap.js manifest.json; do
  if [ ! -f "$stage/$f" ]; then
    echo "::error::package_web_spa: missing $f in $src — not a flutter build/web output?" >&2
    exit 1
  fi
  if grep -Fq "$forbidden" "$stage/$f"; then
    echo "::error::package_web_spa: absolute $forbidden reference found in $f (AC3 #1100)" >&2
    # No head-truncation: grep|head closes the pipe early -> SIGPIPE 141
    # under pipefail; these files are small, print every match.
    grep -Fn "$forbidden" "$stage/$f" >&2
    exit 1
  fi
done
if ! grep -Fq '<base href="./">' "$stage/index.html"; then
  echo "::error::package_web_spa: index.html has no relative <base href=\"./\"> after patch" >&2
  exit 1
fi

rm -f "$out"
(cd "$stage" && zip -qr "$out" .)
echo "packaged $(du -h "$out" | cut -f1) -> $out"
unzip -l "$out" | grep -E 'index.html|flutter_bootstrap.js' || true
