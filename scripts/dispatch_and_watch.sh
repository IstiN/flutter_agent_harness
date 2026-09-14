#!/usr/bin/env bash
# Dispatch a child workflow and watch it — with correct run correlation
# (issue #343) and wedge self-healing (issue #344). Shared by every
# dispatching daily-publish leg so the nightly legs cannot regress to the
# old inline watchers.
#
# #343 — the TestFlight and Play legs dispatch the SAME workflow
# (build-mobile.yml) as concurrent `needs: plan` siblings; the old inline
# watcher identified "our" run by event + a 60s createdAt window only and
# grabbed [0] of the timestamp-ordered list, so the Play leg could latch
# the TestFlight run (or a stale same-shaped run inside the trailing
# window) and watch a build that never builds Android. Correlation here:
#   * exact displayTitle match (--title) — the child workflow's run-name
#     embeds its inputs, so the sibling's differently-shaped run can never
#     be adopted (`gh run list` cannot filter by inputs; displayTitle is
#     the only distinguisher in the list API);
#   * the NEWEST matching run ([-1]) — never [0];
#   * a tight 30s createdAt window (clock-skew headroom; a run from
#     minutes ago, like today's stale iOS failure, is out of scope).
#
# #344 — a self-hosted runner that lost its final job-completion report
# holds a SUCCEEDED job in_progress forever (GitHub has no stale-run
# detection for self-hosted jobs below the workflow timeout), blocking the
# single-runner pool and every watcher leg until their 300m timeout. The
# watch here is budgeted: a run still unfinished after --budget-seconds
# (≈2x historical duration) is CANCELLED and re-dispatched exactly once;
# if the retry also wedges we fail fast naming both runs, so the pool
# problem surfaces in the leg log instead of silently eating 5 hours.
#
# Usage:
#   dispatch_and_watch.sh WORKFLOW.yml --repo OWNER/REPO --ref main \
#     [--title 'run-name exact match'] [--budget-seconds N] \
#     [--out-run-id FILE] [-f key=value]...
#
# The run id is written to --out-run-id as soon as correlation succeeds
# (BEFORE the watch), so callers can export the run URL even when the
# child run later fails. Env knobs (test shims): DW_POLL_SECONDS (60),
# DW_APPEAR_POLL_SECONDS (10), DW_APPEAR_ATTEMPTS (60),
# DW_CANCEL_WAIT_SECONDS (180).
set -euo pipefail

workflow=""
repo="${GITHUB_REPOSITORY:-}"
ref="main"
title=""
budget=$((2 * 60 * 60))
out_run_id=""
inputs=()

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --ref) ref="$2"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    --budget-seconds) budget="$2"; shift 2 ;;
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
  echo "usage: dispatch_and_watch.sh WORKFLOW.yml --repo OWNER/REPO [--ref main] [--title T] [--budget-seconds N] [-f k=v]" >&2
  exit 2
fi

poll="${DW_POLL_SECONDS:-60}"
appear_poll="${DW_APPEAR_POLL_SECONDS:-10}"
appear_attempts="${DW_APPEAR_ATTEMPTS:-60}"
cancel_wait="${DW_CANCEL_WAIT_SECONDS:-180}"

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

attempt=1
while :; do
  dispatch
  epoch=$(date +%s)
  if ! run_id=$(wait_for_run "$((epoch - 30))"); then
    echo "::error::dispatched $workflow run never appeared (no workflow_dispatch run${title:+ titled \"$title\"} in the trailing window after $((appear_attempts * appear_poll))s)" >&2
    exit 1
  fi
  echo "watching $workflow run $run_id${title:+ (\"$title\")} — https://github.com/$repo/actions/runs/$run_id"
  if [ -n "$out_run_id" ]; then printf '%s\n' "$run_id" > "$out_run_id"; fi

  started=$(date +%s)
  while :; do
    status=$(gh run view "$run_id" --repo "$repo" --json status,conclusion \
      --jq '.status + "/" + (.conclusion // "-")' 2>/dev/null || echo "error/-")
    if [ "${status%%/*}" = "completed" ]; then break; fi
    if [ $(( $(date +%s) - started )) -gt "$budget" ]; then
      if [ "$attempt" -ge 2 ]; then
        echo "::error::$workflow run $run_id still unfinished after ${budget}s on the SECOND attempt — runner pool suspect (issue #344); https://github.com/$repo/actions/runs/$run_id" >&2
        exit 1
      fi
      echo "::warning::$workflow run $run_id unfinished after ${budget}s — cancelling and re-dispatching once (issue #344 self-heal); https://github.com/$repo/actions/runs/$run_id"
      gh run cancel "$run_id" --repo "$repo" \
        || echo "::warning::cancel of run $run_id failed (already gone?)"
      # Bounded wait for the cancel to land — a wedged worker may never
      # process it, so never block the re-dispatch on it.
      cancel_deadline=$(( $(date +%s) + cancel_wait ))
      while [ "$(date +%s)" -lt "$cancel_deadline" ]; do
        s=$(gh run view "$run_id" --repo "$repo" --json status --jq '.status' 2>/dev/null || echo unknown)
        [ "$s" = "completed" ] && break
        sleep "$poll"
      done
      attempt=$((attempt + 1))
      continue 2
    fi
    sleep "$poll"
  done

  conclusion="${status#*/}"
  echo "$workflow run $run_id conclusion: $conclusion"
  if [ "$conclusion" = "success" ]; then exit 0; fi
  echo "::error::$workflow run $run_id concluded $conclusion — https://github.com/$repo/actions/runs/$run_id" >&2
  exit 1
done
