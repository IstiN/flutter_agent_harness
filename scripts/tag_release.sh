#!/usr/bin/env bash
# Cut the annotated tag + GitHub Release for the release bump that just landed
# on main (see auto_release.sh). Runs on the 'chore(release):' push to main —
# the `release-tag` job in ci.yml. Idempotent: an existing tag is a no-op.
# The tag is pushed with the fa-release-bot App token (checkout token,
# gh-1172) because GITHUB_TOKEN pushes never trigger the tag-scoped
# binaries/publish jobs.
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
echo "Tagging $tag at $(git rev-parse --short HEAD)"
git tag -a "$tag" -m "Release $tag"
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
