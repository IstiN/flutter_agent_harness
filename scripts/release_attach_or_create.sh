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
# Ownership-stamped: the create path makes a DRAFT (gh-1801 rework: the
# release never goes live from a leg — the tag-run release-provenance job
# publishes + flags latest once the signed SHA256SUMS is attached). The
# body stamps
#   <!-- release-draft-owner: run/<run_id>/job/<job_id> -->
# and release_draft_guard.sh deletes that draft ONLY on an exact
# run+job match — never the sibling leg's mid-upload draft (daily-publish
# runs the mobile and macOS legs concurrently on the same derived tag).
# The marker is an invisible HTML comment in the body.
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
  # gh-1801 hard refusal: creating a release with zero resolved assets is
  # the `fa update` breaker (an empty `latest` 404s every
  # fa-<os>-<arch>.tar.gz until backfill — v1.0.630, 2026-10-23). Attaching
  # is the caller's only honest option when it resolved nothing — fail
  # loud here, never create empty. Pinned by
  # test/release_empty_latest_guard_test.dart.
  echo "::error::no assets to attach for $tag — refusing to create or touch a release with an empty asset list (gh-1801): resolve at least one artifact or skip the release step" >&2
  exit 1
fi

upload_all() { # exists-path: upload + (servable-only) publish + latest
  for asset in "${assets[@]}"; do
    gh release upload "$tag" "$asset" --clobber --repo "$repo"
  done
  # Latest policy (#282 + gh-1801 rework): publish + latest ONLY when the
  # release can actually serve `fa update` — that means the signed
  # checksums are already on it (`fa update` hard-fails without
  # SHA256SUMS(.sig), bin/self_manage.dart provenance gate). A release
  # carrying them but still draft means provenance ran and its own flip
  # failed — recover it here. Any other case stays draft/unflipped: the
  # tag-run release-provenance job (ci.yml) is the single owner of the
  # --draft=false --latest flip, and a red provenance must leave the
  # PREVIOUS release as latest instead of stranding a provenance-less one
  # (the v1.0.630 incident window).
  if release_serves_fa_update; then
    gh release edit "$tag" --draft=false --latest --repo "$repo"
  else
    echo "release $tag is not yet servable (no SHA256SUMS on it) — publish+latest left to the release-provenance step (gh-1801)"
  fi
}

# fa-update servability = the signed checksums are on the release. Every
# fa-* archive alone is NOT enough: `fa update` fetches SHA256SUMS(.sig)
# and aborts when either is missing (bin/self_manage.dart).
release_serves_fa_update() {
  local names
  names=$(gh release view "$tag" --repo "$repo" --json assets --jq '[.assets[].name]' 2>/dev/null || true)
  printf '%s\n' "$names" | grep -qE '^SHA256SUMS(\.sig)?$'
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
  # Fail fast BEFORE the cryptic crash: the push URL below collapses to ''
  # when GH_TOKEN is unset, and git's `fatal: bad repository ''` does not
  # point at the env gap (run 39766453580, v1.0.626 mobile leg). Callers
  # must export GH_TOKEN=RELEASE_PAT (or a job-scoped App token) — the
  # workflow GITHUB_TOKEN is not a substitute (GitHub suppresses events it
  # triggers, so the tag CI would never fire).
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "::error::tag $tag is missing but GH_TOKEN is not set — the annotated-tag push would run 'git push \"\"'. Set GH_TOKEN (PAT/App token) on the calling step, or the tag can never be minted here." >&2
    exit 1
  fi
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

# Bare vX.Y.Z title (#282): matches the tag, matches pub.dev. gh-1801
# rework: the create is DRAFT-ONLY. Whatever this leg resolved
# (AAB/IPA/store APKs, DMGs/zips) is not the signed provenance `fa update`
# demands — a leg that arrives first must never publish the release, let
# alone flag it latest (threads 2/6). The draft is ownership-stamped (the
# marker below) so this job's draft lifecycle guard reclaims it on
# failure; the tag-run binaries job attaches the CLI assets into it and
# release-provenance (ci.yml) publishes + flags latest once SHA256SUMS.sig
# is on board.
if gh release create "$tag" \
  --repo "$repo" \
  --title "$tag" \
  --draft \
  --notes-file "$notes" \
  "${assets[@]}"; then
  echo "✅ created draft release $tag with ${#assets[@]} asset(s) — publish is provenance-owned (gh-1801)"
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
