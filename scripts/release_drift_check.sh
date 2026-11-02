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
# Exit codes (gh-2042 review: infra is NOT drift evidence):
#   0  clean — every fa-* asset matches the signed SHA256SUMS;
#   1  DRIFT — a verdict a human must see (the workflow pages from the
#      details file + auto re-requests release-provenance);
#   2  INFRA — the assets could not be downloaded (transport error after a
#      retry): red run, but NO drift page (the next scheduled run
#      re-checks; the remediation step only pages on a non-empty details
#      file, which an infra failure never writes).
#
# Usage: release_drift_check.sh <tag>
# Env: GITHUB_REPOSITORY, GH_TOKEN/GITHUB_TOKEN,
#      FA_DRIFT_LOCAL_DIR (tests only: verify a pre-populated directory
#      instead of downloading), FA_DRIFT_DETAILS (drift details file, the
#      remediation step pages from it; default drift-details.txt in the CWD),
#      FA_DRIFT_RETRY_SLEEP (seconds between download retries; default 2).
#
# GNU-bound (sha256sum -c, find -printf, comm): this check targets the
# ubuntu-latest workflow runner — it fails confusingly if run locally on
# macOS/BSD.
set -euo pipefail

tag="${1:?usage: release_drift_check.sh <tag>}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
details="${FA_DRIFT_DETAILS:-drift-details.txt}"

drift=()
report() { # report <line>: collects the drift finding + names it in the details file
  drift+=("$1")
  printf '%s\n' "$1" >> "$details"
}

# The details reset runs BEFORE any download (gh-2042 review): a check that
# dies mid-download must never leave stale checkout content behind for the
# remediation step to page as if it were today's drift.
rm -f "$details"

workdir="${FA_DRIFT_LOCAL_DIR:-$(mktemp -d)}"

# Download with a transient-blip guard (gh-2042 review): retry once on
# transport failures (502, rate limit, ...) and treat ONLY an explicit
# not-found / no-match verdict as a deterministic "absent" (rc 2). Any
# other failure after the retry is infra (rc 1).
gh_dl() { # gh_dl <pattern> → 0 downloaded, 2 deterministic absent, 1 infra
  local pattern="$1" attempt err rc
  for attempt in 1 2; do
    err=$(mktemp)
    rc=0
    gh release download "$tag" --repo "$repo" --dir "$workdir" --pattern "$pattern" 2>"$err" || rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f "$err"
      return 0
    fi
    if grep -Eqi 'not found|no assets match' "$err"; then
      rm -f "$err"
      return 2
    fi
    rm -f "$err"
    if [ "$attempt" -lt 2 ]; then
      sleep "${FA_DRIFT_RETRY_SLEEP:-2}"
    fi
  done
  return 1
}

if [ -z "${FA_DRIFT_LOCAL_DIR:-}" ]; then
  mkdir -p "$workdir"
  # The manifest and its signature ride their own pattern: `fa-*` does not
  # match them, and BOTH must be on the release for provenance to exist.
  fa_rc=0
  sha_rc=0
  gh_dl 'fa-*' || fa_rc=$?
  gh_dl 'SHA256SUMS*' || sha_rc=$?
  if [ "$fa_rc" -eq 1 ] || [ "$sha_rc" -eq 1 ]; then
    echo "::error::release drift check could not download the assets of $tag (transport error after retry) — an infra blip is NOT drift evidence: failing WITHOUT a drift page; the next scheduled run re-checks" >&2
    exit 2
  fi
fi

if [ ! -f "$workdir/SHA256SUMS" ]; then
  report "SHA256SUMS is NOT on release $tag — provenance can never be verified (SEC-07 #795 fail-closed class)"
else
  if [ ! -f "$workdir/SHA256SUMS.sig" ]; then
    report "SHA256SUMS.sig is NOT on release $tag — an unsigned manifest is not provenance"
  fi
  if ! (cd "$workdir" && sha256sum -c SHA256SUMS > "$workdir/sha-check.log" 2>&1); then
    reported=0
    while IFS= read -r line; do
      case "$line" in
        *FAILED*|*failed*)
          report "digest drift: $line"
          reported=1
          ;;
      esac
    done < "$workdir/sha-check.log"
    # gh-2042 review thread 9: a failed verification that named nothing is
    # still drift — never let a nonzero sha-check pass silently (e.g. a
    # tab-separated manifest sed-extracts cleanly, so the set-diff stays
    # quiet while sha256sum only prints "no properly formatted checksum
    # lines found").
    [ "$reported" -eq 1 ] || report "SHA256SUMS failed verification without a named FAILED line — manifest shape is suspect (see $workdir/sha-check.log)"
  fi
fi

# Set diff, both directions: the manifest must cover EXACTLY the fa-* set
# actually on the release. The names are read LINE-WISE (gh-2042 review):
# release asset names may contain spaces, and a word-split loop would
# report one bogus per-word "asset" instead of the whole name.
manifest_names=$(sed -n 's/^[0-9a-fA-F]\{64\}[[:space:]]\+\*\?//p' "$workdir/SHA256SUMS" 2>/dev/null || true)
local_names=$(find "$workdir" -maxdepth 1 -name 'fa-*' -type f -printf '%f\n' 2>/dev/null | sort)
unlisted=$(comm -23 <(printf '%s\n' "$local_names" | sort -u) <(printf '%s\n' "$manifest_names" | sort -u) | sed '/^$/d')
uncovered=$(comm -13 <(printf '%s\n' "$local_names" | sort -u) <(printf '%s\n' "$manifest_names" | sort -u) | sed '/^$/d')
while IFS= read -r name; do
  [ -n "$name" ] || continue
  report "stale manifest: fa asset $name is on the release but NOT in SHA256SUMS (attached after signing?)"
done <<< "$unlisted"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  report "missing asset: SHA256SUMS lists $name but the release no longer serves it (gh-1832 shape)"
done <<< "$uncovered"

if [ "${#drift[@]}" -gt 0 ]; then
  echo "drift-details file: $details" >&2
  for line in "${drift[@]}"; do
    echo "::error::release drift on $tag: $line (gh-2042 AC2 — the signed SHA256SUMS no longer matches the shipped assets; remediation: re-run release-provenance for the tag)" >&2
  done
  exit 1
fi

echo "✅ release drift check passed for $tag: every fa-* asset matches the signed SHA256SUMS ($(printf '%s\n' "$local_names" | grep -c . || true) assets)"
