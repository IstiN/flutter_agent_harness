#!/usr/bin/env bash
# load_drop_retry.sh — one-shot retry for sharded dart test legs: the
# loopback-ws load drops (issue #2331) and the engine-abandonment wedge
# (gh-2381).
#
# Family 1 (issue #2331): under CI-leg load the dart test loader's
# loopback WebSocket (127.0.0.1:…/ws) to a freshly spawned test VM can die
# mid-handshake —
#   Failed to load "<file>": Connection closed before full header was
#   received, uri = http://127.0.0.1:…/ws
#   Failed to load "<file>": Connection reset by peer, uri=http://127.0.0.1:…/ws
# The victim file is arbitrary (whatever is loading when the socket dies),
# never an assertion failure (6/6 occurrences on the card). The shard reds
# even though every test that ran was green.
#
# Family 2 (gh-2381, run 45200064457 shard 2/3): the same load class can
# kill the VM-service connection DURING a post-suite coverage gather; the
# test_core engine's run loop dies with the suite queue still pending —
# tests left IN FLIGHT (their tearDowns never run → live pty2 children)
# and whole suites never loaded — while the file-reporter records only the
# finished subset (allSuites count 26, 16 suite events, testStart 101 vs
# testDone 98). The abandoned pty2 `_waitForExitCode` isolates then block
# the VM's exit handshake forever (`Attempt:N waiting for isolate
# _waitForExitCode to check in`) and the shard burns its WHOLE budget
# before the timeout kill lands `cancelled`.
#
# This wrapper runs the shard's dart test command as given, and on a run
# carrying a TRANSIENT signature — the ws-drop text above, a started-but-
# never-finished test in the reporter, or an invocation target with no
# suite event at all — re-runs the transient inventory ONCE (the gh-1026
# rerun-only-failed discipline): transient targets PLUS every failed suite
# the attempt-1 reporter records (via the repo's
# scripts/gate_failed_targets.py). A co-occurring real failure — assertion
# failure or compile-error load failure — is therefore IN the rerun and
# keeps the shard red; an attempt 1 whose only losses are transient heals.
# Without a transient signature the wrapper never reruns at all: real
# failures stay loud, nothing is rerun blind, nothing is masked.
#
# The exit-handshake wedge gets a watchdog instead of a 40-minute burn:
# sustained `Attempt:N waiting for isolate …` console spam means the run's
# results are already in the file-reporter (it flushes per event) and
# coverage is per-suite incremental, so the wedged runner is SIGKILLed and
# the normal evidence-driven decision proceeds. The spam budget is
# LOAD_DROP_RETRY_SPAM_LIMIT (default 8 lines; 0 disables the watchdog).
# The pattern is anchored on the `Attempt:` prefix — test-failure text that
# QUOTES the phrase (pty_harness's shutdownPty StateError) never matches.
#
# Usage:
#   scripts/load_drop_retry.sh <main-log> <retry-log> -- <cmd...> "<targets>"
#
#   <main-log>   the path of the caller's own --file-reporter=json:<main-log>
#                (passed as part of <cmd...>) that junit/duration consumers
#                read — attempt-1 evidence is never clobbered; also names
#                the <main-log>.console capture;
#   <retry-log>  where the rerun's reporter writes (kept separate so the
#                main log is never overwritten);
#   <cmd...>     the full dart test invocation INCLUDING its own
#                --file-reporter flag; the FINAL argument is the quoted,
#                newline/space-separated target list (word-split here).
#
# Exit: 0 when the run (or the single rerun) is green; the failing exit
# code otherwise. Coverage consumers are safe: the rerun inherits
# --coverage=coverage, so a healed file's hits land in the same coverage/
# dir the gate merges.
set -euo pipefail
# TARGETS/RERUN_TARGETS expand unquoted below (word-split by design — the
# caller passes a quoted, space-separated list). Glob-off: a path carrying
# glob metacharacters must never expand (PR #2347 review digest).
set -f

usage() {
  echo "usage: $0 <main-log> <retry-log> -- <cmd...> \"<targets>\"" >&2
  exit 2
}

[ "$#" -ge 5 ] || usage
MAIN_LOG=$1
RETRY_LOG=$2
[ "${3:-}" = "--" ] || usage
shift 3
CMD=("${@:1:$#-1}")       # command + flags (including --file-reporter=…)
TARGETS="${!#}"           # final arg: quoted, space-separated target list
[ -n "$TARGETS" ] || usage

CONSOLE="${MAIN_LOG}.console"
SPAM_LIMIT="${LOAD_DROP_RETRY_SPAM_LIMIT:-8}"
FIFO=""
WATCHDOG_PID=""
RUNNER_RC=""

