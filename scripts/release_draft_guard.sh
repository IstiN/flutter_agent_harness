#!/usr/bin/env bash
# Release draft lifecycle guard (issue #282): a run that creates a release
# draft must end with it published or deleted — never orphan it. `gh
# release create <tag> <assets...>` uploads the assets through a DRAFT
# first and publishes only after every upload succeeds; a step dying
# mid-upload (the v0.1.190 rot) leaves that draft behind forever.
#
# Usage: release_draft_guard.sh <tag>
#
# OWNERSHIP-SCOPED DELETE (review of #294): the guard deletes ONLY the
# draft this very run+job created. daily-publish runs the macOS and
# mobile legs concurrently against the same derived tag; a failed leg's
# guard firing on the SIBLING leg's mid-upload draft would destroy a
# healthy concurrent release. Draft-capable creates
# (scripts/release_attach_or_create.sh) stamp the draft body with
#   <!-- release-draft-owner: run/<run_id>/job/<job_id> -->
# and the guard deletes only on an exact match against GITHUB_RUN_ID /
# GITHUB_JOB (both GitHub Actions default env). A foreign or unmarked
# draft is NEVER deleted here — the daily sweeper
# (scripts/sweep_stale_drafts.sh) reclaims genuinely orphaned drafts
# after 24h.
#
# Called from workflow steps with `if: always() && job.status != 'success'`
# so it runs on failure AND cancellation. A published release or a missing
# release is a no-op; a draft for <tag> is deleted (its assets are
# unpublished by definition — published releases are the artifact store,
# issue #282 E2). The tag itself is never touched.
set -euo pipefail

tag="${1:?usage: release_draft_guard.sh <tag>}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID must be set (GitHub Actions default env)}"
: "${GITHUB_JOB:?GITHUB_JOB must be set (GitHub Actions default env)}"
identity="run/$GITHUB_RUN_ID/job/$GITHUB_JOB"

state=$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft 2>/dev/null || echo missing)
if [ "$state" != "true" ]; then
  echo "release lifecycle guard: $tag is ${state} (published or absent) — nothing to clean"
  exit 0
fi

notes=$(gh release view "$tag" --repo "$repo" --json body --jq '.body // ""' 2>/dev/null || echo "")
owner=$(printf '%s' "$notes" \
  | grep -oE 'release-draft-owner: run/[0-9]+/job/[A-Za-z0-9_-]+' \
  | head -1 | sed 's/^release-draft-owner: //' || true)

if [ "$owner" != "$identity" ]; then
  echo "::warning::release lifecycle guard: draft $tag is owned by '${owner:-<unmarked>}' (we are $identity) — refusing to delete a draft this run+job did not create; a sibling leg may be mid-upload. The daily sweeper reclaims orphaned drafts after 24h (issue #282)."
  exit 0
fi

gh release delete "$tag" --repo "$repo" --yes
echo "::warning::release lifecycle guard: deleted own draft $tag — the run failed after creating it; a draft must be published or deleted, never orphaned (issue #282)"
