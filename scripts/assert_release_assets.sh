#!/usr/bin/env bash
# gh-1832: release required-assets gate + post-publish smoke.
#
# The single source of truth for the required set is the file next to this
# script: scripts/release_required_assets.txt (scope rationale lives in its
# header). Three modes:
#
#   assert_release_assets.sh <tag>
#       PUBLISH GATE (ci.yml release-provenance, before the signed-checksum
#       upload and the --draft=false --latest flip): every required asset
#       name must already be attached to <tag>'s release (draft counts).
#       Anything missing → ::error:: + exit 1 → the release run goes red
#       and the release stays a draft (the previous release stays latest).
#       This is the rehearsal-proven guard for the v1.0.635 incident, where
#       the extension's producer (build-macos.yml build-extension, a daily
#       leg that derives "latest+1 at its own dispatch moment") attached
#       fa-extension.zip to an orphaned v1.0.636 draft while the tag train
#       published v1.0.635 without it — every leg green, nothing asserted
#       the published set.
#
#   assert_release_assets.sh --smoke <tag|latest>
#       POST-PUBLISH SMOKE: ranged-GET (1 byte) every required asset's
#       download URL; anything outside HTTP 200/206 fails. Base URL is
#       https://github.com unless FA_RELEASE_DOWNLOAD_BASE overrides it
#       (tests), repo comes from GITHUB_REPOSITORY.
#
#   assert_release_assets.sh --landing [page]
#       LANDING LINK-CHECK: extracts EVERY http(s) …/releases/(latest/)?
#       download/… URL from the landing page (default site/index.html) and
#       probes each the same way — the page's links can never silently rot
#       again (the owner-facing symptom of gh-1832 was exactly this 404).
#
# Env: GITHUB_REPOSITORY, GH_TOKEN (gate mode), FA_RELEASE_DOWNLOAD_BASE
# (smoke/landing override, tests only).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
required_file="$script_dir/release_required_assets.txt"
[ -s "$required_file" ] || {
  echo "::error::required-assets list $required_file is missing/empty — refusing to judge a release against an empty set" >&2
  exit 1
}
# The list, comments stripped, order kept.
required=()
while IFS= read -r line; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | tr -d '[:space:]')"
  [ -n "$line" ] && required+=("$line")
done < "$required_file"
[ "${#required[@]}" -gt 0 ] || {
  echo "::error::$required_file parsed to zero assets — fix the list" >&2
  exit 1
}

# One ranged GET; prints the HTTP code. 200/206 = served (206 = the
# Range: bytes=0-0 answer of a real CDN download, i.e. an actual
# 1-byte download probe, not a name check).
probe_url() {
  local url="$1" code
  code=$(curl -sS -L --range 0-0 -o /dev/null -w '%{http_code}' \
    --connect-timeout 15 --max-time 60 "$url" 2>/dev/null || echo 000)
  case "$code" in
    200|206) return 0 ;;
    *) echo "$code"; return 1 ;;
  esac
}

mode="${1:?usage: assert_release_assets.sh <tag> | --smoke <tag|latest> | --landing [page]}"

case "$mode" in
  --smoke)
    tag="${2:?usage: assert_release_assets.sh --smoke <tag|latest>}"
    repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
    base="${FA_RELEASE_DOWNLOAD_BASE:-https://github.com}"
    fail=0
    for asset in "${required[@]}"; do
      if [ "$tag" = "latest" ]; then
        url="$base/$repo/releases/latest/download/$asset"
      else
        url="$base/$repo/releases/download/$tag/$asset"
      fi
      if ! code="$(probe_url "$url")"; then
        echo "::error::release asset smoke FAILED: $url → HTTP $code (gh-1832: a required asset does not serve)" >&2
        fail=1
      else
        echo "✅ $url → HTTP $code"
      fi
    done
    [ "$fail" -eq 0 ] || exit 1
    echo "✅ required-assets smoke passed for $tag (${#required[@]} assets)"
    ;;

  --landing)
    page="${2:-site/index.html}"
    [ -f "$page" ] || {
      echo "::error::landing page $page not found — pass the path or run from the repo root" >&2
      exit 1
    }
    # URL stops at whitespace, quotes, angle/close parens, plus, comma —
    # the landing page embeds these links in hrefs and JSON FAQ text with
    # trailing punctuation.
    urls=$(grep -oE "https?://[^\"' <>()+,\t]+" "$page" \
      | grep -E '/releases/(latest/)?download/' | sort -u || true)
    [ -n "$urls" ] || {
      echo "::error::no /releases/ download links found in $page — the page shape changed; revisit the link-check contract (gh-1832)" >&2
      exit 1
    }
    count=0
    fail=0
    while IFS= read -r url; do
      count=$((count + 1))
      if ! code="$(probe_url "$url")"; then
        echo "::error::landing link FAILED: $url → HTTP $code (gh-1832: the landing page exposes a broken release download)" >&2
        fail=1
      else
        echo "✅ $url → HTTP $code"
      fi
    done <<< "$urls"
    [ "$fail" -eq 0 ] || exit 1
    echo "✅ landing link-check passed: $count release URL(s) in $page all serve"
    ;;

  *)
    tag="$mode"
    repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
    export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    [ -n "$GH_TOKEN" ] || {
      echo "::error::GH_TOKEN/GITHUB_TOKEN is not set — the gate cannot read the release's asset list" >&2
      exit 1
    }
    on_release=$(gh release view "$tag" --repo "$repo" --json assets \
      --jq '.assets[].name' 2>/dev/null || true)
    missing=()
    for asset in "${required[@]}"; do
      if ! printf '%s\n' "$on_release" | grep -qxF "$asset"; then
        missing+=("$asset")
      fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
      echo "::error::release $tag is missing ${#missing[@]} required asset(s): ${missing[*]} — BLOCKING the publish (gh-1832: a partial release must never go live; the release stays a draft and the previous release stays latest). Producers: fa-extension.zip ← build-macos.yml build-extension (daily cli leg), fa-linux-*/fa-windows-* ← ci.yml binaries, fa-web-spa.zip ← ci.yml web-spa, fa-macos-* ← ci.yml binaries. Re-run the missing producer against this tag, then re-tag/re-run the train." >&2
      exit 1
    fi
    echo "✅ release $tag carries all ${#required[@]} required assets — publish may proceed"
    ;;
esac
