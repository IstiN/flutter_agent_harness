#!/usr/bin/env bash
# Bound a release-body notes file under GitHub's release-body cap (gh-237).
#
# `gh release create`/`gh release edit` hard-reject a body over
# 125,000 characters with HTTP 422 "body is too long (maximum is
# 125000 characters)" — run 44680647719 (daily-publish cli leg, v1.0.756)
# red THREE attach jobs (build-macos-cli arm64/x64 + build-extension)
# with exactly that error: scripts/release_notes.sh returned the curated
# `## Unreleased` CHANGELOG section (131,072 bytes by then) as the release
# body, the create failed, release_lazy_draft.sh swallowed the failure,
# and every release_asset_gate.sh call died with "release not found".
#
# This helper bounds ONE notes file IN PLACE:
#   - at/under the cap -> untouched no-op;
#   - over the cap     -> truncated at the last whole line that fits
#     (UTF-8-safe byte fallback for a newline-less giant line), plus an
#     explicit marker naming CHANGELOG.md as the full source. The release
#     page body is a view of the curated notes, never the store of them.
#
# Callers: the release-body WRITERS only (release_lazy_draft.sh,
# release_attach_or_create.sh). Deliberately NOT release_notes.sh itself:
# scripts/stamp_staged_release.sh pipes release_notes.sh output into the
# staged pub.dev CHANGELOG, where truncation would silently drop curated
# content from the published package.
#
# Usage: release_notes_cap.sh <file> [cap_bytes]
#   cap_bytes defaults to 120000 — comfortably under the 125,000-character
#   API limit (UTF-8 bytes >= characters, so a byte ceiling is
#   conservative); the slack also absorbs the marker line itself.
set -euo pipefail

file="${1:?usage: release_notes_cap.sh <file> [cap_bytes]}"
cap="${2:-120000}"

if [ ! -f "$file" ]; then
  echo "::error::release_notes_cap.sh: notes file '$file' does not exist — nothing to bound" >&2
  exit 1
fi

size=$(wc -c < "$file" | tr -d ' ')
if [ "$size" -le "$cap" ]; then
  exit 0
fi

python3 - "$file" "$cap" <<'PY'
import sys

path, cap = sys.argv[1], int(sys.argv[2])
data = open(path, "rb").read()
marker_tmpl = "…(truncated — {} bytes dropped; full notes: CHANGELOG.md)\n"
# Reserve marker room: the zero-digit marker plus enough slack for the
# real dropped-count digits (a 20-digit dropped count is 10^19 bytes —
# impossible), so the FINAL file is guaranteed <= cap.
reserved = len(marker_tmpl.format(0).encode()) + 20
keep_cap = cap - reserved
cut = min(keep_cap, len(data))
# Prefer the last whole line within the budget (ASCII '\n' — a byte
# boundary is always a line boundary).
nl = data.rfind(b"\n", 0, cut + 1)
if nl >= 0:
    cut = nl + 1
elif cut > 0:
    # Single giant line: back off to a UTF-8 code-point boundary so the
    # kept prefix stays decodable.
    while cut > 0 and (data[cut] & 0xC0) == 0x80:
        cut -= 1
dropped = len(data) - cut
marker = marker_tmpl.format(dropped).encode()
open(path, "wb").write(data[:cut] + b"\n" + marker)
PY

echo "release_notes_cap: $file bounded $(wc -c < "$file" | tr -d ' ') bytes (was $size, cap $cap)"
