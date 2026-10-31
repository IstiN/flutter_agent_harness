#!/usr/bin/env bash
# Dispatch a child workflow and wait for it — NEVER kill it (gh-1903).
# Shared by every dispatching daily-publish leg.
#
# gh-1903 invariant: a child run QUEUED behind siblings on the single
# self-hosted runner (fa-m5-1) is NORMAL OPERATION, not a failure mode.
# The 2026-10-26 incident (daily run 40274465122, issue #1735) cancelled
# TWO healthy queued testflight children (~31m "queue stall" each) and
# failed a fully-built v1.0.648 release solely by killing its place in
# line. What remains here:
#   * dispatch + exact run correlation, unchanged (#343 below);
#   * a read-only wait: child state + elapsed logged every poll, sibling
#     in-progress runs logged on a diagnostic interval while the child has
#     not started — NO stall timer, NO wedge cancel, NO re-dispatch;
#   * bounds: the child's own per-job server-side timeouts (#344) and the
#     leg's timeout-minutes — nothing else;
#   * exactly ONE cancel path: when the LEG itself is terminated (leg
#     timeout, manual cancel → this script gets TERM/INT), cancel only
#     THIS leg's own NEVER-STARTED child (by the already-correlated run
#     id) so an orphaned queued run cannot publish unattended when the
#     pool revives, then fail with a diagnostic naming the child run, its
#     last observed state, and the observed pool activity. A child that
#     ever started, or already completed, is never touched.
#
# The watchdog it replaces (kept for history): #344 budgeted the watch
# (~2x historical duration) and cancelled + re-dispatched a wedged run
# once; gh-172 added a queue-stall window (no in_progress job for
# max(600, budget/8)s) for the pool-held zombie (run 39374894901). Both
# heuristics false-positive on healthy queues by construction — 31m does
# not cover the cli sibling chain's 335m worst-case on the same runner —
# and each cancel loses the queue position and restarts the clock, a
# starvation loop. Zombie handling is now: CANNOT OBSERVE ⇒ CANNOT JUDGE.
# The repo-wide `gh run list --status in_progress` probe is read-only; if
# it shows runs, the queue is presumed healthy; if it shows none while the
# child never started, a ::warning:: names the gh-172 zombie signature and
# the leg timeout surfaces the full diagnostic. Only a repo-wide EMPTY
# in_progress list while the child never started positively establishes
# pool idleness — and even then the script does not cancel (gh-1903).
#
# #343 — correlation (unchanged): the TestFlight and Play legs dispatch
# the SAME workflow (build-mobile.yml) as concurrent `needs: plan`
# siblings; identifying "our" run by event + a createdAt window only let
# the Play leg latch the TestFlight run. Correlation here:
#   * exact displayTitle match (--title) — the child workflow's run-name
#     embeds its inputs, so the sibling's differently-shaped run can never
#     be adopted (`gh run list` cannot filter by inputs; displayTitle is
#     the only distinguisher in the list API);
#   * the NEWEST matching run ([-1]) — never [0];
#   * a tight 30s createdAt window (clock-skew headroom; a run from
#     minutes ago is out of scope).
#
# Usage:
#   dispatch_and_watch.sh WORKFLOW.yml --repo OWNER/REPO --ref main \
#     [--title 'run-name exact match'] [--out-run-id FILE] [-f key=value]...
#
# The run id is written to --out-run-id as soon as correlation succeeds
# (BEFORE the wait), so callers can export the run URL even when the
# child run later fails. Env knobs (test shims): DW_POLL_SECONDS (60),
# DW_APPEAR_POLL_SECONDS (10), DW_APPEAR_ATTEMPTS (60),
# DW_DIAG_SECONDS (300 — sibling-liveness probe interval while the child
# has not started; 0 = every poll).
set -euo pipefail

