#!/usr/bin/env bash
# Auto-release (gh-1522): cut the annotated TAG + GitHub Release directly —
# the git tag is the single source of truth for versions and ZERO files are
# mutated in-repo. The retired flow (this script used to patch-bump
# pubspec.yaml / CHANGELOG.md / flutter_app/pubspec.{yaml,lock} and push a
# 'chore(release):' commit straight to protected main) landed a 4-file bot
# commit on main per release: noisy history, a direct-to-main bot push
# path, CHANGELOG growth toward the pub.dev 256 KiB cap (gh-1452), and
# pubspec.lock churn that invalidated flutter_app's --enforce-lockfile
# (gh-1265). Now:
#
#   latest tag + 1  →  `git tag -a v$next origin/main`  →  push the tag
#   →  `gh release create` with release_notes.sh notes.
#
# Runs in CI on every push to main / the 2h catch-up cron / manual dispatch
# (the `release` job in .github/workflows/ci.yml). The job authenticates via
# actions/create-github-app-token (RELEASE_APP_ID + RELEASE_APP_PRIVATE_KEY);
# the App token pushes the tag because GITHUB_TOKEN pushes never trigger the
# tag-scoped publish/binaries jobs (gh-1172). The App remains the ONLY
# bypass actor on the main ruleset but no longer needs to push to main at
# all — releases never touch the branch.
#
# The tag push fires the ci.yml `publish` job, which stamps the staged
# publish tree from the SAME tag (scripts/stage_publish_package.sh <dir>
# <version>) — the tag↔staged-version invariant is guarded there.
#
# Dry-run: RELEASE_DRY_RUN=1 (or "true") computes the tag that WOULD be
# cut, logs it, and stops before any push.
#
# Release notes: scripts/release_notes.sh — curated `## <version>` section,
# else the curated `## Unreleased` body (gh-1522 §2), else conventional
# commits since the previous tag.
set -euo pipefail

# Tag authorship names the App so releases are attributable in history
# (auditability contract, gh-1172).
git config user.name "fa-release-bot[bot]"
git config user.email "fa-release-bot[bot]@users.noreply.github.com"

dry_run=0
case "${RELEASE_DRY_RUN:-0}" in 1|true|yes) dry_run=1 ;; esac

# Coalescing guards: pub.dev rate-limits publishes (~12/day), so releases are
# capped at one per 2h; runs with nothing new since the last tag are skipped.
git fetch origin main --tags --quiet
last_tag=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
if [ -n "$last_tag" ]; then
  pending=$(git rev-list --count "$last_tag..origin/main")
  if [ "$pending" -eq 0 ]; then
    echo "Auto-release: nothing new since $last_tag, skipping."
    exit 0
  fi
  # The 2h window runs from the RELEASE, not from the commit the tag points
  # at: commits can sit pending on main for hours before the cron/dispatch
  # cuts the tag (the common catch-up path), and reading the commit date
  # would let extra releases through exactly when this guard (and the
  # pub.dev ~12/day rate limit) exists to stop them (PR #1526 thread 5).
  # Annotated tags carry a tagger date; a lightweight tag (never cut by
  # this script, but defensive) falls back to the commit date.
  tag_ts=$(git for-each-ref --format='%(taggerdate:unix)' "refs/tags/$last_tag")
  [ -n "$tag_ts" ] || tag_ts=$(git log -1 --format=%ct "$last_tag")
  tag_age=$(( $(date +%s) - tag_ts ))
  if [ "$tag_age" -lt 7200 ]; then
    echo "Auto-release: coalesced — $last_tag is ${tag_age}s old (<2h); $pending commit(s) pending. Next eligible push or the 2h cron will release them."
    exit 0
  fi
fi

# Tag-push race honesty: a tag that appeared mid-run makes `next` stale —
# the push rejects it (already exists) and the retry loop re-derives from
# the freshly fetched tags. Never blind-push over an existing tag.
for attempt in 1 2 3; do
  git fetch origin main --tags --quiet

  latest_tag=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
  if [ -z "$latest_tag" ]; then
    echo "::error::no vX.Y.Z tag found — refusing to invent a first version (cut v0.1.0 manually)." >&2
    exit 1
  fi
  current="${latest_tag#v}"
  IFS='.' read -r major minor patch <<< "$current"
  next="$major.$minor.$((patch + 1))"
  tag="v$next"
  echo "Auto-release: $latest_tag -> $tag (attempt $attempt)"

  # The tag pins origin/main as of THIS fetch — a main that advances during
  # the run is picked up by a later release, never by a retag.
  git tag -a "$tag" -m "Release $tag" origin/main

  if [ "$dry_run" -eq 1 ]; then
    echo "Auto-release DRY-RUN: would push tag $tag at $(git rev-parse --short origin/main) and create the GitHub Release."
    git tag -d "$tag" >/dev/null
    exit 0
  fi

  if git push origin "refs/tags/$tag"; then
    echo "Auto-release: pushed $tag — the tag-scoped publish/binaries jobs fire from it."
    # GitHub Release so the binaries job can attach assets to it. Notes come
    # from release_notes.sh (issue #282). Bare vX.Y.Z title, latest explicit.
    notes=$(bash "$(dirname "$0")/release_notes.sh" "$next") || notes="Release $tag"
    gh release create "$tag" \
      --title "$tag" \
      --notes "$notes" \
      --latest \
      --repo "$GITHUB_REPOSITORY" || true
    exit 0
  fi
  echo "Tag push raced (tag likely appeared mid-run), re-deriving..."
  git tag -d "$tag" >/dev/null 2>&1 || true
done

echo "Auto-release failed after 3 attempts"
exit 1
