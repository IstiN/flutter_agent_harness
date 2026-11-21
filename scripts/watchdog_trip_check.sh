#!/usr/bin/env bash
# Copyright (c) 2026, the Flutter Agent Harness authors.
# Use of this source code is governed by a MIT license that can be found
# in the LICENSE file.
#
# watchdog_trip_check.sh — the gh-2290 timeout-kill trip decision for the
# `watchdog` job of .github/workflows/ci.yml (issue #194 point 4).
#
# The watchdog's remedy for a degraded-runner allocation is ONE retrigger
# with a fresh allocation (never `gh run rerun`). Tripping requires
# recognizing a job-level timeout KILL — and only that kill. The v1.0.745
# tag run 4424840840 hung a PTY shard (the pty2 blocking-waitpid wedge,
# `Attempt:N waiting for isolate _waitForExitCode to check in`), burned
# its 40-minute budget and was killed by `timeout-minutes`: GitHub landed
# that kill as job conclusion `cancelled` (NOT `failure` — jobs
# 134588877581/134566192421) with the mid-flight step `cancelled` and the
# trailing `if: always()` evidence steps `skipped`.
#
# gh-2358 added the SECOND kill shape: runner DEATH. The v1.0.759 tag run
# (44868070949, job 136736814346) lost its self-hosted runner `fa-m5-1`
# ~11 minutes into `flutter build ios (debug, unsigned)` ("The
# self-hosted runner lost communication with the server"). GitHub
# concluded the JOB `failure` but NOTHING ever reported again: the
# mid-flight step — and every trailing step — froze at conclusion `null`,
# so the `cancelled`-step-only signature was blind to it. The watchdog
# ran, found nothing, and the release train sat red (no GitHub release,
# `vpinned` marker stuck) until a manual full rerun. One trip decision,
# two kill shapes: the mid-flight cut is `cancelled` (GitHub concluded
# the cancel) or `null` (nothing ever concluded).
#
# The degraded-runner-kill signature, as one predicate over the jobs JSON:
#
#   job conclusion == "failure" OR "cancelled"      (both kill shapes land)
#   AND at least one step concluded "cancelled" OR "null"
#     (a step was cut mid-flight — the kill itself; `null` is the
#     frozen runner-death tail, gh-2358)
#   AND NO step concluded "failure"                  (a real test failure
#     ENDS with a failed step — in these shards the `if: always()`
#     evidence steps often trail it with `success` — so a genuine red
#     never trips; a fresh runner allocation cannot fix a defect. This
#     guard also covers death AFTER a real red: the failed step is
#     concluded, only the trailing steps freeze at `null`)
#
# A cancelled job with NO steps (never started — a run-level cancel
# reaching a queued job) is NOT a kill (`any()` over an empty steps
# array is false). Success/skipped never trip. A job whose conclusion
# is still null is in flight — the first select filters it out, so an
# in-progress leg can never fake the signature.
#
# Network-free by contract: the caller fetches the run's jobs document in
# ONE call (the jobs API embeds each job's steps array — `gh run view
# --json jobs`; `gh api .../runs/<id>/jobs` is fine unpaged, but
# `--paginate` concatenates page bodies and jq then reads only the first
# page — verified against a 69-job run) and hands the FILE here.
# Fixture-self-tested by scripts/watchdog_trip_selftest.sh (#1100
# pattern), wired into the static gate; the workflow wiring is pinned by
# test/ci_watchdog_tag_retrigger_guard_test.dart.
#
# Usage: watchdog_trip_check.sh [jobs-json-file] [output-file]
#   jobs-json-file  the jobs document; `-` or an empty arg reads stdin
#   output-file     default $GITHUB_OUTPUT when set (the trip=<bool> line
#                   lands there AND on stdout); without one, stdout only.
#                   Diagnostics never start with `trip=`, so the line is
#                   unambiguous in both sinks.
set -u

json_file="${1:--}"
out_file="${2:-${GITHUB_OUTPUT:-}}"

if [ "$json_file" = "-" ] || [ -z "$json_file" ]; then
  jobs_json="$(cat)"
else
  jobs_json="$(cat "$json_file")"
fi

# The degraded-runner-kill signature, as ONE shared jq filter (the count
# and the diagnostics below project over the same filter — a duplicated
# literal can drift silently, and the selftest pins only the trip=
# contract): failed-or-cancelled jobs with a mid-flight cut (>=1 step
# concluded `cancelled` OR frozen unconcluded `null`) and NO failed step.
filter='.jobs[]?
   | select(.conclusion == "failure" or .conclusion == "cancelled")
   | select(any(.steps[]?; .conclusion == "cancelled" or .conclusion == null))
   | select(all(.steps[]?; .conclusion != "failure"))'

matches="$(printf '%s' "$jobs_json" | jq -r "[$filter] | length")"

if [ -z "$matches" ] || ! [ "$matches" -eq "$matches" ] 2>/dev/null; then
  # A malformed projection must NEVER flip the trip (fail-safe: the
  # watchdog is an optimization — a broken pre-check degrades to no
  # retrigger, never to a spurious dispatch loop).
  echo "::warning::watchdog_trip_check: unparseable jobs JSON or jq failure — not tripping"
  matches=0
fi

trip=false
if [ "$matches" -gt 0 ]; then
  trip=true
fi

if [ "$trip" = "true" ]; then
  echo "::notice::watchdog_trip_check: $matches job(s) match the degraded-runner-kill signature (gh-2290/gh-2358):"
  printf '%s' "$jobs_json" | jq -r "[$filter]
    | (.[] | \"  \" + .name + \": \" + .conclusion
       + \" (mid-flight cut: \"
       + ([.steps[]? | select(.conclusion == \"cancelled\" or .conclusion == null) | .name] | join(\", \"))
       + \")\")
  "
else
  echo "watchdog_trip_check: no degraded-runner-kill signature — nothing to retrigger"
fi

if [ -n "$out_file" ]; then
  {
    printf 'trip=%s\n' "$trip"
  } >> "$out_file"
fi
echo "trip=$trip"
