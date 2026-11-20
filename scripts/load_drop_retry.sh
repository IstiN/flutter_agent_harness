#!/usr/bin/env bash
# load_drop_retry.sh — one-shot loopback-ws load-drop retry for sharded
# dart test legs (issue #2331).
#
# Family: under CI-leg load the dart test loader's loopback WebSocket
# (127.0.0.1:…/ws) to a freshly spawned test VM can die mid-handshake —
#   Failed to load "<file>": Connection closed before full header was
#   received, uri = http://127.0.0.1:…/ws
#   Failed to load "<file>": Connection reset by peer, uri=http://127.0.0.1:…/ws
# The victim file is arbitrary (whatever is loading when the socket dies),
# never an assertion failure (6/6 occurrences on the card). The shard reds
# even though every test that ran was green.
#
# This wrapper runs the shard's dart test command as given, and on failure
# that carries BOTH the `Failed to load "<path>"` marker AND a ws-drop
# signature, re-runs ONLY the dropped file(s) once (the gh-1026
# rerun-only-failed-files discipline). Real test failures never match the
# signature and stay loud — nothing is rerun blind, nothing is masked.
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
#                space-separated target list (word-split here).
#
# Exit: 0 when the run (or the single rerun) is green; the failing exit
# code otherwise. Coverage consumers are safe: the rerun inherits
# --coverage=coverage, so a healed file's hits land in the same coverage/
# dir the gate merges.
set -euo pipefail

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

# Attempt 1 — the command exactly as the step defines it (its own
# --file-reporter=json:<main-log> is part of CMD; dart accumulates repeated
# reporter flags, so the wrapper must not add a second one).
set +e
"${CMD[@]}" $TARGETS 2>&1 | tee "$CONSOLE"
RC=${PIPESTATUS[0]}
set -e
if [ "$RC" -eq 0 ]; then
  exit 0
fi

# Detection: the ws-drop family signature ONLY. A real assertion failure,
# compile error, or timeout never pairs `Failed to load "…"` with ws text
# (that prefix is emitted solely by the test loader) — those exit here,
# loud.
if ! grep -qE 'Connection closed before full header was received|Connection reset by peer' \
    "$CONSOLE"; then
  echo "load_drop_retry: failure carries no loopback-ws drop signature — not rerunning" >&2
  exit "$RC"
fi
DROPPED=$(awk '/Failed to load/ && (/Connection closed before full header was received/ || /Connection reset by peer/)' \
  "$CONSOLE" |
  sed -E -e 's/.*Failed to load "([^"]+)".*/\1/' -e 't' -e 's/.*Failed to load ([^:"]+):.*/\1/' |
  sort -u)
if [ -z "$DROPPED" ]; then
  echo "load_drop_retry: ws-drop signature present but no dropped file extractable — not rerunning blind" >&2
  exit "$RC"
fi

echo "🔁 load-drop retry (#2331): rerunning dropped file(s) ONCE:" >&2
printf '%s\n' "$DROPPED" | sed 's/^/   /' >&2

RETRY_CMD=()
for arg in "${CMD[@]}"; do
  case "$arg" in
    --file-reporter=*) ;;            # rerun writes to RETRY_LOG instead
    *) RETRY_CMD+=("$arg") ;;
  esac
done

set +e
"${RETRY_CMD[@]}" --file-reporter="json:$RETRY_LOG" $DROPPED 2>&1 | tee -a "$CONSOLE"
RETRY_RC=${PIPESTATUS[0]}
set -e

if [ "$RETRY_RC" -eq 0 ]; then
  echo "✅ load-drop retry: healed — dropped file(s) green on the rerun" >&2
  exit 0
fi
echo "❌ load-drop retry: rerun still red (exit $RETRY_RC) — failing loudly" >&2
exit "$RETRY_RC"
