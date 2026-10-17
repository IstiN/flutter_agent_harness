#!/usr/bin/env bash
# update_git_mirror.sh — resilient local git-mirror update (gh-1644).
#
# Replaces the single-shot inline logic in build-macos.yml / build-mobile.yml
# ("Update local git mirror(s)" steps). The old logic fetched ONCE with
# stderr swallowed (`2>/dev/null`), and on any failure fell through to a
# FULL `git clone --mirror` whose ~1 h transfer died mid-flight on the
# self-hosted runner's flaky link (run 38855793382:
# "error: 2931 bytes of body are still expected", exit 128) — no retry,
# and a killed clone left a partial mirror dir behind.
#
# Contract (asserted by scripts/update_git_mirror_selftest.sh):
#   - fetch retries MIRROR_FETCH_ATTEMPTS times (default 3) with
#     MIRROR_RETRY_SLEEP seconds (default 10) between attempts, stderr
#     visible — the first-failure cause is no longer swallowed;
#   - each attempt aborts on a stalled connection (<1 KB/s for 60 s) so a
#     wedged transfer engages the bounded retries instead of holding the
#     step for an hour;
#   - persistent fetch failure → recreate. The partial dir is removed
#     before EVERY attempt (a killed clone leaves a non-repo dir that
#     would fail the next attempt with "already exists"), and the
#     recreation is a BLOBLESS mirror (`--filter=blob:none` — the gh-1477
#     precedent in this repo): commits/trees only, ~90% less transfer,
#     shrinking the recreate window from ~1 h to minutes. The dependent
#     checkouts use `git clone --reference <mirror> --depth=1` and pull
#     tip blobs from origin, so they never need historical blobs from the
#     mirror. An EXISTING full mirror is untouched — fetches stay cheap;
#     only recreations become blobless;
#   - recreation retries MIRROR_CLONE_ATTEMPTS times (default 3);
#   - every failure path exits nonzero with a ::error annotation and
#     leaves NO partial mirror dir behind.
#
# Usage: update_git_mirror.sh <url> <mirror-path>
# Run from anywhere:  bash scripts/update_git_mirror.sh URL MIRROR
set -euo pipefail

url="${1:?usage: update_git_mirror.sh <url> <mirror-path>}"
mirror="${2:?usage: update_git_mirror.sh <url> <mirror-path>}"

fetch_attempts="${MIRROR_FETCH_ATTEMPTS:-3}"
clone_attempts="${MIRROR_CLONE_ATTEMPTS:-3}"
retry_sleep="${MIRROR_RETRY_SLEEP:-10}"

# Stall guard for http(s) remotes (no-op for file/local remotes): an
# attempt moving <1 KB/s for 60 s is dead — retry instead of hanging.
# The run-38855793382 death was a 62-minute transfer ending in
# "2931 bytes of body are still expected".
STALL_GUARD=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60)

is_repo() { git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }

recreate_mirror() {
  local attempt
  for ((attempt = 1; attempt <= clone_attempts; attempt++)); do
    echo "recreate attempt ${attempt}/${clone_attempts}: $mirror"
    rm -rf "$mirror"
    if git "${STALL_GUARD[@]}" clone --mirror --filter=blob:none "$url" "$mirror"; then
      echo "mirror recreated: $mirror (blobless)"
      return 0
    fi
    echo "git clone --mirror failed (attempt ${attempt}/${clone_attempts})" >&2
    if [ "$attempt" -lt "$clone_attempts" ]; then
      sleep "$retry_sleep"
    fi
  done
  rm -rf "$mirror"   # never leave a partial clone behind
  echo "::error::update_git_mirror: recreating $mirror from $url failed after ${clone_attempts} attempt(s)" >&2
  return 1
}

if [ -d "$mirror" ] && is_repo "$mirror"; then
  for ((attempt = 1; attempt <= fetch_attempts; attempt++)); do
    echo "fetch attempt ${attempt}/${fetch_attempts}: $mirror"
    if git -C "$mirror" "${STALL_GUARD[@]}" fetch origin; then
      echo "mirror updated: $mirror"
      exit 0
    fi
    echo "git fetch failed (attempt ${attempt}/${fetch_attempts})" >&2
    if [ "$attempt" -lt "$fetch_attempts" ]; then
      sleep "$retry_sleep"
    fi
  done
  echo "git fetch failed after ${fetch_attempts} attempt(s) — recreating the mirror" >&2
fi

recreate_mirror
