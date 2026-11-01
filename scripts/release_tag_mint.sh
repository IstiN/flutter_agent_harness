#!/usr/bin/env bash
# Mint a release tag as an ANNOTATED tag pushed with a CI-firing token, and
# verify the tag train actually started (gh-2026). Shared by the two
# draft-capable create paths:
#
#   - scripts/release_attach_or_create.sh (build-macos.yml release-macos,
#     build-mobile.yml release-mobile) — the tag was DEFINITELY missing at
#     attach time;
#   - scripts/release_lazy_draft.sh (build-macos.yml build-macos-cli /
#     build-extension) — a `gh release create` for a missing ref would
#     REST-mint a lightweight API tag with NO push event (the v0.1.408
#     silent class, issue #597): no tag train, a stranded draft.
#
# Why this exists — the v1.0.663 / v1.0.665 stale drafts (gh-2026): the
# release legs pushed the annotated tag through the GH_TOKEN URL, but
# actions/checkout had already persisted the JOB token in the repo-local
# git config as `http.<host>/.extraheader = AUTHORIZATION: basic …`. That
# header outranks the URL-embedded credentials on the wire, so GitHub saw
# a GITHUB_TOKEN push — and GitHub NEVER fires workflow runs for
# GITHUB_TOKEN pushes (gh-1172; docs/ci.md "its token triggers the
# tag-scoped jobs, which GITHUB_TOKEN pushes never do"). Both legs stayed
# green, no tag run ever existed on the refs, the provenance-owned publish
# (gh-1801) never ran, and the daily sweeper deleted the drafts a day
# later. Two guards close the class:
#
#   1. strip the persisted extraheader(s) before the push — the same
#      cleanup the Actions runner's post-job step performs ("Removing HTTP
#      extra header") — so the URL's PAT credentials are what GitHub sees
#      and the push fires ci.yml's `push: tags: ['v*']` train;
#   2. verify the outcome: poll for any workflow run on the tag ref within
#      a bounded budget. A push that triggers nothing fails this script
#      LOUD (no draft is created — the caller never reaches its create
#      step), so the leg goes red with a self-explaining error instead of
#      stranding a draft for the sweeper.
#
# Usage: release_tag_mint.sh <tag>
# Env: GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_JOB, GITHUB_SHA (Actions
#      defaults), GH_TOKEN — a PAT/App token, NEVER the workflow
#      GITHUB_TOKEN (a GITHUB_TOKEN push succeeds but can never trigger
#      the train; static lint pins every call site's export).
#      RELEASE_TARGET_SHA overrides the tag target (defaults GITHUB_SHA).
#      RELEASE_TRAIN_VERIFY_TRIES (default 12) ×
#      RELEASE_TRAIN_VERIFY_SLEEP seconds (default 10) bound the
#      verification; the test harness shrinks both.
set -euo pipefail

tag="${1:?usage: release_tag_mint.sh <tag>}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

# Fail fast BEFORE the cryptic crash: the push URL below collapses to ''
# when GH_TOKEN is unset, and git's `fatal: bad repository ''` does not
# point at the env gap (run 39766453580, v1.0.626 mobile leg).
if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error::tag $tag is missing but GH_TOKEN is not set — the annotated-tag push would run 'git push \"\"'. Set GH_TOKEN (PAT/App token) on the calling step, or the tag can never be minted here." >&2
  exit 1
fi

# Guard 1 — strip the persisted checkout credentials. actions/checkout
# (persist-credentials defaults true) leaves the job token as an
# `http.<host>/.extraheader` in the LOCAL git config; git sends that
# Authorization header on every request to the host, and it outranks the
# URL-embedded GH_TOKEN credentials — the minted push would authenticate
# as GITHUB_TOKEN and the train would never fire (gh-2026). Unset every
# extraheader key the same way the runner's post-job cleanup does.
while IFS= read -r extraheader_key; do
  [ -n "$extraheader_key" ] || continue
  git config --local --unset-all "$extraheader_key" || true
done < <(git config --local --name-only --get-regexp 'http\..*\.extraheader' 2>/dev/null || true)

target="${RELEASE_TARGET_SHA:-${GITHUB_SHA:?}}"
echo "tag $tag missing — minting annotated tag at $target (token-URL push, fires the tag train)"
git fetch origin "$target" --depth=1 2>/dev/null || git fetch origin main --depth=50
# CI checkout carries no identity; annotate as the actions bot without
# touching global config (empty ident → exit 128, run 35426119831).
git -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    tag -a "$tag" -m "Release $tag" "$target"
git push "${GH_TOKEN:+https://x-access-token:${GH_TOKEN}@github.com/${repo}.git}" "refs/tags/$tag"

# Guard 2 — the train must actually start. A push that fires no workflow
# run (a GITHUB_TOKEN-classed credential on the wire, a GitHub incident, a
# workflow-file mismatch at the tag commit) silently strands every draft
# attached to the tag: green legs, no publish, the sweeper cleans up a day
# later (v1.0.663 / v1.0.665). The run row for the push event appears
# within seconds; poll briefly and fail loud.
tries="${RELEASE_TRAIN_VERIFY_TRIES:-12}"
sleep_s="${RELEASE_TRAIN_VERIFY_SLEEP:-10}"
runs_seen=0
for _ in $(seq 1 "$tries"); do
  sleep "$sleep_s"
  if [ "$(gh run list --repo "$repo" --branch "$tag" --limit 10 \
    --json databaseId --jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
    runs_seen=1
    break
  fi
done
if [ "$runs_seen" -ne 1 ]; then
  echo "::error::tag train did not start for $tag: pushed refs/tags/$tag to ${repo} but no workflow run appeared on the ref within the verification budget — the push likely authenticated as a CI-suppressed token (GitHub never fires workflows for GITHUB_TOKEN pushes; the persisted actions/checkout extraheader must not outrank the GH_TOKEN push credentials), or the tag-trigger filter does not match. No draft was created; fix the push credential and re-run." >&2
  exit 1
fi
echo "✅ tag train for $tag started (workflow run visible on the ref) — the draft publish path is live"
