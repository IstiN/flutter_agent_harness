#!/usr/bin/env bash
# Lazy DRAFT create for the release train's asset-upload steps (gh-1801).
#
# The train workflows (ci.yml binaries/web-spa, build-macos.yml
# build-macos-cli/build-extension) need a release object to attach assets
# to, but the release must never go live from an upload step: `fa update`
# resolves the `latest` release and hard-fails without the SIGNED
# SHA256SUMS(.sig) (bin/self_manage.dart provenance gate), which only the
# tag-run release-provenance job can upload. This script creates the
# release as a DRAFT — nothing else:
#
#   - body = scripts/release_notes.sh output (curated `## <version>`
#     CHANGELOG section → curated `## Unreleased` → conventional commits;
#     the gh-1172 curated-notes contract), with a minimal fallback —
#     never `--generate-notes` (review threads 3/7);
#   - body carries `<!-- release-draft-owner: run/<run_id>/job/<job> -->`
#     so scripts/release_draft_guard.sh can reclaim the draft on failure
#     (review threads 4/8) — matrix legs override the identity via
#     RELEASE_DRAFT_IDENTITY (e.g. binaries-linux-x64) so a failed leg's
#     guard can never match a sibling's in-flight draft;
#   - the view→create race is tolerated (`|| true`): a sibling leg or the
#     attach path may create the release between our view and create —
#     the loser just uploads into the winner's release;
#   - it NEVER publishes and NEVER flags latest: the single publish point
#     of a tag train is release-provenance's "Upload provenance assets"
#     step (`gh release edit --draft=false --latest` after SHA256SUMS.sig
#     lands). A red provenance leaves the previous release as latest —
#     safe degradation, never a provenance-less latest (v1.0.630 window).
#
# Usage: release_lazy_draft.sh <tag>
# Env: GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_JOB (Actions defaults),
#      RELEASE_DRAFT_IDENTITY (optional leg-suffixed override),
#      GH_TOKEN/GITHUB_TOKEN.
set -euo pipefail

tag="${1:?usage: release_lazy_draft.sh <tag>}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
identity="${RELEASE_DRAFT_IDENTITY:-run/${GITHUB_RUN_ID:?GITHUB_RUN_ID must be set (GitHub Actions default env)}/job/${GITHUB_JOB:?GITHUB_JOB must be set (GitHub Actions default env)}}"

# The guard greps exactly this class — validate here so a malformed
# override fails loud instead of stamping a marker the guard could never
# match (a forever-orphaned draft).
printf '%s' "$identity" | grep -Eq '^run/[0-9]+/job/[A-Za-z0-9_-]+$' || {
  echo "::error::RELEASE_DRAFT_IDENTITY '$identity' does not match 'run/<id>/job/<name>' — the draft lifecycle guard could never reclaim such a draft" >&2
  exit 1
}

# Already created (by a sibling leg, the attach path, or a previous run)?
# Drafts and published releases both resolve here — upload-only is safe.
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  echo "release $tag already exists — lazy draft create skipped"
  exit 0
fi

# Body: curated notes (CHANGELOG section / Unreleased / conventional
# commits) plus the ownership marker the guard verifies before deleting.
# stderr is NOT swallowed: release_notes.sh's ::error gates (e.g. the
# duplicate-'## Unreleased' curation guard) must stay visible even when
# the minimal fallback below keeps the train moving.
notes_file="$(mktemp "${TMPDIR:-/tmp}/release-lazy-notes.XXXXXX")"
trap 'rm -f "$notes_file"' EXIT
if ! bash "$(dirname "$0")/release_notes.sh" "$tag" >"$notes_file" ||
  [ ! -s "$notes_file" ]; then
  printf 'Release %s — see the CHANGELOG.\n' "$tag" >"$notes_file"
fi
# gh-237: bound the body BEFORE stamping the owner marker — the cap
# truncates from the TAIL, so a pre-stamped marker is cut off and the
# created draft carries no ownership proof: release_draft_guard.sh
# resolves `<unmarked>` and refuses to reclaim it, the daily sweeper
# buckets it human (the legs run with GH_TOKEN=RELEASE_PAT) and keeps
# it, dedupe ignores it — a forever-orphaned draft (gh-282). Bounded
# body (≤ 120,000) + the marker stays under the 125,000-character
# release-body cap whose overshoot HTTP-422'd `gh release create` in
# run 44680647719 (v1.0.756) and left every attach gate on the tag
# dying with "release not found".
bash "$(dirname "$0")/release_notes_cap.sh" "$notes_file"

marker="<!-- release-draft-owner: $identity -->"
grep -qF "$marker" "$notes_file" || printf '\n%s\n' "$marker" >>"$notes_file"

