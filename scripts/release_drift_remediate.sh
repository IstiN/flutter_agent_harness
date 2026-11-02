#!/usr/bin/env bash
# Release drift remediation (gh-2042, AC2): when the drift check finds a
# published release whose assets no longer match the signed SHA256SUMS, this
# step (a) auto re-requests the release-provenance job for the tag — the job
# re-hashes the CURRENT assets and re-signs the manifest, which is also the
# AC3 v1.0.680 remediation mechanism — and (b) pages a DEDUPLICATED issue so
# drift never lingers silently.
#
# The re-request targets the SIGN JOB (`gh run rerun --job`), never the
# whole tag run: a full rerun would rebuild + re-attach every asset, which
# the immutability gate (scripts/release_asset_gate.sh, gh-2042 AC1) now
# refuses on a published release — and a rebuild is not what remediation
# needs anyway (the shipped bytes are the truth; only the manifest is stale).
#
# Paging FIRST-CLASS: the issue is filed even when the re-request fails or
# the tag run cannot be found (deleted history, PR-only branch names) — the
# only total failure of this step is the issue filing itself failing.
#
# Issue dedup: exact title `[release-drift] SHA256SUMS drift on <tag>` —
# an open match gets a comment (a fresh data point), never a duplicate.
#
# Usage: release_drift_remediate.sh <tag> <drift-details-file>
# Env: GITHUB_REPOSITORY, GH_TOKEN/GITHUB_TOKEN.
set -euo pipefail

tag="${1:?usage: release_drift_remediate.sh <tag> <drift-details-file>}"
details_file="${2:?usage: release_drift_remediate.sh <tag> <drift-details-file>}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

details="(drift details unavailable)"
[ -f "$details_file" ] && details=$(cat "$details_file")

rerun_status="(re-request not possible: no completed workflow run found for tag $tag on ci.yml)"
run_id=$(gh run list --repo "$repo" --workflow ci.yml --branch "$tag" \
  --limit 30 --json databaseId,conclusion \
  --jq '[.[] | select(.conclusion != null)] | first | .databaseId // ""' 2>/dev/null || echo "")
if [ -n "$run_id" ]; then
  job_id=$(gh api "repos/$repo/actions/runs/$run_id/jobs" --paginate \
    --jq '.jobs[] | select(.name == "Sign release checksums") | .id' 2>/dev/null | head -1 || true)
  if [ -n "${job_id:-}" ]; then
    if gh run rerun "$run_id" --repo "$repo" --job "$job_id" 2>/dev/null; then
      rerun_status="release-provenance re-requested: run $run_id, job $job_id (it re-hashes the current assets and re-signs — gh-2042 AC2/AC3)"
    else
      rerun_status="re-request FAILED: gh run rerun $run_id --job $job_id was rejected — rerun the 'Sign release checksums' job manually"
    fi
  else
    rerun_status="re-request FAILED: no 'Sign release checksums' job on run $run_id — rerun release-provenance for the tag manually"
  fi
fi

title="[release-drift] SHA256SUMS drift on $tag"
body="$(mktemp "${TMPDIR:-/tmp}/release-drift-body.XXXXXX")"
trap 'rm -f "$body"' EXIT
{
  echo "## $title"
  echo
  echo "$details"
  echo
  echo "**Auto-remediation (gh-2042 AC2):** $rerun_status"
  echo
  echo "If the drift persists after the re-run, an attach path replaced fa-* assets on the published release again — find it and gate it (scripts/release_asset_gate.sh). Until the manifest matches the shipped bytes, \`fa update\` / install.sh provenance verification fails for this train."
} > "$body"

# Dedup: exact open-title match (the inject-failure verify pattern) →
# comment; otherwise create. Best-effort label so the issues are filterable.
existing=$(gh issue list --repo "$repo" --state open --limit 200 \
  --json number,title --jq '.[] | select(.title == $t) | .number' --arg t "$title" 2>/dev/null | head -1 || true)
if [ -n "$existing" ]; then
  gh issue comment "$existing" --repo "$repo" --body-file "$body" >/dev/null
  echo "✅ drift issue updated: #$existing (dedup — no duplicate filed)"
else
  gh label create release-drift --repo "$repo" --color D97706 --description "Published release assets drifted from the signed SHA256SUMS" >/dev/null 2>&1 || true
  gh issue create --repo "$repo" --title "$title" --label release-drift \
    --body-file "$body" >/dev/null
  echo "✅ drift issue filed for $tag — paged (gh-2042 AC2: drift must not linger)"
fi
