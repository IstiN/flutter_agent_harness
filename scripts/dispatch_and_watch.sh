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
#     queued+in-progress activity logged on a diagnostic interval while
#     the child has not started — NO stall timer, NO wedge cancel, NO
#     re-dispatch;
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
# The repo-wide `gh run list` liveness probe is read-only and covers BOTH
# queued and in_progress runs (a probe that listed only in_progress would
# read "pool IDLE" during the healthy early-queue window — siblings
# dispatched but not yet picked up — and cry wolf on exactly the shape
# gh-1903 protects; completed runs are filtered out). Only a repo-wide
# list EMPTY in BOTH statuses while the child never started suggests pool
# idleness — the gh-172 zombie signature, named in a ::warning:: — and
# even then the script does not cancel (gh-1903).
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
run_id=0
child_started=0
# Leg start, taken at script start (NOT at the first watch poll): every
# elapsed diagnostic — including a TERM landing in the dispatch/appear
# window — then means leg-elapsed from the runner's perspective.
watch_started=$(date +%s)
last_state="(never polled)"
pool_note="no pool observation yet"

orphan_cleanup() {
  local sig="$1" ec=143 now fresh
  [ "$sig" = "INT" ] && ec=130
  now=$(date +%s)
  if [ "$run_id" -gt 0 ] 2>/dev/null \
      && [ "$child_started" -eq 0 ] \
      && [ "${last_state%%/*}" != "completed" ]; then
    # gh-1903: child_started/last_state are records of the LAST
    # SUCCESSFUL poll — possibly minutes stale (sustained gh/API outage)
    # or raced by a pickup between the final poll and this TERM. The
    # trap is not latency-sensitive (the leg is already dead, and one
    # `gh run view` is one call), so re-observe ONCE and cancel only
    # what the FRESH observation proves never-started. Cannot observe ⇒
    # cannot judge ⇒ no cancel.
    fresh="$(gh run view "$run_id" --repo "$repo" --json status,conclusion,jobs \
      --jq '"\(.status)/" + (.conclusion // "-") + " " + ([.jobs[] | select(.status == "in_progress")] | length | tostring)' 2>/dev/null)" || fresh=""
    if [ -z "$fresh" ] || [ "${fresh%% *}" = "$fresh" ]; then
      echo "::error::leg terminated by $sig after $((now - watch_started))s — child $workflow run $run_id NOT cancelled: the fresh re-observation FAILED (gh/API unreachable), so never-started cannot be established from the stale last observation ($last_state) — cannot observe, cannot judge (gh-172). Risk: an orphaned never-started child may publish unattended when the pool revives (gh-1903 containment withheld, not waived)" >&2
    elif [ "${fresh%%/*}" = "completed" ]; then
      echo "::error::leg terminated by $sig after $((now - watch_started))s — child $workflow run $run_id already ${fresh%% *} (fresh re-observation); nothing to cancel (gh-1903)" >&2
    elif [ "${fresh##* }" -gt 0 ] 2>/dev/null; then
      echo "::error::leg terminated by $sig after $((now - watch_started))s — child $workflow run $run_id STARTED between the last poll and this $sig (fresh re-observation: $fresh); left alone — a started child is bounded by its own per-job server-side timeouts (#344), never cancelled (gh-1903)" >&2
    else
      echo "::error::leg terminated by $sig after $((now - watch_started))s — child $workflow run $run_id NEVER STARTED (fresh re-observation: $fresh; $pool_note); cancelling this orphaned child only (gh-1903 orphan-cancel) — https://github.com/$repo/actions/runs/$run_id" >&2
      gh run cancel "$run_id" --repo "$repo" \
        || echo "::warning::orphan cancel of run $run_id failed (already gone?)" >&2
    fi
  else
    echo "::error::leg terminated by $sig after $((now - watch_started))s — child $workflow run $run_id (started: $([ "$child_started" -eq 1 ] && echo yes || echo no); last observed: $last_state; $pool_note); nothing to cancel (gh-1903: never-started children only)" >&2
  fi
  exit "$ec"
}
trap 'orphan_cleanup TERM' TERM
trap 'orphan_cleanup INT' INT

dispatch
epoch=$(date +%s)
if ! run_id=$(wait_for_run "$((epoch - 30))"); then
  echo "::error::dispatched $workflow run never appeared (no workflow_dispatch run${title:+ titled \"$title\"} in the trailing window after $((appear_attempts * appear_poll))s)" >&2
  exit 1
fi
echo "watching $workflow run $run_id${title:+ (\"$title\")} — https://github.com/$repo/actions/runs/$run_id — read-only wait, no stall timer, no re-dispatch (gh-1903)"
if [ -n "$out_run_id" ]; then printf '%s\n' "$run_id" > "$out_run_id"; fi

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
    fi
    echo "child $run_id: $status running_jobs=${running:-unknown} elapsed=$(( $(date +%s) - watch_started ))s (started: $([ "$child_started" -eq 1 ] && echo yes || echo 'not yet — queued is healthy, gh-1903'))"
  fi
  if [ "${status%%/*}" = "completed" ]; then break; fi
  now=$(date +%s)

  # gh-1903 read-only zombie diagnostics: while the child has not started,
  # probe repo-wide liveness on the diagnostic interval. This NEVER
  # cancels — it only distinguishes "queued behind siblings" (healthy)
  # from "pool appears idle but the child never starts" (the gh-172
  # zombie signature, surfaced in full at the leg timeout above). The
  # probe lists the repo UNFILTERED (one listing, not per-status polls)
  # and filters to non-completed runs: queued siblings are the healthy
  # early-queue shape, and an in_progress-only probe would read "pool
  # IDLE" during exactly that window — the wolf-crier this change exists
  # to remove.
  if [ "$child_started" -eq 0 ] && [ $((now - last_diag)) -ge "$diag" ]; then
    last_diag="$now"
    if sibs="$(gh run list --repo "$repo" --limit 100 \
        --json databaseId,displayTitle,status \
        --jq '[.[] | select(.status != "completed" and .databaseId != '"$run_id"')] | (map(select(.status == "queued")) | length) as $q | (map(select(.status == "in_progress")) | length) as $p | "\($q) queued run(s), \($p) in_progress run(s): " + ([.[] | "\(.databaseId) \(.status) \(.displayTitle)"] | join("; "))' 2>/dev/null)"; then
      queued_n="${sibs%% queued run(s),*}"
      prog_n="${sibs#*, }"; prog_n="${prog_n%% in_progress run(s):*}"
      if [ "$queued_n" -eq 0 ] 2>/dev/null && [ "$prog_n" -eq 0 ] 2>/dev/null; then
        pool_note="repo-wide active (queued+in_progress) runs: NONE while child never started for $((now - watch_started))s — pool appears IDLE (gh-172 zombie signature possible; cannot be confirmed — the runners API is 403 for this token)"
        echo "::warning::$pool_note — NO cancel (gh-1903); if this is a real zombie the leg timeout surfaces the full diagnostic"
      elif [ "$prog_n" -eq 0 ] 2>/dev/null; then
        pool_note="repo-wide $sibs"
        echo "queued sibling activity — $sibs — the child is queued behind these (none in_progress yet); healthy, no idle claim, no cancel, no stall timer (gh-1903)"
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

conclusion="${status#*/}"
echo "$workflow run $run_id conclusion: $conclusion"
if [ "$conclusion" = "success" ]; then exit 0; fi
echo "::error::$workflow run $run_id concluded $conclusion — https://github.com/$repo/actions/runs/$run_id" >&2
exit 1