# ─ gh-1903 orphan backstop (re-invocation mode) ────────────────────────────
# The watcher installs a detached BACKSTOP once its child run is correlated.
# Rationale (bash 5.3 / ubuntu-26.04, 2026-10-29 CI reds on main b54f324c
# and PR #1958 6a49b3ec): run_pending_traps can fire while the shell's
# parser holds a half-read construct (input.c's read loop and eval.c's
# parse_command both call it), and the trap ACTION STRING is then parsed in
# that poisoned state — bash prints `trap: line 2: unexpected EOF while
# looking for matching ')'` and exits 2 WITHOUT running orphan_cleanup. The
# trap handler parse is therefore not a containment guarantee, so the
# backstop owns the same decision independently: if the watcher dies without
# the handler having marked "$2/handler-ran" (poisoned parse, SIGKILL after
# a wedged signal handoff, any death mode), cancel the never-started child
# exactly like the handler would — gh-1903 contract verbatim: never-started
# children only, exactly one cancel (the handler marks itself BEFORE its own
# gh call, so backstop and handler can never double-cancel).
if [ "${1:-}" = "--dw-orphan-backstop" ]; then
  backstop_parent="$2"
  backstop_state="$3"
  backstop_run_id="$4"
  backstop_repo="$5"
  backstop_workflow="$6"
  while kill -0 "$backstop_parent" 2>/dev/null; do
    # The state dir is the watcher's side of the contract: it is removed on
    # every deliberate stop (stop_orphan_backstop). If it is gone while the
    # PID still answers (recycled PID), stop anyway — never a leaked
    # process on the shared pool (#1001 hygiene).
    [ -e "$backstop_state" ] || exit 0
    sleep "${DW_BACKSTOP_POLL_SECONDS:-1}"
  done
  if [ -e "$backstop_state/handler-ran" ]; then
    rm -rf "$backstop_state" 2>/dev/null || true
    exit 0
  fi
  if [ -e "$backstop_state/child-started" ]; then
    rm -rf "$backstop_state" 2>/dev/null || true
    exit 0
  fi
  backstop_status="$(gh run view "$backstop_run_id" --repo "$backstop_repo" \
    --json status --jq .status 2>/dev/null)" || backstop_status=""
  if [ "$backstop_status" = "completed" ]; then
    rm -rf "$backstop_state" 2>/dev/null || true
    exit 0
  fi
  echo "::error::dispatch_and_watch: watcher died without running the orphan-cleanup handler (trap-action parse loss?) — backstop cancelling never-started child $backstop_workflow run $backstop_run_id (gh-1903 containment)" >&2
  gh run cancel "$backstop_run_id" --repo "$backstop_repo" \
    || echo "::warning::backstop orphan cancel of run $backstop_run_id failed (already gone?)" >&2
  rm -rf "$backstop_state" 2>/dev/null || true
  exit 0
fi

workflow=""
repo="${GITHUB_REPOSITORY:-}"
ref="main"
title=""
out_run_id=""
inputs=()

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --ref) ref="$2"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    --out-run-id) out_run_id="$2"; shift 2 ;;
    -f) inputs+=( -f "$2" ); shift 2 ;;
    -*) echo "dispatch_and_watch: unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -n "$workflow" ]; then
        echo "dispatch_and_watch: unexpected extra arg: $1" >&2; exit 2
      fi
      workflow="$1"; shift
      ;;
  esac
done
if [ -z "$workflow" ] || [ -z "$repo" ]; then
  echo "usage: dispatch_and_watch.sh WORKFLOW.yml --repo OWNER/REPO [--ref main] [--title T] [--out-run-id FILE] [-f k=v]" >&2
  exit 2
fi

poll="${DW_POLL_SECONDS:-60}"
appear_poll="${DW_APPEAR_POLL_SECONDS:-10}"
appear_attempts="${DW_APPEAR_ATTEMPTS:-60}"
diag="${DW_DIAG_SECONDS:-300}"

# jq selector: optional exact displayTitle match (#343).
title_select=""
if [ -n "$title" ]; then
  title_select=" | select(.displayTitle == \"${title}\")"
fi

dispatch() {
  gh workflow run "$workflow" --repo "$repo" --ref "$ref" ${inputs[@]+"${inputs[@]}"}
}

# The id of OUR run: workflow_dispatch runs created at/after the floor,
# matching --title when given, NEWEST of the matches (#343).
find_run_id() {
  local floor="$1"
  gh run list --repo "$repo" --workflow "$workflow" --event workflow_dispatch \
    --limit 20 --json databaseId,createdAt,displayTitle \
    --jq "[.[] | select((.createdAt | fromdateiso8601) >= $floor)${title_select}] | sort_by(.createdAt) | .[-1].databaseId // 0" \
    2>/dev/null || echo 0
}

wait_for_run() {
  local floor="$1" id=0 i=0
  while [ "$i" -lt "$appear_attempts" ]; do
    id=$(find_run_id "$floor")
    if [ "$id" -gt 0 ] 2>/dev/null; then echo "$id"; return 0; fi
    sleep "$appear_poll"
    i=$((i + 1))
  done
  return 1
}

