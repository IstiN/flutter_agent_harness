#!/usr/bin/env bash
# build_fa_clip.sh — compile the native `fa-clip` pasteboard helper (gh-2040).
#
# Usage: build_fa_clip.sh [<output-path>]
#
# The helper rides the macOS CLI bundles (bundle/bin/fa-clip, per-arch —
# the release matrix builds each arch on a native runner, gh-2040 AC8) and
# installs beside the `fa` binary, which resolves it relative to its own
# executable path. Exit 0 = binary written; exit 1 = no toolchain (callers
# treat a missing helper as the named pasteboard-unavailable path, AC5).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/tools/fa-clip/fa-clip.swift"
OUT="${1:-$REPO_ROOT/tools/fa-clip/fa-clip}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "fa-clip is macOS-only — not building on $(uname -s)" >&2
  exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found — fa-clip not built (paste degrades to the named unavailable path, gh-2040 AC5)" >&2
  exit 1
fi

case "$(uname -m)" in
  arm64) target="arm64-apple-macos10.13" ;;
  x86_64) target="x86_64-apple-macos10.13" ;;
  *) echo "unsupported arch for fa-clip: $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$OUT")"
swiftc -O -target "$target" -o "$OUT" "$SRC"
chmod +x "$OUT"
echo "built $OUT ($target)"
