#!/bin/bash
# gh-1866 — the single allowed writer of the per-user macOS keychain
# search list.
#
# The fa-m5 pool is ONE host under ONE user account with several runner
# registrations (fa-m5-1/2/3), and the daily testflight (build-mobile
# iOS) and cli (build-macos) legs dispatch CONCURRENTLY by design (#359).
# Every signing job used to publish its temporary keychain with
#
#   security list-keychains -d user -s <job-keychain> ~/Library/Keychains/login.keychain-db
#
# which REPLACES the whole per-user list. On 2026-10-25 (runs 40165498619
# / 40165497544) the concurrent iOS job replaced the list 75 s after the
# build-macos arm64 import, evicting build-arm64.keychain; the release
# build's first codesign 10 minutes later died with
# "No certificate for team 'YP9HC3USZ3' matching ... found" even though
# the certificate was imported, on disk, and unlocked (gh-1852's
# max-parallel: 1 fix covers only build-macos's own matrix).
#
# This helper makes the write ADDITIVE and SELF-VERIFYING:
#   1. read the CURRENT search list back,
#   2. union it with {requested keychain, login.keychain-db} (deduped) —
#      never dropping another concurrent job's entry,
#   3. write the union back,
#   4. re-read and confirm the requested keychain SURVIVED the write; on
#      eviction (an external fixed-list writer) re-add, bounded at 5
#      attempts. Two writers both using this helper converge because
#      every pass preserves the other's entries.
#
# Usage: keychain_searchlist_add.sh <keychain-db-path>
#   The path is the keychain FILE (e.g. "$HOME/Library/Keychains/
#   build-arm64.keychain-db"); it must already exist (create-keychain /
#   import happen in the calling workflow step).
#
# Assumption (same as the workflows it serves): keychain paths contain
# no spaces, so the write can rely on shell word-splitting of the
# de-quoted path list.
set -euo pipefail

KC="${1:?usage: keychain_searchlist_add.sh <keychain-db-path>}"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

list_user_keychains() {
  # One absolute path per line: security quotes paths and pads them with
  # leading whitespace; strip quotes/spaces and drop blank lines.
  security list-keychains -d user | tr -d ' "' | sed '/^$/d'
}

for attempt in 1 2 3 4 5; do
  TMP_LIST="$(mktemp "${TMPDIR:-/tmp}/kc-search-list.XXXXXX")"
  {
    list_user_keychains
    printf '%s\n' "$KC" "$LOGIN_KC"
  } | awk '!seen[$0]++' > "$TMP_LIST"
  # shellcheck disable=SC2046
  if ! security list-keychains -d user -s $(cat "$TMP_LIST"); then
    # A failed WRITE (transient `security` error, keychain momentarily
    # unavailable) is treated like an eviction: spend one of the
    # bounded attempts on it instead of dying under `set -e` with
    # `security`'s raw exit code and no log annotation (gh-1866).
    rm -f "$TMP_LIST"
    echo "keychain search list: write failed — will re-read and retry (attempt $attempt/5)" >&2
    sleep "${KSLA_RETRY_DELAY:-$((attempt * 2))}"
    continue
  fi
  rm -f "$TMP_LIST"

  if list_user_keychains | grep -qFx -- "$KC"; then
    echo "keychain search list: $KC present (attempt $attempt)"
    exit 0
  fi
  echo "keychain search list: $KC evicted by a concurrent writer — re-adding (attempt $attempt/5)" >&2
  sleep "${KSLA_RETRY_DELAY:-$((attempt * 2))}"
done

echo "::error::$KC could not be kept in the user keychain search list after 5 attempts — a concurrent job keeps replacing the list, or the write keeps failing (gh-1866)" >&2
exit 1
