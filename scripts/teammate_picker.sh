#!/usr/bin/env bash
# gh-2359 AC2 — machine issue-picker guard: a fresh dev handoff must not
# pick an issue that already has an OPEN referencing PR — from ANY author.
#
# 2026-11-20 incident: the machine opened PR #2339 (branch ai/gh-2337) for
# the 125k release-body root while the owner's human PR #2340 for the same
# root was already open; the picker only knew its own in-flight work, so
# both fixes ran in parallel and #2340 closed superseded.
#
# Usage: teammate_picker.sh <issue-number>
# Prints the leg the loop should run: `dev` (pick it) or EMPTY (skip).
# Fail-closed: a PR-list lookup error skips the pick (a duplicate fix is
# worse than a delayed one; the next SM tick retries the handoff).
set -euo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
issue="${1:?usage: teammate_picker.sh <issue-number>}"
case "$issue" in '' | *[!0-9]*)
  echo "issue number must be numeric, got: $issue" >&2
  exit 2 ;;
esac

open_prs=$(gh pr list --repo "$repo" --state open --limit 100 \
  --json number,author,headRefName,body 2>/dev/null) || {
  echo "::warning::open-PR lookup failed — skipping the pick for issue #${issue} (gh-2359 AC2, fail-closed)"
  exit 0
}

# Linked = the body keyword the merge train already uses (Fixes/Closes/
# Resolves #n) or the machine branch convention ai/gh-<n>. Both authors
# count: the goal is that no second fix starts while one is visible.
linked=$(printf '%s' "$open_prs" | jq -r --arg n "$issue" '
  .[]
  | select(
      ((.body // "")
        | ascii_downcase
        | test("(fixes|closes|resolves)[[:space:]]*:?[[:space:]]*#"
          + ($n | tostring) + "([^0-9]|$)"))
      or ((.headRefName // "")
        | test("^ai[-/]gh-" + ($n | tostring) + "$"))
    )
  | "#\(.number) by \((.author // {}).login // "unknown")"')

if [ -n "$linked" ]; then
  echo "::notice title=fix-in-flight::issue #${issue} already has an open referencing PR (${linked//$'\n'/, }) — picker skips it (gh-2359 AC2)"
  exit 0
fi

echo "dev"
