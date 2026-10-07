#!/usr/bin/env bash
# Verify pub.dev serves the pubspec version — the daily-publish pubdev leg's
# check (gh-1192). Extracted verbatim from the inline step in
# daily-publish.yml so the classification is shell-harness testable (fake
# gh/curl fixtures, test/release_flow_race_test.dart).
#
# The ONLY publish path is the ci.yml tag job (pub.dev trusted publishing
# accepts OIDC only from tag-push runs — the release-event twin of a tag can
# never publish, #1368). This script VERIFIES pub.dev serves the pubspec
# version and, when behind, recovers by re-running the failed tag-push
# publish run — a rerun keeps the original push-tag event and OIDC claims.
# Unrecoverable states fail loudly and self-file an issue with a
# manual-publish instruction instead of silently hanging.
#
# States (gh-1192; refined by #1368 — the 2026-10-07 false alarm):
#   up-to-date          pub.dev already serves the pubspec version
#   release-in-flight   the publish outcome is NOT yet observable — neutral
#                       skip (no ::error::, no auto-filed issue); the next
#                       scheduled daily re-verifies. Covers:
#                         · the release-tag job has not cut the tag off the
#                           bump yet — at ANY bump age (the old 1h «wedge»
#                           horizon false-alarmed #1368: the verify read
#                           «never triggered» 3 minutes before the tag
#                           landed, off a 10.5h-old bump that self-healed on
#                           the next green main run); the script now WAITS a
#                           bounded window for the tag to appear
#                         · tag exists but its ci.yml run is not visible yet
#                           and the tag is younger than the grace window
#                         · the tag's PUSH ci.yml run is queued/in_progress —
#                           the script waits up to RUN_TERMINAL_WAIT_SECS for
#                           a terminal state first (Never-again: the leg
#                           waits for the publish conclusion, with a
#                           timeout); past the budget the outcome stays
#                           unobserved and the skip stays neutral — runner
#                           starvation may hold a queued run for hours
#                         · the tag is not cut yet but the bump commit is
#                           on main (release-tag pending)
#   recovered           the failed tag-push publish run was re-run and
#                       pub.dev caught up
#   private             publish_to: none — nothing to verify
# Alarms — each error says WHICH state (Never-again #2):
#   «never triggered (no tag and no chore(release) bump on main)»
#   «never triggered (only release-event run(s) …)»  — pub.dev OIDC rejects
#                       release-event tokens, so those runs cannot publish
#   «never triggered (no run registered past the grace window)»
#   «publish did not upload» — the push run went green but pub.dev still
#                       serves the old version
#
# E4: the «re-push the tag» manual fix keeps working — a re-pushed old tag
# has a fresh run the moment it is visible, so the classification reads the
# run, never the stale tag age, and a completed fresh run verifies normally.
#
# E2: only the tag matching the CURRENT pubspec version is evaluated; stale
# older tags are out of scope.
set -euo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
out="${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"
grace="${RELEASE_FLIGHT_GRACE_SECS:-900}" # AC1: «no run at all» window bound
read_sleep="${PUBDEV_READ_SLEEP_SECS:-10}"  # test seam (production: 10s)
poll_sleep="${PUBDEV_POLL_SLEEP_SECS:-20}"  # test seam (production: 20s)
tag_appear_wait="${TAG_APPEAR_WAIT_SECS:-600}"      # wait for a pending tag cut
run_terminal_wait="${RUN_TERMINAL_WAIT_SECS:-1800}" # wait for the tag run to go terminal
max_polls="${PUBDEV_MAX_POLLS:-90}"         # iteration cap (bounds the waits in tests)

emit() { printf '%s\n' "$1" >> "$out"; }

# poll_attempts: iteration count for a bounded wait — a sleep-based budget
# (wait/sleep, capped), or the fixed cap when sleeps are disabled in tests.
poll_attempts() { # $1 = wait seconds
  local a
  if [ "${poll_sleep}" -gt 0 ]; then
    a=$(( $1 / poll_sleep ))
  else
    a="$max_polls"
  fi
  if [ "$a" -gt "$max_polls" ]; then a="$max_polls"; fi
  if [ "$a" -lt 1 ]; then a=1; fi
  echo "$a"
}

pubspec=$(grep '^version:' pubspec.yaml | awk '{print $2}')
emit "pubspec=$pubspec"
emit "published=" # re-exported below after query

if grep -q '^publish_to: *none' pubspec.yaml; then
  emit "status=private"
  echo "::notice::pubspec declares publish_to: none — package is private, nothing to verify on pub.dev"
  exit 0
