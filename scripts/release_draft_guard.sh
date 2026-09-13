#!/usr/bin/env bash
# Release draft lifecycle guard (issue #282): a run that creates a release
# draft must end with it published or deleted — never orphan it. `gh
# release create <tag> <assets...>` uploads the assets through a DRAFT
# first and publishes only after every upload succeeds; a step dying
# mid-upload (the v0.1.190 rot) leaves that draft behind forever.
#
# Usage: release_draft_guard.sh <tag>
#
# Called from workflow steps with `if: always() && job.status != 'success'`
# so it runs on failure AND cancellation. A published release or a missing
# release is a no-op; a draft for <tag> is deleted (its assets are
# unpublished by definition — published releases are the artifact store,
# issue #282 E2). The tag itself is never touched.
set -euo pipefail

tag="${1:?usage: release_draft_guard.sh <tag>}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

state=$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft 2>/dev/null || echo missing)
if [ "$state" = "true" ]; then
  gh release delete "$tag" --repo "$repo" --yes
  echo "::warning::release lifecycle guard: deleted draft $tag — the run failed after creating it; a draft must be published or deleted, never orphaned (issue #282)"
else
  echo "release lifecycle guard: $tag is ${state} (published or absent) — nothing to clean"
fi