cleanup() {
  if [ -n "$WATCHDOG_PID" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
  fi
  if [ -n "$FIFO" ]; then
    rm -f "$FIFO" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# run_streamed [--append] — runs CMD+TARGETS with output streamed to the
# console capture (live CI log) under the gh-2381 exit-handshake watchdog;
# leaves the runner's exit code in RUNNER_RC. Single-writer named pipe: the
# runner's stdout+stderr feed a background tee, and `$!` IS the runner pid
# — an exact kill target with no pgrep topology guessing.
run_streamed() {
  local append=false
  [ "${1:-}" = "--append" ] && append=true
  FIFO="${CONSOLE}.fifo"
  mkfifo "$FIFO"
  if $append; then
    tee -a "$CONSOLE" < "$FIFO" &
  else
    tee "$CONSOLE" < "$FIFO" &
  fi
  local tee_pid=$!
  "${CMD[@]}" $TARGETS > "$FIFO" 2>&1 &
  local runner_pid=$!
  if [ "${SPAM_LIMIT:-8}" -gt 0 ] 2>/dev/null; then
    (
      while kill -0 "$runner_pid" 2>/dev/null; do
        n=$(grep -cE 'Attempt:[0-9]+ waiting for isolate' "$CONSOLE" 2>/dev/null) || n=0
        if [ "${n:-0}" -ge "$SPAM_LIMIT" ]; then
          echo "load_drop_retry: exit-handshake wedge — $n 'waiting for isolate' spam lines; SIGKILL the wedged runner (results are already in the reporter, coverage is per-suite incremental; gh-2381)" >&2
          kill -9 "$runner_pid" 2>/dev/null || true
          break
        fi
        sleep 1
      done
    ) &
    WATCHDOG_PID=$!
  fi
  wait "$runner_pid" 2>/dev/null
  RUNNER_RC=$?
  if [ -n "$WATCHDOG_PID" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
    WATCHDOG_PID=""
  fi
  wait "$tee_pid" 2>/dev/null || true
  rm -f "$FIFO" 2>/dev/null || true
  FIFO=""
}

# Attempt 1 — the command exactly as the step defines it (its own
# --file-reporter=json:<main-log> is part of CMD; dart accumulates repeated
# reporter flags, so the wrapper must not add a second one).
set +e
run_streamed
RC=$RUNNER_RC
set -e

# Detection: which TRANSIENT family fired, if any. The ws-drop text gates
# family 1; the gh-2381 projections gate family 2 off the SAME reporter
# log. A real assertion failure alone pairs with neither — that shape is
# deterministic runner territory: exit loudly, no rerun.
if grep -qE 'Connection closed before full header was received|Connection reset by peer' \
    "$CONSOLE"; then
  DROPPED=$(awk '/Failed to load/ && (/Connection closed before full header was received/ || /Connection reset by peer/)' \
    "$CONSOLE" |
    sed -E -e 's/.*Failed to load "([^"]+)".*/\1/' -e 't' -e 's/.*Failed to load ([^:"]+):.*/\1/' |
    sort -u)
else
  DROPPED=""
fi

# gh-2381 projections off the attempt-1 reporter. They are trusted ONLY
# when the log exists and is non-empty — a missing log (crash before the
# reporter flushed) must degrade to the family-1 console evidence alone,
# never to "every target is suspicious" (the no-blind-rerun rule).
REPORTER_FAILED=""
REPORTER_UNFINISHED=""
REPORTER_LOADED=""
HAS_REPORTER=false
if [ -s "$MAIN_LOG" ]; then
  HAS_REPORTER=true
  REPORTER_FAILED=$(python3 scripts/gate_failed_targets.py "$MAIN_LOG")
  REPORTER_UNFINISHED=$(python3 scripts/gate_failed_targets.py --unfinished "$MAIN_LOG")
  REPORTER_LOADED=$(python3 scripts/gate_failed_targets.py --loaded "$MAIN_LOG")
fi

# Invocation targets the engine never even loaded (planned by allSuites,
# absent from the suite events — the ten vanished suites of run 45200064457).
NEVER_LOADED=""
if $HAS_REPORTER; then
  for t in $TARGETS; do
    if printf '%s\n' "$REPORTER_LOADED" | grep -Fxq -- "$t"; then continue; fi
    if printf '%s\n' "$DROPPED" | grep -Fxq -- "$t"; then continue; fi
    NEVER_LOADED="$NEVER_LOADED$t"$'\n'
  done
  NEVER_LOADED=$(printf '%s' "$NEVER_LOADED" | sed '/^$/d' | sort -u)
fi

# The transient inventory: every loss this wrapper exists to heal.
TRANSIENT=$(printf '%s\n%s\n%s\n' "$DROPPED" "$REPORTER_UNFINISHED" \
  "$NEVER_LOADED" | sed '/^$/d' | sort -u)

if [ "$RC" -eq 0 ] && [ -z "$TRANSIENT" ] && [ -z "$REPORTER_FAILED" ]; then
  exit 0
fi

if [ -z "$TRANSIENT" ]; then
  # Real failures only — deterministic, a rerun cannot heal them.
  echo "load_drop_retry: failure carries no transient signature (no loopback-ws drop, no abandoned inventory) — not rerunning" >&2
  exit "$RC"
fi

# WHAT to rerun is the FULL attempt-1 failed inventory, not just the
# transient files (PR #2347 review round 1, blocking): union the transient
# targets with every failed suite the attempt-1 reporter records. A
# co-occurring real failure is therefore IN the rerun and fails it — the
# shard stays red; an attempt 1 whose ONLY losses are transient heals.
RERUN_TARGETS=$(printf '%s\n%s\n' "$TRANSIENT" "$REPORTER_FAILED" | sed '/^$/d' | sort -u)
if [ -z "$RERUN_TARGETS" ]; then
  echo "load_drop_retry: transient signature present but no failed-file inventory — not rerunning blind" >&2
  exit "$RC"
fi

echo "🔁 load-drop retry (#2331/gh-2381): rerunning transient/failed file(s) ONCE:" >&2
printf '%s\n' "$RERUN_TARGETS" | sed 's/^/   /' >&2

RETRY_CMD=()
for arg in "${CMD[@]}"; do
  case "$arg" in
    --file-reporter=*) ;;            # rerun writes to RETRY_LOG instead
    *) RETRY_CMD+=("$arg") ;;
  esac
done

set +e
CMD=("${RETRY_CMD[@]}")
run_streamed --append
RC=$RUNNER_RC
set -e

if [ "$RC" -eq 0 ]; then
  echo "✅ load-drop retry: healed — transient loss(es) green on the rerun" >&2
  exit 0
fi
echo "❌ load-drop retry: rerun still red (exit $RC) — failing loudly" >&2
exit "$RC"
