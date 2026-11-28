#!/usr/bin/env bash
# Release-notes generator (issue #282): useful, mechanical notes for every
# release path — no more "Release v$next" filler bodies.
#
# Usage: release_notes.sh <version> [range_start]
#   version     bare X.Y.Z or vX.Y.Z
#   range_start optional git ref for the fallback range (default: the
#               newest tag other than vX.Y.Z itself)
#
# Order of preference:
#   1. the CHANGELOG.md `## <version>` section (curated per-release notes);
#   1b. (gh-2463) the pending `changelog/entries/*.md` aggregate via
#      scripts/gen_changelog.dart — per-change entry files replaced the
#      shared-file curation (one file per PR, zero merge conflicts); the
#      aggregate is flat bullets in entry order, content-identical in shape
#      to the old curated Unreleased body. A broken entry FAILS LOUD here:
#      silently dropping it would ship notes missing that change;
#   1c. (gh-1522) the curated `## Unreleased` body — the pre-gh-2463
#      curation window (the generated CHANGELOG.md index no longer carries
#      one; kept for compatibility with any remaining curated file);
#   2. conventional commits since the previous tag, grouped
#      Features / Fixes / Maintenance, capped at 50 lines with an
#      "…and N more" line (issue #282 E4);
#   3. no commits since the previous tag (re-tag) -> a clean
#      "No changes" body, never an empty page (issue #282 E5/AC5).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

version="${1:?usage: release_notes.sh <version> [range_start]}"
version="${version#v}"
range_start="${2:-}"

# ── 1. CHANGELOG.md section for the version ────────────────────────────────
if [ -f CHANGELOG.md ]; then
  # gh-1522 rework (PR #1526): more than one `## Unreleased` header is a
  # merge/bot artifact duplicating the curation window — the preference-1b
  # awk below stops at the FIRST header, so the second section's entries
  # would silently never ship. Fail loud instead of publishing notes that
  # dropped content (pinned by the AC5 duplicate-Unreleased test).
  unreleased_count=$(grep -c '^## Unreleased[ \t]*$' CHANGELOG.md || true)
  if [ "$unreleased_count" -gt 1 ]; then
    echo "::error::CHANGELOG.md carries $unreleased_count '## Unreleased' sections — entries past the first silently never ship; keep exactly one (gh-1522 curation convention)" >&2
    exit 1
  fi
  section=$(awk -v ver="$version" '
    BEGIN { esc = ver; gsub(/\./, "\\.", esc) }
    $0 ~ "^## " esc "[[:space:]]*$" { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' CHANGELOG.md)
  if [ -n "$(printf '%s' "$section" | tr -d '[:space:]')" ]; then
    printf '%s\n' "$section"
    exit 0
  fi
  # gh-1522 preference 1c: a pending curated `## Unreleased` section is
  # this release's notes (the stage-time stamper folds it under the tag's
  # generated section header). Captured here, printed only if the NEWER
  # gh-2463 entries level (below) yields nothing.
  section=$(awk '
    /^## Unreleased[ \t]*$/ { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' CHANGELOG.md)
fi

# gh-2463 preference 1b: the pending changelog/entries aggregate. dart
# missing (or the dir absent) falls through to the legacy levels — a
# generator FAILURE with entries present is loud (notes missing an entry
# is a shipped omission, not a fallback situation).
if command -v dart >/dev/null 2>&1 && [ -d changelog/entries ]; then
  gen_err="$(mktemp "${TMPDIR:-/tmp}/release-notes-gen.XXXXXX")"
  gen_ok=0
  entries_section=$(dart "$script_dir/gen_changelog.dart" --stdout 2>"$gen_err") && gen_ok=1
  cat "$gen_err" >&2
  rm -f "$gen_err"
  if [ "$gen_ok" -ne 1 ]; then
    echo "::error::changelog/entries aggregation failed — refusing to produce release notes that silently drop entries (gh-2463); fix or remove the broken entry file(s)" >&2
    exit 1
  fi
  if [ -n "$(printf '%s' "$entries_section" | tr -d '[:space:]')" ]; then
    printf '%s\n' "$entries_section"
    exit 0
  fi
fi

# gh-1522 preference 1c (continued): the captured curated Unreleased body.
if [ -n "$(printf '%s' "${section:-}" | tr -d '[:space:]')" ]; then
  printf '%s\n' "$section"
  exit 0
fi

# ── 2. conventional-commit fallback ────────────────────────────────────────
if [ -z "$range_start" ]; then
  range_start=$(git tag --sort=-v:refname 2>/dev/null \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -v -x "v$version" | head -1 || true)
fi

range="HEAD"
[ -n "$range_start" ] && range="$range_start..HEAD"
# The release-bump commit itself is noise in its own release notes.
commits=$(git log "$range" --pretty='%s' --no-merges 2>/dev/null \
  | grep -v '^chore(release):' || true)

if [ -z "$commits" ]; then
  # ── 3. re-tag: nothing changed since the previous release ───────────────
  echo "No changes since ${range_start:-the previous release}."
  exit 0
fi

cap="${RELEASE_NOTES_MAX:-50}"
feats=""; fixes=""; chores=""
shown=0
overflow=0
while IFS= read -r subject; do
  [ -n "$subject" ] || continue
  if [ "$shown" -ge "$cap" ]; then
    overflow=$((overflow + 1))
    continue
  fi
  shown=$((shown + 1))
  case "$subject" in
    feat:*|feat\(*) feats="$feats- $subject
" ;;
    fix:*|fix\(*)  fixes="$fixes- $subject
" ;;
    *)             chores="$chores- $subject
" ;;
  esac
done <<< "$commits"

echo "## What's changed"
echo
[ -n "$feats" ]  && printf '### Features\n%s\n' "$feats"
[ -n "$fixes" ]  && printf '### Fixes\n%s\n' "$fixes"
[ -n "$chores" ] && printf '### Maintenance\n%s\n' "$chores"
[ "$overflow" -gt 0 ] && printf '…and %d more\n' "$overflow"
exit 0