fi

# pub.dev API reads lag minutes behind a fresh publish (CDN replicas) — a
# single stale read must not send us into recovery. Three spaced reads, take
# the newest by version.
published=""
for attempt in 1 2 3; do
  v=$(curl -fsS --retry 3 \
    https://pub.dev/api/packages/flutter_agent_harness | jq -r '.latest.version')
  published=$(printf '%s\n%s\n' "$published" "$v" | sed '/^$/d' | sort -V | tail -1)
  [ "$attempt" = 3 ] || sleep "$read_sleep"
done
emit "published=$published"
echo "pubspec=$pubspec published=$published"
newest=$(printf '%s\n%s\n' "$pubspec" "$published" | sort -V | tail -1)
if [ "$newest" = "$published" ]; then
  emit "status=up-to-date"
  echo "::notice::pub.dev already serves $published"
  exit 0
fi

# Behind: classify the tag's publish state before reaching for recovery.
tag="v$pubspec"
now=$(date +%s)

in_flight() { # $1 = human reason — the outcome is UNOBSERVED, never an alarm
  emit "status=release-in-flight"
  echo "::notice::skipped: release in flight — $1; the next scheduled daily re-verifies."
  exit 0
}

never_triggered() { # $1 = which state — nothing publishable is in flight
  echo "::error::$tag has no ci.yml run — the tag-publish never triggered ($1). Manual fix: re-push the tag (git push origin $tag --force) or run ci.yml on the tag ref."
  exit 1
}

# The tag's ci.yml runs. The PUSH-event twin is the only publisher (pub.dev
# OIDC accepts push/workflow_dispatch events only, #1368) — classification
# and recovery must use THAT run, never the release twin. One list read,
# filtered locally.
fetch_runs() {
  gh run list --repo "$repo" --workflow ci.yml \
    --branch "$tag" --limit 20 \
    --json databaseId,status,conclusion,event
}
push_run_of() { # $1 = runs JSON array
  jq -c 'map(select(.event == "push")) | .[0] // empty' <<<"$1"
}
any_run_of() { # $1 = runs JSON array
  jq -c '.[0] // empty' <<<"$1"
}

# Tag presence + age. creatordate = the annotated tag's tagger date (the
# moment release-tag cut it); a lightweight tag falls back to its commit date.
# Echoes the age on stdout, nothing when the tag is absent.
read_tag_age() {
  if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    git fetch -q --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
    echo "$(( now - $(git for-each-ref "refs/tags/$tag" --format='%(creatordate:unix)') ))"
  fi
}
tag_age=$(read_tag_age)

if [ -z "$tag_age" ]; then
  # Tag not cut yet. Pending while a release bump exists on main — at ANY
  # age (#1368: a 10.5h-old bump was cut 3 minutes after the old 1h-horizon
  # alarm fired; the ≥1h untagged state is auto-release's own «proceed, the
  # next range absorbs it» self-heal, not a wedged publish). A bounded wait
  # catches the tag that lands minutes later; only a missing bump — nothing
  # in flight at all — is the «never triggered» alarm.
  git fetch -q --depth=300 origin main
  bump=$(git log --format='%H %s' FETCH_HEAD \
    | awk -v want="$tag" 'NF == 3 && $2 == "chore(release):" && $3 == want { print $1; exit }' || true)
  if [ -z "$bump" ]; then
    never_triggered "no tag and no chore(release) bump on main"
  fi
  bump_age=$(( now - $(git log -1 --format=%ct "$bump") ))
  echo "release-tag has not cut $tag yet (bump ${bump_age}s old) — waiting up to ${tag_appear_wait}s for the tag"
  attempts=$(poll_attempts "$tag_appear_wait")
  attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    sleep "$poll_sleep"
    tag_age=$(read_tag_age)
    if [ -n "$tag_age" ]; then break; fi
    attempt=$(( attempt + 1 ))
  done
  if [ -z "$tag_age" ]; then
    in_flight "release-tag has not cut $tag yet (bump ${bump_age}s old, waited ~${tag_appear_wait}s) — publish pending, not failed"
  fi
  echo "::notice::$tag appeared after the wait — continuing with its run"
fi

runs_json=$(fetch_runs)
tag_run=$(push_run_of "$runs_json")
if [ -z "$tag_run" ]; then
  if [ -n "$(any_run_of "$runs_json")" ]; then
    never_triggered "only release-event run(s) exist and pub.dev OIDC accepts push-event runs only"
  fi
  if [ "$tag_age" -lt "$grace" ]; then
    # AC1 — the 2026-10-03 #1189 false positive: between `git push <tag>` and
    # the tag's ci.yml run becoming visible there is a seconds-to-minutes
    # window (tag 05:32, verify 05:35 read «no run», the healthy run
    # completed 05:37). Neutral skip; the next daily re-verifies.
    in_flight "$tag exists (${tag_age}s old < ${grace}s grace) but its ci.yml run is not visible yet"
  fi
  # Review thread 2 (E4 residual): a freshly re-pushed tag takes seconds to
  # register in the API — an operator re-pushing while this leg sits between
  # its `git ls-remote` and the read above must not trip «never triggered»
  # once. One spaced re-read; alarm only if it is empty too.
  sleep "$read_sleep"
  runs_json=$(fetch_runs)
  tag_run=$(push_run_of "$runs_json")
  if [ -n "$tag_run" ]; then
    echo "::notice::$tag's ci run registered between the reads — continuing with it"
  elif [ -n "$(any_run_of "$runs_json")" ]; then
    never_triggered "only release-event run(s) exist and pub.dev OIDC accepts push-event runs only"
  fi
fi
if [ -z "$tag_run" ]; then
  # AC2 — past the grace window with no run at all (both reads empty):
  # genuinely never triggered (e.g. a GITHUB_TOKEN push cannot cascade).
  never_triggered "no run registered past the ${grace}s grace window"
fi
run_id=$(jq -r '.databaseId' <<<"$tag_run")
emit "run_url=https://github.com/$repo/actions/runs/$run_id"

status=$(jq -r '.status' <<<"$tag_run")
if [ "$status" != "completed" ]; then
  # Never-again #1 (#1368): the leg WAITS for the tag run to reach a terminal
  # state (bounded) before classifying, instead of skipping on the first
  # pending read. Once the budget lapses the outcome is still unobserved —
  # stay neutral (runner starvation can hold a queued run for hours; the
  # next daily re-verifies).
  echo "tag run $run_id is $status — waiting up to ${run_terminal_wait}s for a terminal state"
  attempts=$(poll_attempts "$run_terminal_wait")
  attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    sleep "$poll_sleep"
    status=$(gh run view "$run_id" --repo "$repo" --json status --jq .status)
    [ "$status" = "completed" ] && break
    attempt=$(( attempt + 1 ))
  done
  if [ "$status" != "completed" ]; then
    in_flight "tag run $run_id is still $status after ~${run_terminal_wait}s — publish outcome unobserved, not failed"
  fi
fi
conclusion=$(gh run view "$run_id" --repo "$repo" --json conclusion --jq .conclusion)

if [ "$conclusion" = "success" ]; then
  # Push run went green but pub.dev still serves $published — not
  # recoverable by rerunning.
  echo "::error::tag run for $tag succeeded but pub.dev still serves $published — publish did not upload. Manual publish needed (see issue)."
  exit 1
fi

echo "tag run $run_id concluded $conclusion — re-running its failed jobs (keeps the original tag-push event/OIDC claims)"
gh run rerun "$run_id" --repo "$repo" --failed
sleep "$poll_sleep"
gh run watch "$run_id" --repo "$repo" --exit-status --interval 60 >/dev/null 2>&1 || true
conclusion=$(gh run view "$run_id" --repo "$repo" --json conclusion --jq .conclusion)
if [ "$conclusion" != "success" ]; then
  echo "::error::rerun of the $tag publish run failed again ($conclusion) — see https://github.com/$repo/actions/runs/$run_id"
fi

# Poll until the API catches up. The rerun's publish job already
# verified 'pub.dev verified: flutter_agent_harness <v>' itself;
# a single read 52s later hit a stale replica and false-errored
# the whole leg (2026-09-28 daily run) — match the publish job's
# poll approach: up to 10 min.
published2=""
for attempt in $(seq 1 30); do
  published2=$(curl -fsS --retry 3 \
    https://pub.dev/api/packages/flutter_agent_harness | jq -r '.latest.version')
  [ "$published2" = "$pubspec" ] && break
  echo "pub.dev API still serves '$published2' (want $pubspec, attempt $attempt/30)"
  sleep "$poll_sleep"
done
emit "published=$published2"
if [ "$published2" != "$pubspec" ]; then
  echo "::error::rerun went green but the pub.dev API keeps serving $published2 after 10 min, not $pubspec — publish did not upload; manual publish needed"
  exit 1
fi
emit "status=recovered"
echo "::notice::recovered — re-ran the $tag publish run, pub.dev now serves $pubspec"