# gh-2026: a `gh release create` for a MISSING ref REST-mints a
# lightweight API tag with NO push event — the v0.1.408 silent class
# (issue #597). The fast legs (build-macos.yml build-extension /
# build-macos-cli) can reach this create before the attach legs
# (release-macos / release-mobile): the silent mint wins the race, every
# attach leg then finds the tag existing and skips the CI-firing
# annotated push, no tag train ever runs, and the draft is stranded
# (swept a day later — the v1.0.663 / v1.0.665 shape). When the ref is
# DEFINITELY missing, mint it through the CI-firing annotated push and
# verify the train started BEFORE creating the draft (dispatch-time call
# sites export GH_TOKEN=RELEASE_PAT for exactly this; the ci.yml tag-run
# call sites always see the tag of their own push event and never enter
# the mint). An indeterminable verdict (no origin remote, rc 128 —
# sandboxed fixtures) falls through to the plain create path.
set +e
git ls-remote --exit-code origin "refs/tags/$tag" >/dev/null 2>&1
ls_remote_rc=$?
set -e
if [ "$ls_remote_rc" -eq 2 ]; then
  bash "$(dirname "$0")/release_tag_mint.sh" "$tag"
fi

# DRAFT-first (gh-1801): a create here must never publish — the resolved
# asset list at this point can never include the signed checksums. The
# race-lost create is tolerated (the winner owns the release), but a REAL
# create failure is not (gh-237): the body was already bounded above by
# release_notes_cap.sh, so a surviving failure is a genuine API error.
#
# gh-2432 (run 45643151796, v1.0.778): that single shot made every
# TRANSIENT GitHub API server error fatal. All three hosted binaries legs
# got `HTTP 500 (…/releases)` from the create within two minutes (the body
# was already bounded to 119,961 bytes — NOT the gh-237 422 cap), each
# leg's lone post-failure re-view ~0.5s later still saw nothing, and the
# train red'd: release-provenance (the sole publish point) was skipped and
# the staged draft rotted until the daily sweeper reclaimed it (the
# recurring sweep issue gh-2432). One 500'd attempt evidently CREATED the
# draft server-side — the self-hosted macOS legs resolved it minutes
# later — but nothing in-run ever re-checked. Retry TRANSIENT 5xx only,
# with the race re-view at every failure boundary (which heals the
# landed-500 shape with a single create); a deterministic 4xx cannot
# answer differently on attempt 2 and still fails loud after exactly one
# attempt (gh-237 contract). Knobs follow the repo's env-override
# convention (RELEASE_TRAIN_VERIFY_TRIES/SLEEP, FA_DRIFT_RETRY_SLEEP):
# RELEASE_LAZY_CREATE_TRIES (default 3) / RELEASE_LAZY_CREATE_SLEEP
# (default 2s).
create_rc=0
create_tries="${RELEASE_LAZY_CREATE_TRIES:-3}"
create_sleep="${RELEASE_LAZY_CREATE_SLEEP:-2}"
create_err="$(mktemp "${TMPDIR:-/tmp}/release-lazy-create.XXXXXX")"
trap 'rm -f "$notes_file" "$create_err"' EXIT
attempt=1
while :; do
  create_rc=0
  gh release create "$tag" \
    --repo "$repo" \
    --title "$tag" \
    --draft \
    --notes-file "$notes_file" 2>"$create_err" || create_rc=$?
  # gh's stderr must stay in the Actions log ("fix the create failure
  # above", gh-237) — the capture file is a CLASSIFIER, not a sink.
  [ -s "$create_err" ] && cat "$create_err" >&2
  if [ "$create_rc" -eq 0 ]; then
    break
  fi
  # gh-1801's `|| true` tolerated ONLY the view→create race — a sibling
  # leg creating the release between our view and create. gh-237 (run
  # 44680647719, v1.0.756): that swallow ALSO ate real create failures
  # (body-too-long 422), printed "✅ lazy draft ready", and failed every
  # attach gate with "release not found". Re-view at EVERY failure
  # boundary now: the release existing means we lost the race — or our
  # own 500'd-but-landed attempt materialized late (the v1.0.778 shape);
  # either way the caller uploads into the winner's release.
  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    echo "release create failed but $tag now exists — lost the view→create race, the winner owns the release"
    echo "✅ lazy draft ready for $tag (owner $identity) — publish is provenance-owned (gh-1801)"
    exit 0
  fi
  if [ "$attempt" -lt "$create_tries" ] \
    && grep -Eq 'HTTP 5[0-9][0-9]' "$create_err" 2>/dev/null; then
    echo "transient GitHub API error on the draft create (attempt $attempt of $create_tries) — retrying in ${create_sleep}s" >&2
    attempt=$((attempt + 1))
    sleep "$create_sleep"
    continue
  fi
  break
done
if [ "$create_rc" -eq 0 ]; then
  # gh-2372: the create SUCCEEDED, but a same-run sibling leg may have
  # created its own draft inside the view→create race window (GitHub
  # does not enforce one release per tag for drafts — the v1.0.760 /
  # v1.0.763 twin rot). The older (first-created) same-tag release must
  # win: self-delete OUR twin when we lost, so the caller attaches into
  # the winner and nothing rots for 24h until the sweeper. Best-effort.
  bash "$(dirname "$0")/release_draft_twin_dedupe.sh" "$tag"
  echo "✅ lazy draft ready for $tag (owner $identity) — publish is provenance-owned (gh-1801)"
  exit 0
fi
echo "::error::the draft create for $tag failed (rc $create_rc) and no concurrent release appeared — nothing to attach to; fix the create failure above (e.g. the release body exceeding the 125,000-character API cap, gh-237)" >&2
exit 1