# ── gh-1903 single cancel path: the orphan-cleanup trap ────────────────────
# Leg timeout / manual cancel make the runner TERM (then KILL) this
# script. On TERM/INT: if OUR child was never started and is not completed,
# cancel exactly that run (gh-172 containment — an orphaned queued run
# must not publish unattended when the pool revives) and fail naming the
# child, its last observed state, and the observed pool activity. A child
# that ever started — even if it is between jobs right now — is left
# alone: its own per-job server-side timeouts (#344) bound it.
#
# The handler marks "$dw_state/handler-ran" BEFORE its first gh call so the
# detached backstop (spawned at the correlation site below) can tell a
# handled death from a lost handler and never double-cancel. DW_TRAP_PARSE_
# DEATH=1 (test shim) installs a deliberately unparseable trap action,
# reproducing the bash-5.3 poisoned-parse death (exit 2, handler never runs)
# that lost the orphan-cancel on CI reds main b54f324c / PR #1958 6a49b3ec.
run_id=0
child_started=0
watch_started=0
last_state="(never polled)"
pool_note="no pool observation yet"
dw_state=""

orphan_cleanup() {
  local sig="$1" ec=143 now
  [ "$sig" = "INT" ] && ec=130
  if [ -n "$dw_state" ]; then
    : > "$dw_state/handler-ran" 2>/dev/null || true
  fi
  now=$(date +%s)
  if [ "$run_id" -gt 0 ] 2>/dev/null \
      && [ "$child_started" -eq 0 ] \
      && [ "${last_state%%/*}" != "completed" ]; then
    echo "::error::leg terminated by $sig after $((now - watch_started))s — child $workflow run $run_id NEVER STARTED (last observed: $last_state; $pool_note); cancelling this orphaned child only (gh-1903 orphan-cancel) — https://github.com/$repo/actions/runs/$run_id" >&2
    gh run cancel "$run_id" --repo "$repo" \
      || echo "::warning::orphan cancel of run $run_id failed (already gone?)" >&2
  else
    echo "::error::leg terminated by $sig after $((now - watch_started))s — child $workflow run $run_id (started: $([ "$child_started" -eq 1 ] && echo yes || echo no); last observed: $last_state; $pool_note); nothing to cancel (gh-1903: never-started children only)" >&2
  fi
  exit "$ec"
}
if [ "${DW_TRAP_PARSE_DEATH:-0}" = "1" ]; then
  # Test shim: the action string the bash-5.3 poisoned parser dies on
  # (unbalanced `(` — parser_error → exit 2, orphan_cleanup never runs).
  trap 'orphan_cleanup TERM ( ' TERM
  trap 'orphan_cleanup INT ( ' INT
else
  trap 'orphan_cleanup TERM' TERM
  trap 'orphan_cleanup INT' INT
fi

dispatch
epoch=$(date +%s)
if ! run_id=$(wait_for_run "$((epoch - 30))"); then
  echo "::error::dispatched $workflow run never appeared (no workflow_dispatch run${title:+ titled \"$title\"} in the trailing window after $((appear_attempts * appear_poll))s)" >&2
  exit 1
fi
echo "watching $workflow run $run_id${title:+ (\"$title\")} — https://github.com/$repo/actions/runs/$run_id — read-only wait, no stall timer, no re-dispatch (gh-1903)"
if [ -n "$out_run_id" ]; then printf '%s\n' "$run_id" > "$out_run_id"; fi

# ─ gh-1903 orphan backstop: the cancel must not depend on the trap parse ───
# Spawned AFTER correlation (a run id exists to cancel) and detached via
# setsid where available, so a leg-timeout tree-kill cannot take it down
# with the watcher. Stopped explicitly on every NORMAL exit; on a handler
# exit it self-terminates after seeing the handler-ran marker.
dw_backstop_pid=""
dw_state="$(mktemp -d "${TMPDIR:-/tmp}/dw-orphan-XXXXXX" 2>/dev/null)" || dw_state=""
stop_orphan_backstop() {
  if [ -n "$dw_backstop_pid" ]; then
    kill "$dw_backstop_pid" 2>/dev/null || true
    wait "$dw_backstop_pid" 2>/dev/null || true
    dw_backstop_pid=""
  fi
  if [ -n "$dw_state" ]; then
    rm -rf "$dw_state" 2>/dev/null || true
    dw_state=""
  fi
}
if [ -n "$dw_state" ]; then
  printf '%s\n' "$run_id" > "$dw_state/run-id"
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$0" --dw-orphan-backstop "$$" "$dw_state" "$run_id" "$repo" "$workflow" >/dev/null 2>&1 &
  else
    bash "$0" --dw-orphan-backstop "$$" "$dw_state" "$run_id" "$repo" "$workflow" >/dev/null 2>&1 &
  fi
  dw_backstop_pid=$!
