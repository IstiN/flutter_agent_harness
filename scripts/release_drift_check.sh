#!/usr/bin/env bash
# Release drift check (gh-2042, AC2): re-download every `fa-*` asset of a
# release and diff sha256 against the signed SHA256SUMS.
#
# The v1.0.680 incident: assets were re-attached to the published release
# ~2-3h AFTER the manifest was signed, so the manifest no longer described
# the shipped bytes and every `fa update` / install.sh provenance check on
# the train failed. This is the CI-side twin of bin/self_manage.dart's
# verifyReleaseProvenance — same manifest, same digest comparison — run
# after every release publish and on a schedule
# (.github/workflows/release-drift-watch.yml). Drift = red run + a details
# file the remediation step pages from + an auto re-request of
# release-provenance. Drift must page, not linger.
#
# Checks (any hit = drift, exit 1):
#   - SHA256SUMS / SHA256SUMS.sig present on the release (no signature = no
#     provenance at all — the SEC-07 #795 fail-closed class);
#   - every manifest entry's digest matches the downloaded bytes
#     (sha256sum -c);
#   - the manifest covers EXACTLY the release's fa-* set (an fa-* asset on
#     the release that the manifest does not list is a stale manifest — the
#     v1.0.680 `-mac.zip` shape; a manifest entry the release no longer
#     serves is a missing asset — the gh-1832 shape).
#
# Usage: release_drift_check.sh <tag>
# Env: GITHUB_REPOSITORY, GH_TOKEN/GITHUB_TOKEN,
#      FA_DRIFT_LOCAL_DIR (tests only: verify a pre-populated directory
#      instead of downloading), FA_DRIFT_DETAILS (drift details file, the
#      remediation step pages from it; default drift-details.txt in the CWD).
set -euo pipefail

tag="${1:?usage: release_drift_check.sh <tag>}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
details="${FA_DRIFT_DETAILS:-drift-details.txt}"

drift=()
report() { # report <line>: collects the drift finding + names it in the details file
  drift+=("$1")
  printf '%s\n' "$1" >> "$details"
}

workdir="${FA_DRIFT_LOCAL_DIR:-$(mktemp -d)}"
if [ -z "${FA_DRIFT_LOCAL_DIR:-}" ]; then
  mkdir -p "$workdir"
  # The manifest and its signature ride their own pattern: `fa-*` does not
  # match them, and BOTH must be on the release for provenance to exist.
  gh release download "$tag" --repo "$repo" --dir "$workdir" --pattern 'fa-*'
  gh release download "$tag" --repo "$repo" --dir "$workdir" --pattern 'SHA256SUMS*' || true
fi

rm -f "$details"

if [ ! -f "$workdir/SHA256SUMS" ]; then
  report "SHA256SUMS is NOT on release $tag — provenance can never be verified (SEC-07 #795 fail-closed class)"
else
  if [ ! -f "$workdir/SHA256SUMS.sig" ]; then
    report "SHA256SUMS.sig is NOT on release $tag — an unsigned manifest is not provenance"
  fi
  if ! (cd "$workdir" && sha256sum -c SHA256SUMS > "$workdir/sha-check.log" 2>&1); then
    while IFS= read -r line; do
      case "$line" in
        *FAILED*|*failed*)
          report "digest drift: $line"
          ;;
      esac
    done < "$workdir/sha-check.log"
  fi
fi

# Set diff, both directions: the manifest must cover EXACTLY the fa-* set
# actually on the release.
manifest_names=$(sed -n 's/^[0-9a-fA-F]\{64\}[[:space:]]\+\*\?//p' "$workdir/SHA256SUMS" 2>/dev/null || true)
local_names=$(find "$workdir" -maxdepth 1 -name 'fa-*' -type f -printf '%f\n' 2>/dev/null | sort)
unlisted=$(comm -23 <(printf '%s\n' "$local_names" | sort -u) <(printf '%s\n' "$manifest_names" | sort -u) | sed '/^$/d')
uncovered=$(comm -13 <(printf '%s\n' "$local_names" | sort -u) <(printf '%s\n' "$manifest_names" | sort -u) | sed '/^$/d')
for name in $unlisted; do
  report "stale manifest: fa asset $name is on the release but NOT in SHA256SUMS (attached after signing?)"
done
for name in $uncovered; do
  report "missing asset: SHA256SUMS lists $name but the release no longer serves it (gh-1832 shape)"
done

if [ "${#drift[@]}" -gt 0 ]; then
  echo "drift-details file: $details" >&2
  for line in "${drift[@]}"; do
    echo "::error::release drift on $tag: $line (gh-2042 AC2 — the signed SHA256SUMS no longer matches the shipped assets; remediation: re-run release-provenance for the tag)" >&2
  done
  exit 1
fi

echo "✅ release drift check passed for $tag: every fa-* asset matches the signed SHA256SUMS ($(printf '%s\n' "$local_names" | grep -c . || true) assets)"
