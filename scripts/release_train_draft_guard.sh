#!/usr/bin/env bash
# Train-level draft lifecycle guard (issue #282, gh-2230): the ci.yml tag
# train is the PUBLISH OWNER of every staged draft (gh-1801 rework — the
# release-provenance job is the sole `--draft=false --latest` flip point),
# but the per-creating-job guards (scripts/release_draft_guard.sh) cover
# only their own job's failure. A train that dies UPSTREAM of the publish
# point (core tests -> quality-gate red -> binaries skipped ->
# release-provenance skipped) left the staged draft orphaned: the creating
# run's jobs all succeeded (their guards never fire), the failed train is
# superseded and never rerun, and verify_pubdev_release.sh heals the LATEST
# tag only — so the draft rotted exactly 24h until the daily sweeper
# deleted it and filed the recurring sweep issue (gh-2230, v1.0.728).
#
# Called from the ci.yml `train-draft-guard` job, which needs
# release-provenance and runs with `if: always()`: by the time this script
# runs, the publish point has settled (success, failure, or skip) and every
# in-train draft-creating job (binaries, web-spa, build-extension) has
# settled with it.
#
# Deletes (by release id, the tag itself is never touched — drafts may
# carry an empty tag_name, and the id-based API delete is what the sweeper
# uses) only drafts for THIS train's tag whose well-formed
# `release-draft-owner: run/<id>/job/<name>` marker names a COMPLETED run:
# a superseded failed train will never publish them, and draft assets are
# unpublished by definition (issue #282 E2 — published releases are the
# artifact store). Fail-safe keeps — the sweeper remains the backstop:
#   - a FAILED or CANCELLED publish point (rerunnable — the draft is the
#     rerun --failed recovery vessel, gh-1899 convention);
#   - drafts owned by a run that is still queued/in_progress (a concurrent
#     creator leg, e.g. build-macos.yml from the daily cli leg, may be
#     mid-upload — the train can fail faster than a sibling workflow
#     finishes attaching);
#   - unmarked drafts (no marker = no proof of pipeline ownership — E1,
#     gh-2008; a human draft is never deleted here);
#   - any owner-run status lookup failure (never delete blind).
#
# Env: GITHUB_REPOSITORY; needs `contents: write` (release delete) and
# `actions: read` (owner-run status probe — same grant model as the
# sweep-drafts job, review of #294).
set -euo pipefail

tag="${1:?usage: release_train_draft_guard.sh <tag>}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

# The publish point's settled result (exported by the workflow from
# needs.release-provenance.result). Deletion is only correct when the
# publish point is UNREACHABLE: `skipped` means its needs (binaries) failed
# or were skipped, and `gh run rerun --failed` never resurrects skipped
# jobs — nobody will ever publish this draft. A FAILED or CANCELLED
# provenance IS rerunnable, and the staged draft is then the rerun
# --failed recovery vessel (the gh-1899 convention in ci.yml's success-path
# dedupe step: "a red provenance keeps the draft as the rerun --failed
# recovery vessel") — keep it; the 24h sweeper reclaims it if the train is
# never recovered. Unset (wiring broken) keeps too: fail-safe, never
# delete blind — the sweeper backstops the kept drafts either way.
result="${PROVENANCE_RESULT:-}"
if [ "$result" != "skipped" ]; then
  echo "::warning::train draft guard: release-provenance ${result:-<result not exported>} — a rerunnable (non-skipped) publish failure keeps the staged draft as the rerun --failed recovery vessel (gh-1899 convention); the 24h sweeper reclaims it if the train is never recovered (issue #282)"
  exit 0
fi

# ── inventory: drafts for THIS train's tag ──────────────────────────────────
# gh api --paginate emits one JSON array per page; the jq stream filter
# flattens them (same shape as sweep_stale_drafts.sh). Ownership-marker
# parsing: a bare capture(...)? on a non-matching body yields an EMPTY
# stream, so the array wrapper keeps exactly one (possibly empty) value
# per draft row.
rows=$(gh api --paginate "repos/$repo/releases" | jq -r --arg tag "$tag" '
  [ .[] | select(.draft == true and (.tag_name // "") == $tag)
    | { id: (.id | tostring),
        run: ([ (.body // "")
                | capture("release-draft-owner: run/(?<run>[0-9]+)/")?
                | .run ]
              | .[0] // "") } ]
  | .[]
  | [ .id, .run ] | @tsv')

deleted=0
kept=0
while IFS=$'\t' read -r id marker_run; do
  [ -n "$id" ] || continue
  if [ -z "$marker_run" ]; then
    echo "::warning::train draft guard: draft $id for $tag carries no release-draft-owner marker — no proof of pipeline ownership (possibly a human draft, E1); leaving it to the 24h sweeper (issue #282)"
    kept=$((kept + 1))
    continue
  fi
  # Fail-safe lifecycle check: delete only when the owner run has
  # COMPLETED. A non-completed status — or any lookup failure (403 without
  # actions:read, API blip) — keeps the draft: never delete blind.
  # Explicit jq pipe (not gh's --jq): mirrors sweep_stale_drafts.sh, where
  # every JSON probe is filtered by a real jq stage.
  status=$(gh run view "$marker_run" --repo "$repo" --json status 2>/dev/null \
    | jq -r '.status // empty' 2>/dev/null || echo "")
  if [ "$status" != "completed" ]; then
    echo "::warning::train draft guard: draft $id for $tag is owned by run $marker_run (status: ${status:-<lookup failed>}) — the owner is not provably done; refusing to delete a possibly mid-upload draft. The 24h sweeper remains the backstop (issue #282)"
    kept=$((kept + 1))
    continue
  fi
  gh api -X DELETE "repos/$repo/releases/$id"
  echo "::warning::train draft guard: deleted draft $id for $tag (owner run $marker_run completed; this failed train is superseded and will never publish it — a rerun cannot resurrect skipped jobs). Draft assets are unpublished by definition; the git tag is untouched (issue #282, gh-2230)"
  deleted=$((deleted + 1))
done <<< "$rows"

echo "train draft guard: deleted=$deleted kept=$kept for $tag"
