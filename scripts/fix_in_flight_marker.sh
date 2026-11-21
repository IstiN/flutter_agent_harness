#!/usr/bin/env bash
# gh-2359 AC1 — fix-in-flight marker: when a fix PR opens, its linked
# issue is stamped visibly (label `fix-in-flight` + a comment naming the
# PR and branch); when the PR closes (merged or not), the marker clears.
#
# 2026-11-20 incident: the machine loop opened PR #2339 (ai/gh-2337) for
# the 125k release-body root with NO marker on #2337, and a human PR
# (#2340) for the same root landed in parallel — two fixes for one root.
#
# Called by .github/workflows/fix-in-flight.yml on pull_request
# opened/reopened/closed. Every input rides the environment (never
# interpolated into the script text — injection-safe). ANY author stamps
# the issue: the goal is that a second fix never starts while one is
# visible (the AC2 picker skip reads the same open-PR state).
#
# Linked issue = the machine branch convention `ai/gh-<n>` / `ai-gh-<n>`
# and/or the body keyword the merge train already links on
# (Fixes/Closes/Resolves #n).
set -euo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
pr="${PR_NUMBER:?PR_NUMBER must be set}"
action="${PR_ACTION:?PR_ACTION must be set}"
author="${PR_AUTHOR:-unknown}"
branch="${PR_BRANCH:-}"
body="${PR_BODY:-}"
merged="${PR_MERGED:-false}"
label="fix-in-flight"

# Linked issue numbers (deduped): branch convention + body keywords.
issues="$(
  {
    printf '%s\n' "$branch" | sed -n 's/^ai[-/]gh-\([0-9]\{1,\}\)$/\1/p' || true
    printf '%s' "$body" \
      | grep -ioE '(fixes|closes|resolves)[[:space:]]*:?[[:space:]]*#[0-9]+' \
      | grep -oE '[0-9]+' || true
  } | sort -un
)"

if [ -z "$issues" ]; then
  echo "PR #${pr} links no issue (no ai/gh-<n> branch, no Fixes/Closes/Resolves body keyword) — nothing to mark"
  exit 0
fi

# Idempotent self-heal (the daily_publish_report.sh label-create pattern):
# create is a no-op failure when the label already exists.
gh label create "$label" --repo "$repo" --color 1D76DB \
  --description "An open PR references this issue — fix in flight (gh-2359)" \
  >/dev/null 2>&1 || true

for n in $issues; do
  if [ "$action" = "closed" ]; then
    # AC1: clear on close/merge — best effort, the label may be absent
    # (the open event never ran, or a human removed it).
    gh issue edit "$n" --repo "$repo" --remove-label "$label" >/dev/null 2>&1 || true
    if [ "$merged" = "true" ]; then
      state="merged"
    else
      state="closed unmerged (superseded or abandoned — the issue is pickable again)"
    fi
    gh issue comment "$n" --repo "$repo" \
      --body "Fix PR #${pr} (\`${branch:-<no branch>}\`) by @${author} was ${state} — \`fix-in-flight\` cleared." >/dev/null
    echo "issue #${n}: fix-in-flight cleared (PR #${pr} ${state})"
  else
    gh issue edit "$n" --repo "$repo" --add-label "$label" >/dev/null
    gh issue comment "$n" --repo "$repo" \
      --body "Fix in flight: PR #${pr} (\`${branch:-<no branch>}\`) by @${author} references this issue — the machine picker will skip it until the PR closes (gh-2359 AC1/AC2)." >/dev/null
    echo "issue #${n}: fix-in-flight stamped (PR #${pr})"
  fi
done
