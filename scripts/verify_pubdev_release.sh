#!/usr/bin/env bash
# Verify pub.dev serves the pubspec version — the daily-publish pubdev leg's
# check (gh-1192). Extracted verbatim from the inline step in
# daily-publish.yml so the classification is shell-harness testable (fake
# gh/curl fixtures, test/release_flow_race_test.dart).
#
# The ONLY publish path is the ci.yml tag job (pub.dev trusted publishing
# accepts OIDC only from tag-push runs). This script VERIFIES pub.dev serves
# the pubspec version and, when behind, recovers by re-running the failed
# tag-push publish run — a rerun keeps the original push-tag event and OIDC
# claims. Unrecoverable states fail loudly and self-file an issue with a
# manual-publish instruction instead of silently hanging.
#
# States (gh-1192 — the 2026-10-03 #1189 false alarm):
#   up-to-date          pub.dev already serves the pubspec version
#   release-in-flight   the tag-publish is still EXECUTING — neutral skip
#                       (no ::error::, no auto-filed issue); the next
#                       scheduled daily re-verifies. Covers:
#                         · tag exists but its ci.yml run is not visible yet
#                           and the tag is younger than the grace window
#                         · the tag's ci.yml run is queued/in_progress — run
#                           STATUS governs once the run exists, at any age
#                           (runner starvation may hold a queued run far past
#                           the grace window; the grace bounds ONLY the
#                           «no run at all» window)
#                         · the tag is not cut yet but the bump commit is
#                           fresh on main (the release-tag job is still
#                           pending — auto_release.sh uses the same 1h wedge
#                           horizon before it declares release-tag wedged)
#   recovered           the failed tag-publish run was re-run and pub.dev
#                       caught up
#   private             publish_to: none — nothing to verify
# Anything past those windows keeps the pre-existing alarms unchanged: a tag
# with no ci run after the grace, or a green tag run whose publish did not
# upload, still error (and the report job self-files).
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
tag_cut_grace="${TAG_CUT_GRACE_SECS:-3600}" # release-tag wedge horizon (matches auto_release.sh)
read_sleep="${PUBDEV_READ_SLEEP_SECS:-10}"  # test seam (production: 10s)
poll_sleep="${PUBDEV_POLL_SLEEP_SECS:-20}"  # test seam (production: 20s)

emit() { printf '%s\n' "$1" >> "$out"; }

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

in_flight() { # $1 = human reason
  emit "status=release-in-flight"
  echo "::notice::skipped: release in flight — $1; the next scheduled daily re-verifies."
  exit 0
}

# Tag presence + age. creatordate = the annotated tag's tagger date (the
# moment release-tag cut it); a lightweight tag falls back to its commit date.
tag_age=""
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  git fetch -q --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
  tag_age=$(( now - $(git for-each-ref "refs/tags/$tag" --format='%(creatordate:unix)') ))
fi

if [ -z "$tag_age" ]; then
  # Tag not cut yet. In flight ONLY while the bump commit is fresh on main:
  # an old untagged bump means release-tag wedged and MUST alarm — otherwise
  # the next bump silently absorbs a never-published release.
  # --depth=300 deepens past the shallow boundary a fetch-depth:1 checkout
  # carries — the buried-bump search below must see ~1h of history even on
  # busy mornings (the horizon matches auto_release.sh's wedge threshold).
  # Subject-exact scan: --grep would also match commit BODIES (a bump revert
  # quotes the old subject) and must never shadow the real bump.
  git fetch -q --depth=300 origin main
  bump=$(git log --format='%H %s' FETCH_HEAD \
    | awk -v want="$tag" 'NF == 3 && $2 == "chore(release):" && $3 == want { print $1; exit }' || true)
  if [ -n "$bump" ]; then
    bump_age=$(( now - $(git log -1 --format=%ct "$bump") ))
    if [ "$bump_age" -lt "$tag_cut_grace" ]; then
      in_flight "$tag not cut yet and the bump is ${bump_age}s old (< ${tag_cut_grace}s) — release-tag job pending"
    fi
  fi
  echo "::error::$tag has no ci.yml run — the tag-publish never triggered. Manual fix: re-push the tag (git push origin $tag --force) or run ci.yml on the tag ref."
  exit 1
fi

tag_run=$(gh run list --repo "$repo" --workflow ci.yml \
  --branch "$tag" --limit 1 \
  --json databaseId,status,conclusion --jq '.[0] // empty')
if [ -z "$tag_run" ]; then
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
  tag_run=$(gh run list --repo "$repo" --workflow ci.yml \
    --branch "$tag" --limit 1 \
    --json databaseId,status,conclusion --jq '.[0] // empty')
  if [ -n "$tag_run" ]; then
    echo "::notice::$tag's ci run registered between the reads — continuing with it"
  fi
fi
if [ -z "$tag_run" ]; then
  # AC2 — past the grace window with no run at all (both reads empty):
  # genuinely never triggered (e.g. a GITHUB_TOKEN push cannot cascade).
  # Alarm unchanged.
  echo "::error::$tag has no ci.yml run — the tag-publish never triggered. Manual fix: re-push the tag (git push origin $tag --force) or run ci.yml on the tag ref."
  exit 1
fi
run_id=$(jq -r '.databaseId' <<<"$tag_run")
emit "run_url=https://github.com/$repo/actions/runs/$run_id"

status=$(jq -r '.status' <<<"$tag_run")
if [ "$status" != "completed" ]; then
  # E1 — once the run EXISTS its status governs, at any tag age: queued or
  # in_progress means the publish is still executing (runner starvation can
  # hold a queued run for hours). Skip, never alarm, never wait — the next
  # daily re-verifies.
  in_flight "tag run $run_id is $status — the tag-publish is still executing"
fi
conclusion=$(gh run view "$run_id" --repo "$repo" --json conclusion --jq .conclusion)

if [ "$conclusion" = "success" ]; then
  # Publish job went green but pub.dev still serves $published —
  # not recoverable by rerunning (e.g. publish skipped by a gate).
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
