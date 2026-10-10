#!/usr/bin/env bash
# CHANGELOG size guard (gh-1452): pub.dev server-rejects a publish whose
# CHANGELOG.md exceeds its hard content cap — `Message from server:
# CHANGELOG.md exceeds the maximum content length (262144 bytes)`. v1.0.538
# died at `dart pub publish` AFTER the tag + GitHub release existed, so the
# version never reached pub.dev. The changelog is append-only by convention
# and the auto-release grows it near-daily; nothing bounded it before this
# guard.
#
# Callers (keep both wired — test/changelog_cap_guard_test.dart asserts the
# wiring):
#   - scripts/auto_release.sh   — BEFORE the bump commit/tag (pre-tag
#     fast-fail: the push is what fires tag_release + the publish job);
#   - .github/workflows/ci.yml `publish` job gate — BEFORE staging/upload
#     (the server reject is the worst possible discovery point).
#
# Usage: check_changelog_size.sh [file] [cap_bytes]
#   file  defaults to CHANGELOG.md (the file pub packs);
#   cap   defaults to 262144 (the pub.dev cap) — strict less-than; the
#         override exists for tests.
#
# Exit 0 = under the cap. Exit 1 = missing file or size >= cap, with a
# ::error:: annotation naming the fix (archive the tail).
set -euo pipefail

file="${1:-CHANGELOG.md}"
cap="${2:-262144}"

if [ ! -f "$file" ]; then
  echo "::error::check_changelog_size.sh: $file does not exist — a release without a changelog is a broken release (gh-1452)."
  exit 1
fi

size=$(wc -c < "$file")
if [ "$size" -ge "$cap" ]; then
  echo "::error::$file is $size bytes — pub.dev rejects uploads at/over the ${cap}-byte content cap (gh-1452: v1.0.538 died mid-upload). Archive older entries to CHANGELOG_ARCHIVE.md (keep ~30 recent versions inline) and re-run the release."
  exit 1
fi
echo "$file: $size bytes < $cap-byte cap — ok"
