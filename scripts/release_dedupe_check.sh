#!/usr/bin/env bash
# Copyright (c) 2026, the Flutter Agent Harness authors.
# Use of this source code is governed by a MIT license that can be found
# in the LICENSE file.
#
# release_dedupe_check.sh — the gh-1625 release-dedupe pre-check, run by
# the `release-dedupe` job of .github/workflows/ci.yml.
#
# The v* tag push fires the full quality gate by design (the release
# pipeline keys on the tag; the gate runs BEFORE anything publishes);
# the `release: published` event for the SAME tag fires a second,
# identical gate — observed on v1.0.580 (push run 38687023638 in_progress,
# release run 38687023803 pending behind it on the shared ci-<ref>
# concurrency group): doubled release wall time. This check decides
# whether the release twin may skip the gate:
#
#   release event AND a CI run for the same tag ref from the `push` event
#   exists with conclusion == "success" (FAIL-CLOSED, gh-1625 review: only
#   a GREEN push gate dedupes — behind the shared ci-<ref> concurrency
#   group the push twin is already completed when the release twin's
#   check executes, so any other outcome degrades to the full-gate safety
#   net below instead of letting a red tag ship binaries) created within
#   the last DEDUPE_WINDOW_SECS (default 6h — the auto-release flow cuts
#   the tag and publishes the release seconds apart; the window bounds
#   the stale-republish edge)
#     → dedupe=true: every quality leg ANDs
#       needs.release-dedupe.outputs.dedupe != 'true' into its `if` and
#       skips; the release twin keeps only its release-specific legs —
#       binaries-attach (idempotent --clobber upload, last wins),
#       release-provenance signing and installer smoke; web-spa/publish
#       stay keyed on the quality-gate result and skip with it;
#   anything else (no push run — a release cut on an old tag, or a tag
#   the release created itself: API-created tags fire no push event)
#     → dedupe=false: the release twin runs the full gate exactly as
#       before; that path stays the safety net (gh-1625 AC2).
#
# Fail-safe (gh-1625 AC5): dedupe defaults to false and flips only on a
# successful lookup — an `gh run list` error prints a ::warning:: and
# degrades to the full gate, never to a skipped one. The script never
# exits non-zero: a broken pre-check must not redden the run (same
# contract as gh-1551's release-pending check).
#
# Non-release arms (push/dispatch/schedule) short-circuit BEFORE any API
# call (gh-1625 AC3).
#
# Usage: release_dedupe_check.sh [output-file]   (default $GITHUB_OUTPUT)
# Contract: the output file receives EXACTLY one line `dedupe=<bool>`;
# annotations and logs go to stdout. The step maps the file into the
# job output consumed by every gate leg.
# Self-tested by scripts/release_dedupe_selftest.sh (PATH-stubbed gh);
# the workflow wiring is pinned by test/ci_release_dedupe_guard_test.dart.
set -u

out="${1:-${GITHUB_OUTPUT:?pass an output file or run inside a step}}"
EVENT_NAME="${EVENT_NAME:-}"
tag="${GITHUB_REF_NAME:-}"
window_secs="${DEDUPE_WINDOW_SECS:-21600}" # 6h

# ISO-UTC → epoch seconds: GNU date (Linux CI) and BSD date (local macOS).
iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null && return 0
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}

dedupe=false
if [ "$EVENT_NAME" = "release" ]; then
  # The lookup the ticket prescribes: this workflow's runs for the tag
  # ref from the push event — conclusion-aware and fail-closed (gh-1625
  # review BLOCKING #2): ONLY a `conclusion == "success"` push run
  # dedupes. A failed/cancelled push gate must re-gate here (the twin
  # goes red on the same commit and attaches nothing — the binaries job's
  # own "explicit gate check keeps failed-gate runs from building
  # publishable binaries" invariant), never be waved through. The twins
  # share the ci-<ref> concurrency group with cancel-in-progress:
  # false, so by the time this check executes the push run is completed
  # and its conclusion is terminal — success-only is strictly safe. No
  # --repo flag (gh reads GH_REPO/GITHUB_REPOSITORY on the runner).
  if ! created_list=$(gh run list \
      --workflow ci.yml \
      --branch "$tag" \
      --event push \
      --limit 20 \
      --json createdAt,conclusion,status \
      --jq '.[] | select(.conclusion == "success") | .createdAt' 2>&1); then
    echo "::warning::gh run list failed — fail-safe: the release twin runs the full quality gate (gh-1625 AC5)"
    printf '  %s\n' "$created_list"
  else
    now=$(date -u +%s)
    cutoff=$((now - window_secs))
    recent=""
    while IFS= read -r created; do
      [ -z "$created" ] && continue
      ts=$(iso_to_epoch "$created") || continue
      [ -z "$ts" ] && continue
      if [ "$ts" -ge "$cutoff" ]; then
        recent="$created"
        break
      fi
    done <<EOF
$created_list
EOF
    if [ -n "$recent" ]; then
      echo "::notice::a GREEN push CI run for $tag already gates this tag (created $recent) — the release twin skips every quality leg; binaries-attach, release-provenance and installer-smoke still run (gh-1625)"
      dedupe=true
    else
      echo "no push CI run for $tag within the last ${window_secs}s — the release twin runs the full quality gate (gh-1625 AC2 old-tag safety net)"
    fi
  fi
else
  echo "$EVENT_NAME arm — dedupe applies to release events only (gh-1625 AC3)"
fi

printf 'dedupe=%s\n' "$dedupe" >> "$out"
