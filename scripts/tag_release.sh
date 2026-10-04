#!/usr/bin/env bash
# Cut the annotated tag + GitHub Release for the release bump that just landed
# on main (see auto_release.sh). Runs on the 'chore(release):' push to main —
# the `release-tag` job in ci.yml. Idempotent: an existing tag is a no-op.
# The tag is pushed with the fa-release-bot App token (checkout token,
# gh-1172) because GITHUB_TOKEN pushes never trigger the tag-scoped
# binaries/publish jobs.
#
# gh-1192 AC3 — the tag pins the BUMP COMMIT, not moving main: the job's
# checkout can land on a main that advanced in the seconds between the bump
# push and this job starting (v1.0.498 captured the #1178 interloper that
# way), so BUMP_SHA — the push event's frozen head_commit.id — is passed by
# the workflow and validated (exact 'chore(release): v<ver>' subject + matching
# pubspec version) before use. A drifted/absent BUMP_SHA falls back to a
# history search for the bump commit; if neither resolves, the script REFUSES
# to tag rather than tag whatever HEAD points at.
set -euo pipefail

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git fetch origin main --tags --quiet
version=$(sed -n 's/^version: //p' pubspec.yaml)
tag="v$version"
if git rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null 2>&1; then
  echo "Tag $tag already exists — nothing to do."
  exit 0
fi

# ── Resolve the bump commit (gh-1192 AC3) ──────────────────────────────────
# A candidate qualifies only when its subject is exactly the bump subject AND
# its tree carries the tagged version — the two facts auto_release.sh authors
# into every bump commit. A drifted BUMP_SHA (github.sha can resolve to a
# newer main head) fails those checks and the history search decides instead.
resolve_bump() { # $1 = candidate sha; echoes the validated sha or nothing
  local candidate="$1" subject tree_version
  git cat-file -e "$candidate^{commit}" 2>/dev/null || return 1
  subject=$(git log -1 --format=%s "$candidate")
  tree_version=$(git show "$candidate":pubspec.yaml | sed -n 's/^version: //p')
  if [ "$subject" = "chore(release): v$version" ] && [ "$tree_version" = "$version" ]; then
    echo "$candidate"
  fi
}

bump_sha=""
if [ -n "${BUMP_SHA:-}" ]; then
  bump_sha=$(resolve_bump "$BUMP_SHA" || true)
  if [ -z "$bump_sha" ]; then
    subject=$(git log -1 --format=%s "$BUMP_SHA" 2>/dev/null || echo "<unresolvable>")
    echo "::warning::BUMP_SHA $BUMP_SHA is not the v$version bump (subject: $subject) — falling back to the history search"
  fi
fi
if [ -z "$bump_sha" ]; then
  # Subject-only scan — --grep would also match commit BODIES (a bump revert
  # quotes the old subject), and the newest body match must never shadow the
  # real bump. resolve_bump still validates the winner.
  while read -r candidate subject; do
    [ -n "$candidate" ] || continue
    bump_sha=$(resolve_bump "$candidate" || true)
    [ -z "$bump_sha" ] || break
  done < <(git log --format='%H %s' origin/main | awk '$2 == "chore(release):"')
fi
if [ -z "$bump_sha" ]; then
  echo "::error::cannot resolve the v$version bump commit (no valid BUMP_SHA, no 'chore(release): v$version' commit on origin/main) — refusing to tag a moving HEAD (gh-1192 AC3)"
  exit 1
fi

echo "Tagging $tag at $(git rev-parse --short "$bump_sha") (bump commit pinned — gh-1192 AC3)"
# Detach onto the bump so everything below (release notes) reads the tree
# that actually ships, even when the checkout had drifted.
git checkout -q --detach "$bump_sha"
git tag -a "$tag" -m "Release $tag" "$bump_sha"
git push origin "$tag"

# GitHub Release so the binaries job can attach assets to it. Notes come from
# the CHANGELOG section written by the bump (issue #282). Bare vX.Y.Z title,
# latest explicit (drafts never carry the badge).
notes=$(bash "$(dirname "$0")/release_notes.sh" "$version") || notes="Release $tag"
gh release create "$tag" \
  --title "$tag" \
  --notes "$notes" \
  --latest \
  --repo "$GITHUB_REPOSITORY" || true
