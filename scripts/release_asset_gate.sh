#!/usr/bin/env bash
# Release asset immutability gate (gh-2042, AC1): the single attach path for
# `fa-*` assets onto a GitHub Release.
#
# The v1.0.680 incident: the daily build-macos train resolved a tag whose
# release was ALREADY PUBLISHED (the same-tag convergence race — the tag
# train published while the daily train's slow self-hosted legs were still
# building) and re-attached fresh fa-macos-arm64 assets ~2-3h AFTER the
# signed SHA256SUMS was attached. The manifest never re-ran, so every
# `fa update` / install.sh provenance check on the train failed for every
# macOS-arm64 user. A published release must be IMMUTABLE for `fa-*`
# assets: the signed manifest vouches for exactly the bytes that were on
# the release when release-provenance signed it.
#
# Verdicts (per call, all-or-nothing — a partial attach would still drift
# the manifest):
#   release missing        → allow (the caller lazy-drafts first; a raw
#                            upload to a missing release errors loudly)
#   release is a DRAFT     → attach everything --clobber (the gh-1801 flow,
#                            unchanged: publish stays provenance-owned)
#   release is PUBLISHED   → for every listed asset:
#                              - name already attached → immutable SKIP
#                                (the release-twin binaries re-run: same
#                                tag commit, asset already shipped)
#                              - name not attached, matches `fa-*` →
#                                REFUSE the whole call with a loud
#                                ::error:: (post-publish attach must
#                                target a DRAFT / next-version or re-run
#                                release-provenance for the tag)
#                              - name not attached, NOT fa-* → attach
#                                (store AAB/IPA/APK + DMG refreshers are
#                                deliberately not provenance-covered,
#                                see scripts/release_required_assets.txt)
#   anything undeterminable (API blip, unparseable verdict) → fail CLOSED
#
# SHA256SUMS(.sig) are NOT fa-* assets: release-provenance's raw
# `gh release upload` of the manifest is the sanctioned post-publish
# remediation (re-hash the current bytes, re-sign) and stays outside this
# gate by design (gh-2042 AC3).
#
# Usage: release_asset_gate.sh <tag> <asset> [<asset>...]
# Env: GITHUB_REPOSITORY, GH_TOKEN/GITHUB_TOKEN.
set -euo pipefail

tag="${1:?usage: release_asset_gate.sh <tag> <assets...>}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
shift
assets=("$@")
if [ "${#assets[@]}" -eq 0 ]; then
  echo "::error::release_asset_gate.sh called with zero assets for $tag — a caller bug: resolve at least one artifact or skip the release step" >&2
  exit 1
fi

err=$(mktemp)
trap 'rm -f "$err"' EXIT
state_json=$(gh release view "$tag" --repo "$repo" --json isDraft,assets 2>"$err") || {
  if grep -qi "not found" "$err"; then
    # Release absent: the attach path lazily creates the DRAFT first
    # (release_lazy_draft.sh / the create in release_attach_or_create.sh).
    # Attempt the upload — a still-missing release errors loudly in gh.
    for asset in "${assets[@]}"; do
      gh release upload "$tag" "$asset" --clobber --repo "$repo"
    done
    echo "✅ gate: release $tag absent — attached ${#assets[@]} asset(s) (draft-first flow)"
    exit 0
  fi
  echo "::error::cannot determine the release state of $tag ($(cat "$err")) — refusing to attach (gh-2042 fail-closed: an undeterminable verdict must never mutate a release)" >&2
  exit 1
}

if printf '%s' "$state_json" | jq -e '.isDraft == false' >/dev/null 2>&1; then
  # PUBLISHED — the immutability contract.
  attached=$(printf '%s' "$state_json" | jq -r '.assets[].name')
  refused=()
  skipped=()
  uploadable=()
  for asset in "${assets[@]}"; do
    name=$(basename "$asset")
    if printf '%s\n' "$attached" | grep -qxF "$name"; then
      skipped+=("$name")
    elif [[ "$name" == fa-* ]]; then
      refused+=("$name")
    else
      uploadable+=("$asset")
    fi
  done
  if [ "${#refused[@]}" -gt 0 ]; then
    echo "::error::release $tag is PUBLISHED — attaching unattached fa-* asset(s) [${refused[*]}] would invalidate its signed SHA256SUMS (gh-2042 AC1: a published release is immutable for fa-* assets). Remediate by re-running the release-provenance job for the tag (it re-hashes the current assets and re-signs), or target the next-version DRAFT instead." >&2
    exit 1
  fi
  for name in "${skipped[@]:-}"; do
    [ -n "$name" ] || continue
    echo "✅ gate: $name already on the published release $tag — immutable skip (gh-2042)"
  done
  for asset in "${uploadable[@]:-}"; do
    [ -n "$asset" ] || continue
    gh release upload "$tag" "$asset" --clobber --repo "$repo"
    echo "✅ gate: $(basename "$asset") attached to $tag (not provenance-covered)"
  done
  exit 0
fi

if printf '%s' "$state_json" | jq -e '.isDraft == true' >/dev/null 2>&1; then
  # DRAFT — the normal pre-publish attach (unchanged since gh-1801).
  for asset in "${assets[@]}"; do
    gh release upload "$tag" "$asset" --clobber --repo "$repo"
  done
  echo "✅ gate: ${#assets[@]} asset(s) attached to draft $tag — publish stays provenance-owned"
  exit 0
fi

echo "::error::unparseable release state for $tag — refusing to attach (gh-2042 fail-closed)" >&2
exit 1
