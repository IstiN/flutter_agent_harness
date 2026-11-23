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

# Attempt 1 — the command exactly as the step defines it (its own
# --file-reporter=json:<main-log> is part of CMD; dart accumulates repeated
# reporter flags, so the wrapper must not add a second one).
set +e
"${CMD[@]}" $TARGETS 2>&1 | tee "$CONSOLE"
RC=${PIPESTATUS[0]}
set -e

RERUNS=0
SEGMENT="$CONSOLE"     # the FAILING attempt's own output (detection input)
REPORTER="$MAIN_LOG"   # that attempt's reporter log (rerun inventory input)

while [ "$RC" -ne 0 ] && [ "$RERUNS" -lt "$MAX_RERUNS" ]; do
  # Detection gates WHETHER this wrapper reruns at all: the ws-drop family
  # signature on the FAILING attempt's own segment — a healed attempt-1
  # line living in the accumulated console can never re-arm the loop. A
  # real assertion failure, compile error, or timeout never pairs
  # `Failed to load "…"` with ws text (that prefix is emitted solely by
  # the test loader) — with no signature the failure is deterministic
  # runner territory: exit here, loud, no rerun.
  if ! grep -qE 'Connection closed before full header was received|Connection reset by peer' \
    "$SEGMENT"; then
    echo "load_drop_retry: failure carries no loopback-ws drop signature — not rerunning" >&2
    exit "$RC"
  fi
  DROPPED=$(awk '/Failed to load/ && (/Connection closed before full header was received/ || /Connection reset by peer/)' \
    "$SEGMENT" |
    sed -E -e 's/.*Failed to load "([^"]+)".*/\1/' -e 't' -e 's/.*Failed to load ([^:"]+):.*/\1/' |
    sort -u)
  # WHAT to rerun is the FULL failed inventory of the failing attempt, not
  # just the ws-dropped files (PR #2347 review round 1, blocking): union
  # the console drops with every failed suite the attempt's reporter
  # recorded (gate_failed_targets.py — failure AND error results, load
  # failures via the hidden `loading <path>` tests; missing/unparsable log
  # = clean empty). A co-occurring real failure is therefore IN the rerun
  # and fails it — the shard stays red; an attempt whose ONLY failures are
  # ws drops heals.
  REPORTER_FAILED=$(python3 scripts/gate_failed_targets.py "$REPORTER")
  RERUN_TARGETS=$(printf '%s\n%s\n' "$DROPPED" "$REPORTER_FAILED" | sed '/^$/d' | sort -u)
  if [ -z "$RERUN_TARGETS" ]; then
    echo "load_drop_retry: ws-drop signature present but no failed-file inventory — not rerunning blind" >&2
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
  set +e
  "${RETRY_CMD[@]}" --file-reporter="json:$REPORTER" $RERUN_TARGETS 2>&1 \
    | tee "$SEGMENT" | tee -a "$CONSOLE"
  RC=${PIPESTATUS[0]}
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
