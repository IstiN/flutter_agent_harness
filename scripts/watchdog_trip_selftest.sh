#!/usr/bin/env bash
# Copyright (c) 2026, the Flutter Agent Harness authors.
# Use of this source code is governed by a MIT license that can be found
# in the LICENSE file.
#
# watchdog_trip_selftest.sh — fixture self-test for the gh-2290 watchdog
# trip decision (scripts/watchdog_trip_check.sh, the `watchdog` job in
# ci.yml).
#
# The v1.0.745 tag run (4424840840) hung a PTY shard on the pty2
# blocking-waitpid wedge (`Attempt:N waiting for isolate _waitForExitCode
# to check in`), burned its whole 40-minute budget, was concluded
# `cancelled` — and NOTHING retrigged: the watchdog was pull_request-only
# AND its detector scanned failure-conclusion jobs only. The decision must
# trip exactly on the timeout-kill signature and never on a genuine red.
# Proves, on fixture JSON (no network, no gh, no token):
#   AC1  the gh-2290 kill mode: job conclusion `cancelled`, the
#     mid-flight step `cancelled`, trailing `if: always()` evidence
#     steps `skipped` — the EXACT shape of hung shard jobs
#     134588877581/134566192421 → trip,
#   AC2  the classic kill mode: job `failure`, a cut `cancelled` step,
#     no failed step → trip,
#   AC3  the gh-2358 runner-death kill mode: the box (fa-m5-1, v1.0.759
#     tag run 44868070949, job 136736814346) lost communication ~11 min
#     into `flutter build ios (debug, unsigned)`; the JOB concluded
#     `failure` and the mid-flight step — with every trailing step —
#     froze at conclusion `null` (never reported). One trip decision,
#     two kill shapes: the mid-flight cut is `cancelled` (GitHub
#     concluded the cancel) or `null` (nothing ever concluded).
#   FC1  a REAL test failure never trips — in either landing shape: the
#     failed step LAST, or the failed step TRAILED by the `if: always()`
#     evidence steps (`success`) that every red pty shard actually
#     leaves behind (last-step-success — the old last-step detector was
#     blind to this too),
#   FC2  success / skipped / a cancelled never-started job (no steps) /
#     an empty jobs array never trip,
#   FC3  a malformed body fails SAFE to trip=false with a warning (a
#     broken pre-check must degrade to no retrigger, never to a
#     spurious dispatch loop),
#   FC4  the runner died AFTER a real test failure — the red step
#     concluded `failure` and only the trailing steps froze at `null`:
#     a genuine red must never trip, regardless of the frozen tail.
#   RG   the output contract: exactly ONE `trip=<bool>` line, no
#     diagnostic masquerading as `trip=`, GITHUB_OUTPUT lands exactly
#     one line, multiple matches still produce a single line, and the
#     stdin arm (`-`) works.
# Same discipline as release_dedupe_selftest.sh (gh-1625, #1100 pattern).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/watchdog_trip_check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # check <desc> <condition-exit-code: 0 = pass>
  if [ "$2" = "0" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1"
    fails=$((fails + 1))
  fi
}

fixture() { # fixture <name> <json> — write a fixture, run the check
  _fx_name="$1"; shift
  printf '%s' "$1" > "$TMP/$_fx_name.json"
  bash "$CHECK" "$TMP/$_fx_name.json" 2>&1
}

trip_line() { # trip_line <output> — the trip= line, empty when absent
  printf '%s\n' "$1" | grep -E '^trip=(true|false)$' | head -1
}

trip_count() { # trip_count <output> — number of trip= lines
  printf '%s\n' "$1" | grep -cE '^trip=(true|false)$'
}

json_for() { # json_for <conclusion> <shape: kill|failure|success>
  # kill:    the REAL gh-2290 shape — the mid-flight dart test step
  #          cancelled, the trailing if:always() evidence steps skipped.
  # death:   the REAL gh-2358 runner-death shape — the mid-flight
  #          flutter build ios step and everything after it froze at
  #          conclusion null (the runner never reported anything again).
  # failure: a real test failure — the dart test step FAILED, the
  #          evidence steps still trail with success (the last step is
  #          NOT the failed one in these shards).
  # success: a clean job.
  case "$2" in
    kill)    steps='[{"name": "dart test", "conclusion": "cancelled"}, {"name": "junit durations", "conclusion": "skipped"}, {"name": "upload artifact", "conclusion": "skipped"}, {"name": "Post cache", "conclusion": "skipped"}]' ;;
    death)   steps='[{"name": "flutter build ios (debug, unsigned)", "conclusion": null}, {"name": "Post Run ./.github/actions/flutter-pub-get", "conclusion": null}, {"name": "Post Cache CocoaPods (iOS)", "conclusion": null}]' ;;
    failure) steps='[{"name": "dart test", "conclusion": "failure"}, {"name": "junit durations", "conclusion": "success"}]' ;;
    *)       steps='[{"name": "run", "conclusion": "success"}]' ;;
  esac
  cat <<JEOF
{"jobs": [{"name": "PTY/CLI integration (linux, shard 2/3)", "conclusion": "$1", "steps": $steps}]}
JEOF
}

echo "watchdog_trip_selftest (gh-2290):"

# AC1 — the gh-2290 kill mode (the REAL shape: conclusion cancelled,
# mid-flight step cancelled, trailing always()-evidence steps skipped).
out="$(fixture ac1 "$(json_for cancelled kill)")"
[ "$(trip_line "$out")" = "trip=true" ]
check "AC1 cancelled job with a cancelled step trips (gh-2290 kill mode)" $?

# AC2 — the classic kill mode (failure conclusion, cut step, no failed step).
out="$(fixture ac2 "$(json_for failure kill)")"
[ "$(trip_line "$out")" = "trip=true" ]
check "AC2 failure job with a cancelled step and no failed step trips" $?

