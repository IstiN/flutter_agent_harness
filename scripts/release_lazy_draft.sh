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
marker="<!-- release-draft-owner: $identity -->"
grep -qF "$marker" "$notes_file" || printf '\n%s\n' "$marker" >>"$notes_file"

# DRAFT-first (gh-1801): a create here must never publish — the resolved
# asset list at this point can never include the signed checksums. The
# race-lost create is tolerated (the winner owns the release).
gh release create "$tag" \
  --repo "$repo" \
  --title "$tag" \
  --draft \
  --notes-file "$notes_file" || true
echo "✅ lazy draft ready for $tag (owner $identity) — publish is provenance-owned (gh-1801)"