fi

watch_started=$(date +%s)
last_diag=0
while :; do
  # One poll = one API call (gh-172 review): status, conclusion and the
  # running-job count arrive atomically — no race where two calls
  # straddle a completion. A failed poll cannot observe, so it cannot
  # judge (gh-172): it is logged and the wait simply continues — the
  # bounds are the child's per-job server-side timeouts (#344) and the
  # leg timeout, and there is no heuristic left to poison.
  observed="$(gh run view "$run_id" --repo "$repo" --json status,conclusion,jobs \
    --jq '"\(.status)/" + (.conclusion // "-") + " " + ([.jobs[] | select(.status == "in_progress")] | length | tostring)' 2>/dev/null)" || observed=""
  if [ -z "$observed" ] || [ "${observed%% *}" = "$observed" ]; then
    status="error/-"
    running=""
    last_state="$status"
    echo "poll failed (gh/API unreachable) after $(( $(date +%s) - watch_started ))s — cannot observe, cannot judge (gh-172); the wait continues"
  else
    status="${observed%% *}"
    running="${observed##* }"
    last_state="$status"
    if [ -n "$running" ] && [ "$running" -gt 0 ] 2>/dev/null; then
      child_started=1
      # The backstop reads the flag from disk (it outlives this shell).
      if [ -n "$dw_state" ]; then
        printf '1\n' > "$dw_state/child-started" 2>/dev/null || true
      fi
    fi
    echo "child $run_id: $status running_jobs=${running:-unknown} elapsed=$(( $(date +%s) - watch_started ))s (started: $([ "$child_started" -eq 1 ] && echo yes || echo 'not yet — queued is healthy, gh-1903'))"
  fi
  if [ "${status%%/*}" = "completed" ]; then break; fi
  now=$(date +%s)

  # gh-1903 read-only zombie diagnostics: while the child has not started,
  # probe repo-wide liveness on the diagnostic interval. This NEVER
  # cancels — it only distinguishes "queued behind siblings" (healthy)
  # from "pool appears idle but the child never starts" (the gh-172
  # zombie signature, surfaced in full at the leg timeout above).
  if [ "$child_started" -eq 0 ] && [ $((now - last_diag)) -ge "$diag" ]; then
    last_diag="$now"
    if sibs="$(gh run list --repo "$repo" --status in_progress --limit 20 \
        --json databaseId,displayTitle \
        --jq '[.[] | select(.databaseId != '"$run_id"')] | length as $n | "\($n) in_progress run(s): " + ([.[] | "\(.databaseId) \(.displayTitle)"] | join("; "))' 2>/dev/null)"; then
      if [ "${sibs%% *}" = "0" ]; then
        pool_note="repo-wide in_progress runs: NONE while child never started for $((now - watch_started))s — pool appears IDLE (gh-172 zombie signature possible; cannot be confirmed — the runners API is 403 for this token)"
        echo "::warning::$pool_note — NO cancel (gh-1903); if this is a real zombie the leg timeout surfaces the full diagnostic"
      else
        pool_note="repo-wide $sibs"
        echo "sibling activity — $sibs — the queued child is waiting behind these; healthy, no cancel, no stall timer (gh-1903)"
      fi
    else
      pool_note="pool liveness probe FAILED (gh/API unreachable) — pool idleness can be neither established nor excluded"
      echo "pool liveness probe failed — cannot observe, cannot judge (gh-172); no cancel regardless (gh-1903)"
    fi
  fi
  sleep "$poll"
done

# Normal exits stop the backstop first — the child is done; a surviving
# backstop here could only misread the state dir and double-act.
stop_orphan_backstop
conclusion="${status#*/}"
echo "$workflow run $run_id conclusion: $conclusion"
if [ "$conclusion" = "success" ]; then exit 0; fi
echo "::error::$workflow run $run_id concluded $conclusion — https://github.com/$repo/actions/runs/$run_id" >&2
exit 1
