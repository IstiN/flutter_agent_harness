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
#   CK1  the continue-on-error producer kill (gh-2455 review on the
#     watchdog `needs` lap): a `timeout-minutes` kill on a job-level
#     `continue-on-error: true` producer (web-spa, build-extension) is a
#     CANCELLATION, not a failure — the runner's ApplyContinueOnError
#     masks only Failed→Succeeded and leaves Canceled untouched, and the
#     jobs-API conclusion stays RAW under job-level coe — the REAL
#     v1.0.754 tag run 461282156 landed BOTH producers as `failure`
#     (jobs 135885361844/135885361973) on real upload failures. So the
#     kill lands `cancelled` — the same gh-2290 shape — and MUST trip,
#   CK2  the REAL v1.0.754 continue-on-error shape: raw `failure`
#     conclusion with a genuinely failed upload step trailed by success
#     steps — a real red on a coe producer never trips (and the raw
#     conclusion doubles as the proof that coe masking never reaches
#     the jobs-API `conclusion` the watchdog scans),
#   CK3  the masked-kill hypothetical pinned NEGATIVE: a `success`
#     conclusion is never a kill shape (no masked-to-success landing
#     exists in the jobs API — CK2's raw `failure` is the counterproof),
#     so a success job with an anomalous cancelled mid-flight step must
#     NOT trip: widening the signature to success+cut-step would burn
#     the one-shot retrigger on healthy legs; a success leg that did
#     drop its asset strands loudly at the gh-1832 required-assets gate
#     instead (by design),
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

# CK1 — the continue-on-error producer timeout kill (gh-2455 review,
# thread on ci.yml:4287): build-extension carries job-level
# `continue-on-error: true` (ci.yml:5023; web-spa at :4897) and now
# rides in the watchdog `needs`. A `timeout-minutes` kill is a
# CANCELLATION — the runner masks only Failed→Succeeded
# (ApplyContinueOnError, ExecutionContext.cs:1424: `if (Result !=
# TaskResult.Failed) return;`) — so the jobs-API conclusion lands
# `cancelled`, the same gh-2290 shape as the binaries kill, and the
# signature MUST trip for the coe producers too.
out="$(fixture ck1 '{"jobs": [{"name": "Build Chrome extension (release)", "conclusion": "cancelled", "steps": [{"name": "Run actions/checkout", "conclusion": "cancelled"}, {"name": "Build extension zip", "conclusion": "skipped"}, {"name": "Upload extension to the release", "conclusion": "skipped"}]}]}')"
[ "$(trip_line "$out")" = "trip=true" ]
check "CK1 continue-on-error producer timeout kill (cancelled, cut step) trips" $?

# CK2 — the REAL landing shape of a coe producer failure: job-level
# continue-on-error does NOT mask the jobs-API `conclusion`. The
# v1.0.754 tag run 461282156 landed BOTH producers as raw `failure`
# (jobs 135885361844/135885361973): failed upload step, trailing
# always()-steps success. A real red never trips — and the raw
# conclusion is the empirical counterproof to the masked-kill worry.
out="$(fixture ck2 '{"jobs": [{"name": "Build web SPA bundle", "conclusion": "failure", "steps": [{"name": "Build web (release, Pages base)", "conclusion": "success"}, {"name": "Upload bundle to GitHub Release", "conclusion": "failure"}, {"name": "Flag missing bundle in step summary", "conclusion": "success"}]}]}')"
[ "$(trip_line "$out")" = "trip=false" ]
check "CK2 real coe-producer red (v1.0.754 run 461282156 shape) does NOT trip" $?

# CK3 — the masked-kill hypothetical, pinned NEGATIVE: even if a kill
# were ever masked to `success` (it is not — CK2 shows the jobs-API
# conclusion stays raw), a success conclusion must never trip: the
# one-shot retrigger is for degraded RUNNERS, not healthy legs, and a
# success leg that silently dropped its asset strands loudly at the
# gh-1832 required-assets gate by design. This fixture fails if anyone
# ever widens the signature to success+cut-step without revisiting the
# doctrine.
out="$(fixture ck3 '{"jobs": [{"name": "Build web SPA bundle", "conclusion": "success", "steps": [{"name": "Run actions/checkout", "conclusion": "success"}, {"name": "Build web (release, Pages base)", "conclusion": "cancelled"}, {"name": "Package fa-web-spa.zip (relative base + AC3 guard)", "conclusion": "skipped"}]}]}')"
[ "$(trip_line "$out")" = "trip=false" ]
check "CK3 masked-kill hypothetical (success conclusion, cancelled step) does NOT trip" $?

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
