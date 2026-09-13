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
#   1. the CHANGELOG.md `## <version>` section (curated `## Unreleased`
#      content or generated bullets land there via auto_release.sh);
#   2. conventional commits since the previous tag, grouped
#      Features / Fixes / Maintenance, capped at 50 lines with an
#      "…and N more" line (issue #282 E4);
#   3. no commits since the previous tag (re-tag) -> a clean
#      "No changes" body, never an empty page (issue #282 E5/AC5).
set -euo pipefail

version="${1:?usage: release_notes.sh <version> [range_start]}"
version="${version#v}"
range_start="${2:-}"

# ── 1. CHANGELOG.md section for the version ────────────────────────────────
if [ -f CHANGELOG.md ]; then
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
