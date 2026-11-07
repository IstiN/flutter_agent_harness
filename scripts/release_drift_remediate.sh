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
# `// 0` (not `// ""`): jq encodes the empty STRING as `""` — with quotes —
# which would defeat the emptiness guard. 0 is never a real run id.
# gh-2042 review thread 8 (r2): the head SHA rides along because a job
# re-run executes with the workflow file AS IT EXISTED at the original
# run's commit — the guard probe below needs that commit.
run_info=$(gh run list --repo "$repo" --workflow ci.yml --branch "$tag" \
  --limit 30 --json databaseId,conclusion,headSha \
  --jq '[.[] | select(.conclusion != null)] | first | [.databaseId // 0, (.headSha // "")] | @tsv' 2>/dev/null || printf '0\t')
run_id=$(printf '%s' "$run_info" | cut -f1)
run_sha=$(printf '%s' "$run_info" | cut -f2)

# gh-2042 review thread 8 (r2) — the pre-guard rerun window:
# a "Sign release checksums" job re-run re-executes the ci.yml of the TAG'S
# OWN COMMIT. For a tag minted before the gh-2042 flip guard, that is the
# OLD unconditional `gh release edit --draft=false --latest` flip — re-flag
# that tag Latest and every `fa update` client "updates" DOWN onto it.
# Gate the re-request on the run's commit:
#   guard present               → rerun is safe (the guarded flip no-ops).
#   pre-guard + tag IS latest   → the legacy flip only re-asserts the badge
#                                 the tag already holds → safe.
#   pre-guard + tag NOT latest  → REFUSE: degrade to a human-paged
#                                 instruction instead of dragging the badge
#                                 backwards. Fail-closed on probe errors.
guard_present=0
if [ -n "${run_sha:-}" ]; then
  guard_present=$(gh api "repos/$repo/contents/.github/workflows/ci.yml?ref=$run_sha" \
    --jq '.content' 2>/dev/null | base64 -d 2>/dev/null | grep -c 'current_latest=' || true)
  guard_present=${guard_present:-0}
fi
if [ "$run_id" != "0" ] && [ -n "$run_id" ]; then
  job_id=$(gh api "repos/$repo/actions/runs/$run_id/jobs" --paginate \
    --jq '.jobs[] | select(.name == "Sign release checksums") | .id' 2>/dev/null | head -1 || true)
  if [ -n "${job_id:-}" ]; then
    preguard_note=""
    if [ "$guard_present" -lt 1 ]; then
      current_latest=$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null || true)
      if [ "${current_latest:-}" != "$tag" ]; then
        # The refused shape — the issue still pages, with the instruction.
        rerun_status="re-request REFUSED: the completed run of tag $tag (head $run_sha) predates the gh-2042 ci.yml flip guard and $tag is NOT the current latest release — re-running that job would execute the OLD unconditional '--draft=false --latest' flip and drag the Latest badge (and every fa update client) backwards onto $tag. Re-sign from a post-guard checkout instead: check out the tag, run the provenance/sign step with the guarded ci.yml (a rerun of THAT workflow file re-publishes without --latest), or attach the corrected SHA256SUMS manually through the gated attach path."
        job_id=""
      else
        preguard_note=" (pre-guard run at $run_sha; $tag is still the current Latest — the legacy unconditional flip only re-asserts the badge it already holds)"
      fi
    fi
    if [ -n "$job_id" ]; then
      if gh run rerun "$run_id" --repo "$repo" --job "$job_id" 2>/dev/null; then
        rerun_status="release-provenance re-requested: run $run_id, job $job_id (it re-hashes the current assets and re-signs — gh-2042 AC2/AC3)${preguard_note}"
      else
        rerun_status="re-request FAILED: gh run rerun $run_id --job $job_id was rejected — rerun the 'Sign release checksums' job manually"
      fi
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
  gh issue comment "$existing" --repo "$repo" --body-file "$body" >/dev/null \
    || { echo "::error::drift on $tag: could not comment the open drift issue #$existing — page the release owner manually" >&2; exit 1; }
  echo "✅ drift issue updated: #$existing (dedup — no duplicate filed)"
else
  gh label create release-drift --repo "$repo" --color D97706 --description "Published release assets drifted from the signed SHA256SUMS" >/dev/null 2>&1 || true
  gh issue create --repo "$repo" --title "$title" --label release-drift \
    --body-file "$body" >/dev/null \
    || { echo "::error::drift on $tag: could not file the drift issue — page the release owner manually" >&2; exit 1; }
  echo "✅ drift issue filed for $tag — paged (gh-2042 AC2: drift must not linger)"
fi