# AC3 — the gh-2358 runner-death kill mode (the REAL shape: fa-m5-1
# lost communication ~11 min into the flutter build ios step of tag
# run 44868070949, job 136736814346; the JOB concluded failure and the
# mid-flight step — with every trailing step — froze at null).
out="$(fixture ac3 "$(json_for failure death)")"
[ "$(trip_line "$out")" = "trip=true" ]
check "AC3 failure job with an UNCONCLUDED (null) mid-flight step trips (gh-2358 runner death)" $?

# AC3b — the same runner death under the cancelled conclusion (a
# run-level cancel racing the lost heartbeat): still a mid-flight cut,
# still no failed step.
out="$(fixture ac3b "$(json_for cancelled death)")"
[ "$(trip_line "$out")" = "trip=true" ]
check "AC3b cancelled job with an unconcluded (null) mid-flight step trips" $?

# FC1 — a real test failure must NOT retrigger (both landing shapes).
out="$(fixture fc1a '{"jobs": [{"name": "Core tests (shard 0/4)", "conclusion": "failure", "steps": [{"name": "dart test", "conclusion": "failure"}, {"name": "junit", "conclusion": "success"}]}]}')"
[ "$(trip_line "$out")" = "trip=false" ]
check "FC1a real test failure (failed step, trailing evidence) does NOT trip" $?

out="$(fixture fc1b '{"jobs": [{"name": "Core tests (shard 3/4)", "conclusion": "failure", "steps": [{"name": "setup", "conclusion": "success"}, {"name": "dart test", "conclusion": "failure"}]}]}')"
[ "$(trip_line "$out")" = "trip=false" ]
check "FC1b real test failure (failed LAST step) does NOT trip" $?

# FC4 — the runner died AFTER a real test failure: the red step
# concluded `failure`, then the box vanished before the trailing
# always() evidence steps reported — they froze at null. A genuine red
# must never trip regardless of the frozen tail (a fresh runner
# allocation cannot fix a defect).
out="$(fixture fc4 '{"jobs": [{"name": "Core tests (shard 1/4)", "conclusion": "failure", "steps": [{"name": "dart test", "conclusion": "failure"}, {"name": "junit durations", "conclusion": null}, {"name": "Post cache", "conclusion": null}]}]}')"
[ "$(trip_line "$out")" = "trip=false" ]
check "FC4 failed step + frozen trailing steps (death after a real red) does NOT trip" $?

# FC2 — clean, skipped, never-started, empty.
out="$(fixture fc2a '{"jobs": [{"name": "Static gates", "conclusion": "success", "steps": [{"name": "analyze", "conclusion": "success"}]}]}')"
[ "$(trip_line "$out")" = "trip=false" ]
check "FC2a success job does not trip" $?

out="$(fixture fc2b '{"jobs": [{"name": "Golden suite (macOS baselines)", "conclusion": "skipped", "steps": []}]}')"
[ "$(trip_line "$out")" = "trip=false" ]
check "FC2b skipped job does not trip" $?

out="$(fixture fc2c '{"jobs": [{"name": "Binaries smoke gate", "conclusion": "cancelled", "steps": []}]}')"
[ "$(trip_line "$out")" = "trip=false" ]
check "FC2c cancelled never-started job (no steps) does not trip" $?

out="$(fixture fc2d '{"jobs": []}')"
[ "$(trip_line "$out")" = "trip=false" ]
check "FC2d empty jobs array does not trip" $?

# FC3 — malformed body fails safe.
out="$(fixture fc3 'not json at all')"
[ "$(trip_line "$out")" = "trip=false" ]
check "FC3 malformed jobs JSON fails safe to trip=false" $?
printf '%s\n' "$out" | grep -q '::warning::'
check "FC3 malformed body warns loudly" $?

# RG — output contract.
out="$(fixture rg1 "$(json_for cancelled kill)")"
[ "$(trip_count "$out")" = "1" ]
check "RG1 exactly one trip= line on stdout" $?

printf '%s\n' "$out" | grep -vE '^trip=' | grep -qE '^trip='
[ $? -ne 0 ]
check "RG2 no diagnostic line masquerades as trip=" $?

out_file="$TMP/github_output"
: > "$out_file"
GITHUB_OUTPUT="$out_file" bash "$CHECK" "$TMP/ac1.json" > "$TMP/rg3.out"
grep -cE '^trip=(true|false)$' "$out_file" > "$TMP/rg3.count"
[ "$(cat "$TMP/rg3.count")" = "1" ]
check "RG3 exactly one trip= line lands in GITHUB_OUTPUT" $?

out="$(fixture rg4 '{"jobs": [{"name": "PTY shard 2/3", "conclusion": "cancelled", "steps": [{"name": "dart test", "conclusion": "cancelled"}, {"name": "upload", "conclusion": "skipped"}]}, {"name": "PTY shard 0/3", "conclusion": "cancelled", "steps": [{"name": "dart test", "conclusion": "cancelled"}, {"name": "upload", "conclusion": "skipped"}]}]}')"
[ "$(trip_line "$out")" = "trip=true" ]
[ "$(trip_count "$out")" = "1" ]
check "RG4 multiple matches trip once, one line" $?

# RG5 — stdin arm (`-`).
out="$(printf '%s' "$(json_for cancelled kill)" | bash "$CHECK" - 2>&1)"
[ "$(trip_line "$out")" = "trip=true" ]
check "RG5 stdin arm trips" $?

if [ "$fails" -gt 0 ]; then
  echo "watchdog_trip_selftest: $fails FAILURE(S)"
  exit 1
fi
echo "watchdog_trip_selftest: all green"
