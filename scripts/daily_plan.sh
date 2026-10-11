#!/usr/bin/env bash
# Daily auto-publish plan gate (issue #161): change detection + version
# derivation for the daily-publish.yml «Detect main movement and derive
# versions» step. Extracted verbatim from the inline step so the gate is
# shell-harness testable (test/release_flow_race_test.dart), plus the
# gh-1192 release-unresolved re-arm.
#
# Baseline = last green run that exercised ALL legs. A single-leg green
# dispatch (legs=pubdev inject smoke etc.) must NOT advance the baseline —
# otherwise the next scheduled run would skip the legs that never ran for
# that sha.
#
# gh-1192 (review thread 1): a release-in-flight pubdev leg exits 0, so
# that daily goes GREEN — and becomes the new baseline AT THE BUMP'S sha.
# If main then stays quiet (quiet evening/weekend — pushes are the only
# thing that moves main here), every later daily would skip all legs:
# AC1's «the next scheduled daily re-verifies» and the failed-run
# `gh run rerun --failed` recovery would stall until an unrelated push.
# So when the baseline says skip, the gate still forces the legs while
# the LATEST TAG's version is NOT served by pub.dev (gh-1522: the committed
# pubspec is the 0.0.0-dev placeholder; the tag is the version) — the
# release is unresolved and verification/recovery must re-arm, independent
# of the baseline. A failed pub.dev read fails OPEN (the baseline decision
# stands): an API outage must not force daily legs on its own.
set -euo pipefail

repo="${GITHUB_REPOSITORY}"
out="${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"

last_green=$(gh run list --repo "$repo" --workflow daily-publish.yml \
  --branch main --status success --limit 15 \
  --json headSha,event,displayTitle \
  --jq '[.[] | select(.event == "schedule" or (.event == "workflow_dispatch" and (.displayTitle | contains("(all)"))))][0].headSha // empty')
head=$(git rev-parse origin/main)
echo "last green daily: ${last_green:-<none>} — main: $head"

changed=true
if [ "$last_green" = "$head" ] && [ "${FORCE:-}" != "true" ]; then
  changed=false
  echo "::notice::main has not moved since the last green daily — all legs skip (green-neutral, #159)"
fi

if [ "$changed" = "false" ]; then
  # gh-1192 re-arm (gh-1522 rework): the baseline skip is only safe when
  # nothing is pending. The version under test is the LATEST TAG (the
  # committed pubspec is the 0.0.0-dev placeholder — the tag is the single
  # source of truth); local tags are correct here because the plan job
  # checks out fetch-depth 0. No tag → nothing has been released yet →
  # main movement is the only re-arm trigger (a first release IS main
  # movement, so the baseline cannot skip it).
  latest_tag=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
  version="${latest_tag#v}"
  served=""
  read_ok=false
  if [ -n "$latest_tag" ]; then
    if served=$(curl -fsS --retry 3 \
        https://pub.dev/api/packages/flutter_agent_harness 2>/dev/null \
        | jq -r '.latest.version' 2>/dev/null) && [ -n "$served" ]; then
      read_ok=true
    fi
  fi
  if [ "$read_ok" = "true" ] && [ "$served" != "$version" ]; then
    changed=true
    echo "::notice::pub.dev serves $served, latest tag wants $version — release unresolved, re-arming the legs (gh-1192: a release-in-flight green must not become a skip baseline)"
  elif [ "$read_ok" = "false" ] && [ -n "$latest_tag" ]; then
    # Fail OPEN: the baseline decision stands. An API outage must not force
    # daily legs by itself — the next daily re-reads.
    echo "::warning::pub.dev API read failed — the release-unresolved re-arm (gh-1192) cannot run; keeping the baseline decision"
  fi
fi
echo "changed=$changed" >> "$out"

if [ -z "${latest_tag:-}" ]; then
  latest_tag=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
fi
next_tag=v0.1.0
if [ -n "$latest_tag" ]; then
  IFS='.' read -r major minor patch <<< "${latest_tag#v}"
  next_tag="v${major}.${minor}.$((patch + 1))"
fi
{
  echo "latest_tag=${latest_tag:-none}"
  echo "next_tag=$next_tag"
  # gh-1522: kept key name (report consumers read it) — the value is the
  # latest TAG version, not a file read.
  echo "pubspec_version=${latest_tag#v}"
} >> "$out"
