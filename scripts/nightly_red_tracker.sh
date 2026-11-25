#!/usr/bin/env bash
# Copyright (c) 2026, the Flutter Agent Harness authors.
# Use of this source code is governed by a MIT license that can be found
# in the LICENSE file.
#
# nightly_red_tracker.sh — self-heal for the nightly-red tracker's close
# leg (issue #2362).
#
# On 2026-11-20 and 2026-11-21 the nightly auto-issue job closed the open
# nightly-red tracker with a "Green again — closing" comment (#1953) ~3h
# AFTER the run's PTY/CLI integration and Build ios legs had already
# failed (runs 44667132620 / 44860623417). Mechanism: the job runs under
# job-level `if: always()`, and a step-level `success()` sees only the
# job's own steps — never the `needs` failures — so the close fired on
# every scheduled night, red or green. The reopen that kept the tracker
# alive was a FLEET-side monitor sweep, not owned by this bot; when it
# missed 2/2 consecutive nights, the tracker stayed closed and nothing in
# the run noticed until a human reopened it ~20 min later.
#
# Invoked by nightly.yml right after the close leg, inside the same run:
#   - every run leg green → the close stands (ledger genuinely done);
#   - any leg red         → the tracker is re-opened back-to-back and the
#     OPEN state is verified with ONE bounded retry (AC1);
#   - retry exhausted     → a `reopen-failed` label + comment land so a
#     human/machine sees the failure without an SLA timer (AC2).
#
# Fixture self-test: scripts/nightly_red_tracker_selftest.sh
set -euo pipefail

usage() { echo "usage: $0 self-heal <issue-number>" >&2; exit 64; }

[ "${1:-}" = "self-heal" ] || usage
number="${2:-}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:?GITHUB_RUN_ID required}"
# AC1: re-check the issue state N seconds after each reopen (GH state
# propagation); the selftest sets 0.
verify_wait="${REOPEN_VERIFY_WAIT:-5}"

note() {
  echo "decision: $*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "decision: $*" >> "${GITHUB_STEP_SUMMARY}"
  fi
}

state() { gh issue view "$number" --repo "$repo" --json state --jq .state; }

if [ -z "$number" ]; then
  note "why-not self-heal — the close leg closed no tracker this run"
  exit 0
fi

# Same jobs-API shape the filer step uses, widened per the
# watchdog_trip_check.sh predicate precedent (#2362 review): a leg that
# timed out (budget breach) or was cancelled (infrastructure cut) is a
# red night exactly like a plain failure — the close must never stand on
# one (the pre-fix filter read those nights as green = the #2362 bug in
# a narrower shape).
failing=$(gh api "repos/$repo/actions/runs/${GITHUB_RUN_ID}/jobs?per_page=100" \
  --jq '[.jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled") | .name] | join(", ")')

if [ -z "$failing" ]; then
  note "close stands #$number — every run leg green, no reopen"
  exit 0
fi

attempt=0
while :; do
  if gh issue reopen "$number" --repo "$repo"; then
    sleep "$verify_wait"
    if [ "$(state)" = "OPEN" ]; then
      gh issue comment "$number" --repo "$repo" \
        --body "Auto-reopened after premature close — the run still has failing legs: ${failing}.
Run: ${run_url}"
      note "reopened #$number — premature close self-healed (failing: ${failing})"
      exit 0
    fi
  fi
  attempt=$((attempt + 1))
  [ "$attempt" -ge 2 ] && break
done

# AC2: loud exhaustion marker — observable without polling timers.
gh label create reopen-failed --force --repo "$repo" \
  --description "Nightly-red tracker stayed closed after the bot's reopen retry (#2362)"
gh issue comment "$number" --repo "$repo" \
  --body "reopen-failed: the nightly bot closed this tracker and its reopen retry did not take (still closed after 2 attempts).
Failing legs: ${failing}
Run: ${run_url} — manual reopen required."
gh issue edit "$number" --repo "$repo" --add-label reopen-failed
note "reopen-failed #$number — reopen retry exhausted (failing: ${failing})"
exit 1
