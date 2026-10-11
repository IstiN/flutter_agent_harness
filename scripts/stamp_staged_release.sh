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
# `|| true`: a stage whose pubspec dropped the version line must reach the
# loud invariant message below, not die silently on grep's exit 1 under
# `set -e` (PR #1526 rework behavioral test).
stamped=$(grep '^version:' "$pubspec" | awk '{print $2}' || true)
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
#
# One python step does the whole staged edit: prepend the generated section
# under the file's `# Changelog` preamble (file order is newest-first — the
# stamp prepends), drop the staged `## Unreleased` header+body (it became
# the tag's section or stays in-repo curation for the NEXT release — the
# published artifact never shows an Unreleased section), and keep only what
# fits under pub.dev's cap, newest first — the fresh tag section always
# survives. The trimmed tail is not lost: the repo file (git) and
# CHANGELOG_ARCHIVE.md carry the full history.
section="$(bash "$repo_root/scripts/release_notes.sh" "$version" 2>/dev/null || true)"
if [ -z "$section" ]; then
  echo "::error::could not generate a changelog section for v$version"
  exit 1
fi
FA_SECTION="$section" FA_VERSION="$version" FA_CHANGELOG="$changelog" python3 - <<'PY'
import os
import re

cap = 262144
path = os.environ["FA_CHANGELOG"]
version = os.environ["FA_VERSION"]
section = os.environ["FA_SECTION"].strip("\n")

text = open(path, encoding="utf-8").read()
parts = re.split(r"(?=^## )", text, flags=re.M)
preamble = parts[0].rstrip("\n") + "\n"
versions = [
    s
    for s in parts[1:]
    if s.startswith("## ")
    and not re.match(r"^## Unreleased[ \t]*$", s.split("\n", 1)[0])
    # PR #1526 rework: the repo file may already carry a curated section
    # for THIS version (release_notes.sh prefers it) — never keep a
    # duplicate copy below the generated one.
    and not re.match(
        rf"^## {re.escape(version)}[ \t]*$", s.split("\n", 1)[0]
    )
]
# Blank lines around the header and between sections, matching the repo's
# hand-curated convention (PR #1526 rework thread 4) — raw markdown must
# not run sections together: preamble\n + \n## <version>\n\n<body>\n\n.
new = f"\n## {version}\n\n{section.strip()}\n\n"
size = len((preamble + new).encode("utf-8"))
kept = []
for s in versions:  # file order: newest first (the stamp prepends)
    b = len(s.encode("utf-8"))
    if kept and size + b >= cap:
        break
    kept.append(s)
    size += b
open(path, "w", encoding="utf-8").write(preamble + new + "".join(kept))
PY

# gh-1452: pub.dev server-rejects an upload whose CHANGELOG.md exceeds its
# hard 262144-byte content cap — the guard above already trims to fit, so a
# failure here means even the preamble + the single fresh section is over
# (pathological); a second pass keeping ONLY the fresh section is the last
# resort before the loud fail.
bash "$repo_root/scripts/check_changelog_size.sh" "$changelog" || {
  echo "staged CHANGELOG still over the pub.dev cap — keeping only the fresh section"
  FA_CHANGELOG="$changelog" python3 - <<'PY'
import os
import re

path = os.environ["FA_CHANGELOG"]
text = open(path, encoding="utf-8").read()
parts = re.split(r"(?=^## )", text, flags=re.M)
open(path, "w", encoding="utf-8").write(parts[0] + parts[1])
PY
  bash "$repo_root/scripts/check_changelog_size.sh" "$changelog"
}
echo "staged CHANGELOG stamped with the v$version section"
