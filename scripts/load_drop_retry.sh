#!/usr/bin/env bash
# load_drop_retry.sh — bounded loopback-ws load-drop retry for sharded
# dart test legs (issue #2331).
#
# Family: under CI-leg load the dart test loader's loopback WebSocket
# (127.0.0.1:…/ws) to a freshly spawned test VM can die mid-handshake —
#   Failed to load "<file>": Connection closed before full header was
#   received, uri = http://127.0.0.1:…/ws
#   Failed to load "<file>": Connection reset by peer, uri=http://127.0.0.1:…/ws
# The victim file is arbitrary (whatever is loading when the socket dies),
# never an assertion failure (10/10 occurrences on the card). The shard reds
# even though every test that ran was green.
#
# This wrapper runs the shard's dart test command as given, and on failure
# that carries BOTH the `Failed to load "<path>"` marker AND a ws-drop
# signature, re-runs the failed inventory (the gh-1026
# rerun-only-failed-files discipline): the ws-dropped files PLUS every
# failed suite the failing attempt's reporter log records (the repo's
# scripts/gate_failed_targets.py). A co-occurring real failure — assertion
# failure or compile-error load failure — is therefore IN the rerun and
# keeps the shard red; an attempt whose only failures are ws drops heals.
# Without the ws-drop signature the wrapper never reruns at all: real
# failures stay loud, nothing is rerun blind, nothing is masked.
#
# Bounded retry (not one-shot; PR #2347 shipped the one-shot ancestor):
# every RED attempt whose OWN output carries the signature buys one more
# rerun of THAT attempt's failed inventory, up to
# $LOAD_DROP_RETRY_MAX_RERUNS (default 2 — three attempts total), after a
# drain backoff of $LOAD_DROP_RETRY_BACKOFF_S seconds (default 5, doubling
# per rerun). Detection reads only the failing attempt's own console
# segment — a healed file's old signature line can never re-arm the loop.
# The bound is hard: a drop-always runner reds after the last rerun with
# that attempt's exit code.
#
# Family 2 (gh-2381, run 45200064457 PTY shard 2/3): the same load class can
# kill the VM-service connection DURING a post-suite coverage gather; the
# test_core engine's run loop dies with the suite queue still pending —
# tests left IN FLIGHT (their tearDowns never run → live pty2 children)
# and whole suites never loaded — while the file-reporter records only the
# finished subset (allSuites count 26, 16 suite events, testStart 101 vs
# testDone 98). The abandoned pty2 `_waitForExitCode` isolates then block
# the VM's exit handshake forever (`Attempt:N waiting for isolate
# _waitForExitCode to check in`) and the shard burns its WHOLE budget
# before the timeout kill lands `cancelled`. The wrapper heals this shape
# inside the SAME bounded budget: the gh-2381 projections
# (gate_failed_targets.py --unfinished/--loaded) treat unfinished tests and
# never-loaded invocation targets as transient losses (trusted ONLY when
# the attempt's reporter log exists — a missing log never widens the
# inventory), and an exit-handshake WATCHDOG bounds the burn: sustained
# `Attempt:N waiting for isolate` spam on THIS attempt's fresh console
# output means the results are already recorded (the reporter flushes per
# event; coverage is per-suite incremental), so the wedged runner's
# process group is SIGKILLed and the loop's evidence-driven decision
# proceeds. The spam budget is $LOAD_DROP_RETRY_SPAM_LIMIT (default 8
# lines; 0 disables the watchdog); the pattern is anchored on the
# `Attempt:` prefix so test-failure text that QUOTES the phrase
# (pty_harness's shutdownPty StateError) never trips the kill.
#
# Usage:
#   scripts/load_drop_retry.sh <main-log> <retry-log> -- <cmd...> "<targets>"
#   (interface unchanged from the PR #2347 one-shot — callers need nothing)
#
#   <main-log>   the path of the caller's own --file-reporter=json:<main-log>
#                (passed as part of <cmd...>) that junit/duration consumers
#                read — attempt-1 evidence is never clobbered; also names
#                the <main-log>.console capture;
#   <retry-log>  base path for the reruns' reporter logs: rerun k writes
#                <retry-log>.rerunK (kept separate so the main log is never
#                overwritten; rerun evidence only — no consumer reads it);
#   <cmd...>     the full dart test invocation INCLUDING its own
#                --file-reporter flag; the FINAL argument is the quoted,
#                space-separated target list (word-split here).
#
# Exit: 0 when the run (or a rerun) is green; the failing exit code
# otherwise. Coverage consumers are safe: every rerun inherits
# --coverage=coverage, so healed files' hits land in the same coverage/
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
BACKOFF=${LOAD_DROP_RETRY_BACKOFF_S:-5}
MAX_RERUNS=${LOAD_DROP_RETRY_MAX_RERUNS:-2}
# Operator knobs are consumed by bash integer tests/arithmetic below. A
# sleep-style "5s" or other garbage must not disable the retry loop itself.
[[ "$BACKOFF" =~ ^[0-9]+$ ]] || BACKOFF=5
[[ "$MAX_RERUNS" =~ ^[0-9]+$ ]] || MAX_RERUNS=2
SPAM_LIMIT="${LOAD_DROP_RETRY_SPAM_LIMIT:-8}"
[[ "$SPAM_LIMIT" =~ ^[0-9]+$ ]] || SPAM_LIMIT=8

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
#
# The runner rides `setsid` (own process group) so the watchdog's wedge
# kill takes the WHOLE tree down: a killed dart test leaves its spawned
# children (pty CLIs, `dart run` chains, sleeps) holding the fifo's write
# end — without the group kill, `tee` never sees EOF and this wrapper
# hangs exactly like the wedge it is killing. After the runner exits, tee
# gets a short drain window (an orphan-held write end can keep it alive
# forever) and is then killed; the evidence is complete the moment the
# runner's writes land.
# run_streamed [--append] [segment-file] — the optional second argument is
# the failing-attempt segment file the rerun loop greps for its signature:
# one tee feeds the accumulated console AND the fresh per-attempt segment
# (their #2331 loop contract) plus the live CI log, from the same stream.
run_streamed() {
  local append=false
  [ "${1:-}" = "--append" ] && { append=true; shift; }
  local segment=""
  [ -n "${1:-}" ] && segment="$1"
  FIFO="${CONSOLE}.fifo"
  mkfifo "$FIFO"
  if $append; then
    if [ -n "$segment" ]; then
      tee -a "$CONSOLE" "$segment" < "$FIFO" &
    else
      tee -a "$CONSOLE" < "$FIFO" &
    fi
  else
    tee "$CONSOLE" < "$FIFO" &
  fi
  local tee_pid=$!
  if command -v setsid >/dev/null 2>&1; then
    setsid "${CMD[@]}" $TARGETS > "$FIFO" 2>&1 &
  else
    "${CMD[@]}" $TARGETS > "$FIFO" 2>&1 &
  fi
  local runner_pid=$!
  if [ "$SPAM_LIMIT" -gt 0 ]; then
    (
      # `read -t` is the poll timer: a BUILTIN — killing this subshell
      # mid-wait forks no `sleep` child for the job harness to report. The
      # spam count covers ONLY bytes appended during THIS run: the reruns
      # (--append) share the console with earlier attempts, whose wedge
      # spam must never insta-kill a healthy rerun before its first poll.
      exec 3< /dev/zero
      baseline=$(wc -c < "$CONSOLE" 2>/dev/null) || baseline=0
      while kill -0 "$runner_pid" 2>/dev/null; do
        n=$(tail -c +"$((baseline + 1))" "$CONSOLE" 2>/dev/null |
          grep -cE 'Attempt:[0-9]+ waiting for isolate') || n=0
        if [ "${n:-0}" -ge "$SPAM_LIMIT" ]; then
          echo "load_drop_retry: exit-handshake wedge — $n 'waiting for isolate' spam lines; SIGKILL the wedged runner's process group (results are already in the reporter, coverage is per-suite incremental; gh-2381)" >&2
          kill -9 -- "-$runner_pid" 2>/dev/null || true
          kill -9 "$runner_pid" 2>/dev/null || true
          break
        fi
        read -t 1 -u 3 || true
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
  # Drain window: on the wedge path the group kill closed every write end
  # and tee EOFs on its own; on the normal path orphan-held writers can
  # keep tee alive indefinitely — cap the drain and kill it.
  exec 3< /dev/zero
  local i
  for i in 1 2 3 4 5; do
    kill -0 "$tee_pid" 2>/dev/null || break
    read -t 0.2 -u 3 || true
  done
  kill "$tee_pid" 2>/dev/null || true
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

RERUNS=0
SEGMENT="$CONSOLE"     # the FAILING attempt's own output (detection input)
REPORTER="$MAIN_LOG"   # that attempt's reporter log (rerun inventory input)

while [ "$RC" -ne 0 ] && [ "$RERUNS" -lt "$MAX_RERUNS" ]; do
  # Detection gates WHETHER this wrapper reruns at all, on TWO transient
  # families read from the FAILING attempt's OWN segment — a healed
  # attempt-1 line living in the accumulated console can never re-arm the
  # loop:
  #   family 1 (#2331) — the loopback-ws drop signature;
  #   family 2 (gh-2381) — the engine-abandonment evidence: the attempt's
  #   reporter log records a started-but-never-finished test
  #   (--unfinished) or an invocation target with NO suite event at all
  #   (--loaded complement), i.e. Engine.run() died mid-queue. Trusted
  #   ONLY when the reporter log exists and is non-empty: a missing log
  #   (crash before the reporter flushed) degrades to the console evidence
  #   alone — never "every target is suspicious" (no-blind-rerun).
  # A real assertion failure, compile error, or timeout never pairs
  # `Failed to load "…"` with ws text nor leaves an abandoned inventory —
  # with neither transient the failure is deterministic runner territory:
  # exit here, loud, no rerun.
  HAS_REPORTER=false
  if [ -s "$REPORTER" ]; then HAS_REPORTER=true; fi
  DROPPED=""
  if grep -qE 'Connection closed before full header was received|Connection reset by peer' \
    "$SEGMENT"; then
    DROPPED=$(awk '/Failed to load/ && (/Connection closed before full header was received/ || /Connection reset by peer/)' \
      "$SEGMENT" |
      sed -E -e 's/.*Failed to load "([^"]+)".*/\1/' -e 't' -e 's/.*Failed to load ([^:"]+):.*/\1/' |
      sort -u)
  fi
  REPORTER_FAILED=""
  REPORTER_UNFINISHED=""
  REPORTER_LOADED=""
  if $HAS_REPORTER; then
    REPORTER_FAILED=$(python3 scripts/gate_failed_targets.py "$REPORTER")
    REPORTER_UNFINISHED=$(python3 scripts/gate_failed_targets.py --unfinished "$REPORTER")
    REPORTER_LOADED=$(python3 scripts/gate_failed_targets.py --loaded "$REPORTER")
  fi
  NEVER_LOADED=""
  if $HAS_REPORTER; then
    for t in $TARGETS; do
      if printf '%s\n' "$REPORTER_LOADED" | grep -Fxq -- "$t"; then continue; fi
      if printf '%s\n' "$DROPPED" | grep -Fxq -- "$t"; then continue; fi
      NEVER_LOADED="$NEVER_LOADED$t"$'\n'
    done
    NEVER_LOADED=$(printf '%s' "$NEVER_LOADED" | sed '/^$/d' | sort -u)
  fi
  TRANSIENT=$(printf '%s\n%s\n%s\n' "$DROPPED" "$REPORTER_UNFINISHED" \
    "$NEVER_LOADED" | sed '/^$/d' | sort -u)
  if [ -z "$TRANSIENT" ]; then
    echo "load_drop_retry: failure carries no loopback-ws drop signature (no abandoned inventory either) — not rerunning" >&2
    exit "$RC"
  fi
  # WHAT to rerun is the FULL failed inventory of the failing attempt, not
  # just the transient files (PR #2347 review round 1, blocking): union
  # the transient targets with every failed suite the attempt's reporter
  # recorded (gate_failed_targets.py — failure AND error results, load
  # failures via the hidden `loading <path>` tests; missing/unparsable log
  # = clean empty). A co-occurring real failure is therefore IN the rerun
  # and fails it — the shard stays red; an attempt whose ONLY losses are
  # transient heals.
  RERUN_TARGETS=$(printf '%s\n%s\n' "$TRANSIENT" "$REPORTER_FAILED" | sed '/^$/d' | sort -u)
  if [ -z "$RERUN_TARGETS" ]; then
    echo "load_drop_retry: transient signature present but no failed-file inventory — not rerunning blind" >&2
    exit "$RC"
  fi

  RERUNS=$((RERUNS + 1))
  echo "🔁 load-drop retry (#2331): rerun $RERUNS/$MAX_RERUNS after ${BACKOFF}s drain backoff:" >&2
  printf '%s\n' "$RERUN_TARGETS" | sed 's/^/   /' >&2
  if [ "$BACKOFF" -gt 0 ]; then sleep "$BACKOFF"; fi
  BACKOFF=$((BACKOFF * 2))

  RETRY_CMD=()
  for arg in "${CMD[@]}"; do
    case "$arg" in
      --file-reporter=*) ;;            # rerun writes its own evidence log
      *) RETRY_CMD+=("$arg") ;;
    esac
  done

  SEGMENT="${CONSOLE}.rerun$RERUNS"
  REPORTER="${RETRY_LOG}.rerun$RERUNS"
  RETRY_CMD+=("--file-reporter=json:$REPORTER")
  set +e
  CMD=("${RETRY_CMD[@]}")
  TARGETS="$RERUN_TARGETS"  # the rerun drives the transient/failed inventory
  run_streamed --append "$SEGMENT"
  RC=$RUNNER_RC
  set -e
done

if [ "$RC" -eq 0 ]; then
  if [ "$RERUNS" -gt 0 ]; then
    echo "✅ load-drop retry: healed — dropped file(s) green on rerun $RERUNS" >&2
  fi
  exit 0
fi
echo "❌ load-drop retry: still red after $RERUNS rerun(s) (exit $RC) — failing loudly" >&2
exit "$RC"
