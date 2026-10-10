#!/usr/bin/env bash
# gh-1522: stamp the staged publish tree with the release version — the git
# tag is the single source of truth, the repo files carry a placeholder
# (0.0.0-dev) and are NEVER mutated by a release.
#
# Usage: stamp_staged_release.sh <stage-dir> <version>
#   <stage-dir> — the staged package tree (scripts/stage_publish_package.sh)
#   <version>   — the release version WITHOUT the leading v (1.0.550)
#
# What it stamps, in order:
#   1. pubspec.yaml `version:` in the stage — and a hard guard that the
#      staged version now EQUALS <version> (a tag/file desync fails here,
#      BEFORE the upload, never mid-publish);
#   2. CHANGELOG.md in the stage — the tag's section is generated and
#      PREPENDED (the repo file keeps its curated `## Unreleased` window;
#      pub.dev's 262144-byte cap is enforced on the STAGED file, which is
#      trimmed of its oldest sections if needed — the repo file stays
#      lossless in git, the archive tail lives in CHANGELOG_ARCHIVE.md).
set -euo pipefail

stage="${1:?usage: stamp_staged_release.sh <stage-dir> <version>}"
version="${2:?usage: stamp_staged_release.sh <stage-dir> <version>}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pubspec="$stage/pubspec.yaml"
changelog="$stage/CHANGELOG.md"
[ -f "$pubspec" ] || { echo "::error::staged pubspec missing: $pubspec"; exit 1; }
[ -f "$changelog" ] || { echo "::error::staged CHANGELOG missing: $changelog"; exit 1; }

# ── 1. Stamp the version ────────────────────────────────────────────────────
sed -i "s/^version: .*/version: $version/" "$pubspec"

# Guard (gh-1522 AC: staged version MUST equal the tag name, v1.0.550 →
# 1.0.550) — the stamp above makes this self-evident, but the check is the
# invariant's tripwire: a future staging change that drops the pubspec
# version line, comments it, or carries a second version field fails LOUDLY
# here instead of shipping a 0.0.0-dev package to pub.dev.
stamped=$(grep '^version:' "$pubspec" | awk '{print $2}')
if [ "$stamped" != "$version" ]; then
  echo "::error::staged pubspec version '$stamped' != release tag version '$version' — refusing to publish (gh-1522 tag↔file invariant)"
  exit 1
fi
echo "staged pubspec stamped to $version"

# ── 2. Generate + prepend the tag's changelog section ──────────────────────
# Preference order (mirrors scripts/release_notes.sh, extended gh-1522):
#   a. a curated `## <version>` section already in the repo CHANGELOG.md;
#   b. the curated `## Unreleased` body, folded under `## <version>`
#      (the release "moves Unreleased into the tag's section AT STAGE
#      TIME — not in-repo", gh-1522 §2);
#   c. generated conventional-commit bullets since the previous tag
#      (release_notes.sh fallback, RELEASE_NOTES_MAX capped).
section="$(bash "$repo_root/scripts/release_notes.sh" "$version" 2>/dev/null || true)"
if [ -z "$section" ]; then
  echo "::error::could not generate a changelog section for v$version"
  exit 1
fi
# Drop leading blank lines (the awk section extraction carries the blank
# line right under the section header) so the staged section is tight.
section="$(printf '%s\n' "$section" | awk 'NF { p = 1 } p')"

printf '## %s\n\n%s\n\n' "$version" "$section" > "$changelog.new"
# Drop the staged `## Unreleased` header+body (it became the tag's section
# or stays in-repo curation for the NEXT release — the published artifact
# never shows an Unreleased section).
awk '
  BEGIN { skip = 0 }
  /^## Unreleased[ \t]*$/ { skip = 1; next }
  skip && /^## / { skip = 0 }
  skip { next }
  { print }
' "$changelog" >> "$changelog.new"
mv "$changelog.new" "$changelog"

# gh-1452: pub.dev server-rejects an upload whose CHANGELOG.md exceeds its
# hard 262144-byte content cap. The repo file is capped by
# scripts/check_changelog_size.sh at authoring time; the STAGED file gets
# the same cap enforced HERE (it just grew by a fresh section) — trim the
# oldest sections until it fits. The trimmed tail is not lost: the repo
# file (git) and CHANGELOG_ARCHIVE.md carry the full history.
bash "$repo_root/scripts/check_changelog_size.sh" "$changelog" || {
  echo "staged CHANGELOG over the pub.dev cap — trimming oldest staged sections"
  STAGED_CHANGELOG="$changelog" python3 - <<'PY'
import os
import re

path = os.environ["STAGED_CHANGELOG"]
cap = 262144
text = open(path, encoding="utf-8").read()
sections = re.split(r"(?=^## )", text, flags=re.M)
head, versions = sections[0], [s for s in sections[1:] if s.startswith("## ")]
# Always keep the newest section plus whatever fits under the cap.
kept = []
size = len(head.encode("utf-8"))
for s in reversed(versions):
    b = len(s.encode("utf-8"))
    if kept and size + b >= cap:
        break
    kept.append(s)
    size += b
open(path, "w", encoding="utf-8").write(head + "".join(reversed(kept)))
PY
  bash "$repo_root/scripts/check_changelog_size.sh" "$changelog"
}
echo "staged CHANGELOG stamped with the v$version section"
