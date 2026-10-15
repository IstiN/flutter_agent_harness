#!/usr/bin/env bash
# Copyright (c) 2026, the Flutter Agent Harness authors.
# Use of this source code is governed by a MIT license that can be found
# in the LICENSE file.
#
# release_dedupe_selftest.sh — fixture self-test for the gh-1625
# release-dedupe pre-check (scripts/release_dedupe_check.sh, the
# release-dedupe job in ci.yml).
#
# The v* tag push fires the full quality gate; the `release: published`
# event for the same tag used to fire a second identical gate. The check
# must dedupe exactly the fresh-twin case and fail safe everywhere else.
# Proves, on a PATH-stubbed gh (no network, no token):
#   AC1  a recent push run for the tag (ANY status — the stub contract
#        pins that the script passes no --status filter) dedupes: the
#        release twin skips the gate, binaries-attach only;
#   AC2  no recent push run (an old tag's release, or a tag the release
#        created itself — API-created tags fire no push event) does NOT
#        dedupe: the full gate stays the safety net;
#   AC3  non-release arms (push/schedule/workflow_dispatch) short-circuit
#        with NO API call at all;
#   AC5  a failing `gh run list` degrades to dedupe=false with a loud
#        ::warning:: and a zero exit — the gate decides, never the pre-check;
#   RG   the output contract: the output file carries EXACTLY the
#        `dedupe=<bool>` line (annotations go to stdout, never into
#        GITHUB_OUTPUT), and the lookup shape is --workflow ci.yml
#        --branch <tag> --event push.
# Same discipline as sm_merge_guard_selftest.sh (gh-1568, #1100 pattern).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/release_dedupe_check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # check <desc> <condition-exit-code: 0 = pass>
  if [ "$2" = "0" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1"
    fails=$((fails + 1))
  fi
}

