#!/usr/bin/env bash
# Attach assets to <tag>'s release, creating it when missing — the single
# draft-capable create path for build-macos.yml / build-mobile.yml
# (issue #282 E3 + review of #294).
#
# Race-idempotent (E3): if `gh release create` loses the view→create race
# (another job/run created the release in between), fall back to
# uploading into the winner's release instead of failing. A failed create
# would fire the job's draft lifecycle guard against the WINNER's
# in-flight draft.
#
# Ownership-stamped: `gh release create <tag> <assets...>` uploads the
# assets through a DRAFT first and publishes only after every upload
# succeeds, so the create stamps the body with
#   <!-- release-draft-owner: run/<run_id>/job/<job_id> -->
# and release_draft_guard.sh deletes that draft ONLY on an exact
# run+job match — never the sibling leg's mid-upload draft (daily-publish
# runs the mobile and macOS legs concurrently on the same derived tag).
# The marker is an invisible HTML comment in the published body.
#
# Usage: release_attach_or_create.sh <tag> <asset> [<asset>...]
#   reads the release body from release-notes.md in the CWD (a minimal
#   body is written when the file is missing/empty)
# Env: GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_JOB (Actions defaults),
#      GH_TOKEN/GITHUB_TOKEN.
set -euo pipefail

tag="${1:?usage: release_attach_or_create.sh <tag> <assets...>}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
shift
assets=("$@")
if [ "${#assets[@]}" -eq 0 ]; then
  echo "::error::no assets to attach for $tag" >&2
  exit 1
fi

upload_all() { # exists-path: upload + re-assert the Latest badge (#282)
  for asset in "${assets[@]}"; do
    gh release upload "$tag" "$asset" --clobber --repo "$repo"
  done
  # Latest policy (#282): the newest published release carries the badge
  # explicitly — even when this call lost the create race.
  gh release edit "$tag" --latest --repo "$repo"
}

if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  upload_all
  echo "✅ attached ${#assets[@]} asset(s) to existing release $tag"
  exit 0
fi

# Body: prepared notes (CHANGELOG section / conventional-commit fallback)
# plus the ownership marker the guard verifies before deleting.
notes="release-notes.md"
marker="<!-- release-draft-owner: run/${GITHUB_RUN_ID:?GITHUB_RUN_ID must be set (GitHub Actions default env)}/job/${GITHUB_JOB:?GITHUB_JOB must be set (GitHub Actions default env)} -->"
[ -s "$notes" ] || printf 'Release %s — see the CHANGELOG.\n' "$tag" > "$notes"
grep -qF "$marker" "$notes" || printf '\n%s\n' "$marker" >> "$notes"

# A `gh release create` for a MISSING tag mints a lightweight API tag:
# no push event → no ci.yml tag run → no publish/binaries (the v0.1.408
# silent class, issue #597). If the ref is absent, create it as an
# ANNOTATED tag and push it with the PAT the job already carries
# (GH_TOKEN=RELEASE_PAT in build-macos) so the tag CI fires. A push with
# the workflow's default github.token would be equally dead — GitHub
# suppresses events triggered by GITHUB_TOKEN.
# Gate on the DEFINITE missing verdict (ls-remote --exit-code rc 2):
# sandboxes without an origin remote fatal with 128 — indeterminable
# falls through to the plain create path (test fixtures rely on it).
set +e
git ls-remote --exit-code origin "refs/tags/$tag" >/dev/null 2>&1
ls_remote_rc=$?
set -e
if [ "$ls_remote_rc" -eq 2 ]; then
  target="${RELEASE_TARGET_SHA:-${GITHUB_SHA:?}}"
  echo "tag $tag missing — creating annotated tag at $target (PAT push, fires tag CI)"
  git fetch origin "$target" --depth=1 2>/dev/null || git fetch origin main --depth=50
  # CI checkout carries no identity; annotate as the actions bot without
  # touching global config (empty ident → exit 128, run 35426119831).
  git -c user.name="github-actions[bot]" \
      -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
      tag -a "$tag" -m "Release $tag" "$target"
  git push "${GH_TOKEN:+https://x-access-token:${GH_TOKEN}@github.com/${repo}.git}" "refs/tags/$tag"
fi

# Bare vX.Y.Z title (#282): matches the tag, matches pub.dev. Assets ride
# the create command — gh uploads them through a draft first, so the job's
# draft lifecycle guard owns the failure path.
if gh release create "$tag" \
  --repo "$repo" \
  --title "$tag" \
  --notes-file "$notes" \
  --latest \
  "${assets[@]}"; then
  echo "✅ created release $tag with ${#assets[@]} asset(s)"
  exit 0
fi

# E3 idempotency: the create may have lost the view→create race — the
# winner's release now exists. Attach instead of failing (a failing
# create would fire the guard against the winner's in-flight draft).
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  upload_all
  echo "✅ lost the create race — attached ${#assets[@]} asset(s) to the concurrently created release $tag"
  exit 0
fi

echo "::error::release create for $tag failed and no concurrent release appeared — see the step log above" >&2
exit 1
