#!/usr/bin/env bash
# Prunes mobile-only / bundled-dead weight from a built flutter_assets tree
# (#1096 size diet). Every packaging surface — mac DMG/ZIP (sandboxed AND
# no-sandbox), the Pages web demo, the browser extension, the Office add-in —
# calls THIS script so the rulebook lives in one place.
#
# Loud by design: a requested path that no longer exists FAILS the build.
# A bare `rm -rf` exits 0 on a drifted layout and silently ships the fat
# bundle — layout drift must surface here, not in the artifact size.
#
# Usage: prune_flutter_assets.sh <flutter_assets_root> <rel-path> [rel-path...]
set -euo pipefail

root="${1:?usage: prune_flutter_assets.sh <flutter_assets_root> <rel...>}"
shift
[ -d "$root" ] || { echo "::error::flutter_assets root not found: $root" >&2; exit 1; }

total_kib=0
for rel in "$@"; do
  target="$root/$rel"
  if [ ! -e "$target" ]; then
    echo "::error::prune target missing — flutter_assets layout drifted? $target" >&2
    exit 1
  fi
  kib=$(du -sk "$target" | cut -f1)
  rm -rf "$target"
  total_kib=$((total_kib + kib))
  echo "pruned $rel (${kib}KiB)"
done
echo "prune_flutter_assets: ${total_kib}KiB freed from $root"