# Portable ISO-UTC timestamp <secs> ago (GNU date on CI; BSD date locally).
iso_ago() {
  if date -u -d "-$1 seconds" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    date -u -d "-$1 seconds" '+%Y-%m-%dT%H:%M:%SZ'
  else
    date -u -j -v -"$1"S '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

# Stub `gh`: serves the GH_STUB_FIXTURE JSON file as the `gh run list`
# answer (unless GH_STUB_FAIL is set — then it fails like a red API) and
# records every invocation to GH_CALL_LOG. Emulates the ONE jq projection
# the check uses (`--jq '.[].createdAt'` — one timestamp per line), the
# same faithful-stub discipline as flake_watch_selftest.sh's search quirk.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${GH_CALL_LOG:?GH_CALL_LOG required}"
if [ -n "${GH_STUB_FAIL:-}" ]; then
  echo "gh: The deployment API is experiencing problems (stub)" >&2
  exit 1
fi
fixture="${GH_STUB_FIXTURE:?GH_STUB_FIXTURE required}"
if printf '%s' "$*" | grep -q -- '--jq .\[\].createdAt'; then
  grep -o '"createdAt":"[^"]*"' "$fixture" |
    sed 's/"createdAt":"//; s/"$//'
else
  cat "$fixture"
fi
STUB
chmod +x "$TMP/bin/gh"

RC=0
# run_check <event> <tag> <case-name> — runs the REAL check script against
# the stub with EVENT_NAME/GITHUB_REF_NAME set; the `dedupe=` line lands in
# $TMP/out.<case>, everything the script prints lands in
# $TMP/stdout.<case>, the stub's call log in $TMP/calls.log (fresh per
# case). The script's exit code is left in $RC.
run_check() {
  : > "$TMP/out.$3"
  : > "$TMP/stdout.$3"
  : > "$TMP/calls.log"
  EVENT_NAME="$1" GITHUB_REF_NAME="$2" GH_CALL_LOG="$TMP/calls.log" \
    PATH="$TMP/bin:$PATH" \
    bash "$CHECK" "$TMP/out.$3" >"$TMP/stdout.$3" 2>&1
  RC=$?
}

fixture() { # fixture <case-name> <created-at rows...> — writes the
  # `gh run list --json createdAt` answer shape and prints its path.
  local name="$1"
  shift
  {
    printf '['
    local sep="" row
    for row in "$@"; do
      printf '%s{"createdAt":"%s"}' "$sep" "$row"
      sep=', '
    done
    printf ']\n'
  } > "$TMP/fx.$name"
  printf '%s' "$TMP/fx.$name"
}

# ── AC1: a fresh push twin dedupes the release twin ─────────────────────
GH_STUB_FIXTURE="$(fixture recent "$(iso_ago 60)")" run_check release vTest.0 fresh
check 'AC1: recent push run → dedupe=true' \
  "$(grep -qx 'dedupe=true' "$TMP/out.fresh"; echo $?)"
check 'AC1: the script exits 0 (the short-circuit is green, never red)' \
  "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
check 'RG: the lookup filters this workflow (--workflow ci.yml)' \
  "$(grep -q -- '--workflow ci.yml' "$TMP/calls.log"; echo $?)"
check 'RG: the lookup keys on the tag ref (--branch <tag>)' \
  "$(grep -q -- '--branch vTest.0' "$TMP/calls.log"; echo $?)"
check 'RG: the lookup filters the push event (--event push)' \
  "$(grep -q -- '--event push' "$TMP/calls.log"; echo $?)"
check 'RG: no --status filter — ANY status dedupes (the push twin is still in_progress in the hot path)' \
  "$(grep -q -- '--status' "$TMP/calls.log" && echo 1 || echo 0)"
check 'RG: the output file carries EXACTLY the dedupe line (annotations never pollute GITHUB_OUTPUT)' \
  "$(printf 'dedupe=true\n' | cmp -s - "$TMP/out.fresh"; echo $?)"

# ── AC1: 2+ runs, one stale + one recent — the recent one still dedupes ──
GH_STUB_FIXTURE="$(fixture mixed "$(iso_ago 100000)" "$(iso_ago 120)")" \
  run_check release vTest.0 mixed
check 'AC1: a recent run among stale ones → dedupe=true' \
  "$(grep -qx 'dedupe=true' "$TMP/out.mixed"; echo $?)"

# ── AC1/AC2: the window boundary (default 6h) is honored ────────────────
GH_STUB_FIXTURE="$(fixture edge-in "$(iso_ago 21570)")" \
  DEDUPE_WINDOW_SECS=21600 run_check release vTest.0 edge-in
check 'AC1: a run seconds inside the window still dedupes' \
  "$(grep -qx 'dedupe=true' "$TMP/out.edge-in"; echo $?)"
GH_STUB_FIXTURE="$(fixture edge-out "$(iso_ago 21630)")" \
  DEDUPE_WINDOW_SECS=21600 run_check release vTest.0 edge-out
check 'AC2: a run just past the window does NOT dedupe' \
  "$(grep -qx 'dedupe=false' "$TMP/out.edge-out"; echo $?)"

# ── AC2: the old-tag safety net ──────────────────────────────────────────
GH_STUB_FIXTURE="$(fixture old "$(iso_ago 100000)")" run_check release vOld.0 old
check 'AC2: only stale push runs (old-tag release) → dedupe=false, the full gate runs' \
  "$(grep -qx 'dedupe=false' "$TMP/out.old"; echo $?)"

printf '[]\n' > "$TMP/fx.empty"
GH_STUB_FIXTURE="$TMP/fx.empty" run_check release vNew.0 empty
check 'AC2: no push run at all (release-created tag) → dedupe=false' \
  "$(grep -qx 'dedupe=false' "$TMP/out.empty"; echo $?)"

# ── AC3: non-release arms never call the API ─────────────────────────────
for ev in push schedule workflow_dispatch; do
  GH_STUB_FIXTURE="$TMP/fx.empty" run_check "$ev" vTest.0 "arm-$ev"
  check "AC3: $ev arm → dedupe=false" \
    "$(grep -qx 'dedupe=false' "$TMP/out.arm-$ev"; echo $?)"
  check "AC3: $ev arm makes NO gh call" \
    "$([ -s "$TMP/calls.log" ] && echo 1 || echo 0)"
  check "AC3: $ev arm exits 0" \
    "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
done

# ── AC5: an API failure fails safe to the full gate ──────────────────────
GH_STUB_FAIL=1 GH_STUB_FIXTURE="$TMP/fx.empty" run_check release vTest.0 apierr
check 'AC5: gh run list failure → dedupe=false (the gate decides)' \
  "$(grep -qx 'dedupe=false' "$TMP/out.apierr"; echo $?)"
check 'AC5: the failure warns loudly (::warning::)' \
  "$(grep -q '::warning::' "$TMP/stdout.apierr"; echo $?)"
check 'AC5: the script still exits 0 (the pre-check never reddens the run)' \
  "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"

echo
if [ "$fails" -eq 0 ]; then
  echo '✅ release-dedupe self-test green'
  exit 0
fi
echo "❌ release-dedupe self-test: $fails failing assertion(s)"
exit 1
