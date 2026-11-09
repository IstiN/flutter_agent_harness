#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  gh-2075 — seed_sqlite3_native_assets.sh self-test                         ║
# ║  The contract closes the run-42566734746 incident: the package:sqlite3    ║
# ║  native-assets hook downloads its prebuilt libsqlite3 dylib with ONE      ║
# ║  un-retried GET at BUILD time, and every macOS release job in the cli     ║
# ║  leg died on that request in the same window (hosted CLI: 504 Gateway     ║
# ║  Time-out → exit 255; self-hosted app legs: a proxy error page served    ║
# ║  with HTTP 200 — identical wrong sha256 bef140a1a… for BOTH distinct     ║
# ║  arch assets — caught by the hook's digest pin ~20 min into each build). ║
# ║  Scenarios (fixture sqlite3 package + fault-injected `curl` shim on      ║
# ║  PATH, file:// mirror — hermetic, no real egress):                        ║
# ║    T1 FRESH    a clean workspace seeds the pinned dylibs into the hook   ║
# ║                cache (download-<hash8>/libsqlite3.dylib, sha-pinned)     ║
# ║    T2 RETRY    THE INCIDENT: curl fails transiently (504-class) twice,   ║
# ║                then succeeds — the bounded retry must recover in one     ║
# ║                script run (the legacy hook died on the FIRST failure)    ║
# ║    T3 GARBAGE  the bef140a1a signature: HTTP 200 with a wrong body —     ║
# ║                the digest check must PURGE, never install, and fail      ║
# ║                loudly with a named ::error::                             ║
# ║    T4 WARM     a hash-valid cached file skips the download entirely      ║
# ║                (zero curl invocations — warm release+no-sandbox builds   ║
# ║                must not re-expose to the egress flake)                   ║
# ║    T5 MISSING  a workspace without sqlite3 (or without package           ║
# ║                resolution) fails LOUD before any download attempt        ║
# ║    T6 EXHAUST  persistent failures → nonzero exit after exactly          ║
# ║                SQLITE3_SEED_ATTEMPTS logged attempts, ::error:: marker   ║
# ║    T7 STALE    a wrong-bytes cache file (stale/corrupt) is NOT trusted   ║
# ║                — it is replaced by a fresh pinned download               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Run from anywhere:  bash scripts/seed_sqlite3_native_assets_selftest.sh

set -u
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root, any cwd

SCRIPT="scripts/seed_sqlite3_native_assets.sh"
[ -f "$SCRIPT" ] || { echo "❌ $SCRIPT missing — run this selftest from the repo root" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Resolve the REAL curl binary — NOT a PATH wrapper (the
# update_git_mirror_selftest.sh pattern; this runner may carry PATH
# shims, and the shim must be able to delegate without ping-ponging).
REAL_CURL="$(command -v -p curl 2>/dev/null || true)"
if [ -z "$REAL_CURL" ]; then REAL_CURL="$(command -v curl)"; fi
REAL_PYTHON3="$(command -v -p python3 2>/dev/null || true)"
if [ -z "$REAL_PYTHON3" ]; then REAL_PYTHON3="$(command -v python3)"; fi

pass=0
fail=0

# ── fixture: a fake installed sqlite3 package with its own pinned hashes ────
PKG="$WORK/sqlite3-3.9.1"
mkdir -p "$PKG/lib/src/hook"
printf 'arm64-fixture-dylib-bytes-0123456789abcdef' > "$WORK/arm64.dylib"
printf 'x64-fixture-dylib-bytes-fedcba9876543210' > "$WORK/x64.dylib"
ARM64_HASH="$("$REAL_PYTHON3" -c "import hashlib;print(hashlib.sha256(open('$WORK/arm64.dylib','rb').read()).hexdigest())")"
X64_HASH="$("$REAL_PYTHON3" -c "import hashlib;print(hashlib.sha256(open('$WORK/x64.dylib','rb').read()).hexdigest())")"
cat > "$PKG/lib/src/hook/asset_hashes.dart" <<EOF
const String? releaseTag = 'sqlite3-selftest-1.0.0';

final Map<String, String> assetNameToSha256Hash = {
  'libsqlcipher.arm64.macos.dylib': 'not-parsed-decoy',
  'libsqlite3.arm64.macos.dylib': '$ARM64_HASH',
  'libsqlite3.x64.macos.dylib': '$X64_HASH',
};
EOF

make_ws() { # $1 = ws dir; $2 = include sqlite3? (yes|no)
  mkdir -p "$1/.dart_tool"
  if [ "$2" = yes ]; then
    cat > "$1/.dart_tool/package_config.json" <<EOF
{
  "configVersion": 2,
  "packages": [
    {"name": "some_other_pkg", "rootUri": "file:///nonexistent/pkg", "packageUri": "lib/", "languageVersion": "3.0"},
    {"name": "sqlite3", "rootUri": "file://$PKG", "packageUri": "lib/", "languageVersion": "3.0"}
  ]
}
EOF
  else
    cat > "$1/.dart_tool/package_config.json" <<EOF
{
  "configVersion": 2,
  "packages": [
    {"name": "only_other_pkg", "rootUri": "file:///nonexistent/pkg", "packageUri": "lib/", "languageVersion": "3.0"}
  ]
}
EOF
  fi
}

# ── fault-injected curl shim ────────────────────────────────────────────────
SHIM="$WORK/shim"
mkdir -p "$SHIM"
cat > "$SHIM/curl" <<EOF
#!/usr/bin/env bash
# gh-2075 selftest shim: fault matrix via files/env, then delegate to the real curl.
COUNT_FILE="$SHIM/count"
FAIL_FILE="$SHIM/fail-until"
echo 1 >> "\$COUNT_FILE"
# T2/T6 RETRY/EXHAUST: transient failure injection (504-class) via a
# file-backed countdown — each curl call is a fresh process, so env vars
# cannot carry the counter across invocations.
if [ -f "\$FAIL_FILE" ]; then
  LEFT=\$(cat "\$FAIL_FILE")
  if [ "\$LEFT" -gt 0 ]; then
    echo \$((LEFT - 1)) > "\$FAIL_FILE"
    echo "curl: (7) seed-shim: injected transient connection failure" >&2
    exit 7
  fi
fi
# T3 GARBAGE: simulate the HTTP-200-with-error-page signature (the
# bef140a1a incident) — write wrong bytes to the -o target, exit 0.
if [ -n "\${SEED_SHIM_SERVE_GARBAGE:-}" ]; then
  OUT=""
  prev=""
  for arg in "\$@"; do
    if [ "\$prev" = "-o" ]; then OUT="\$arg"; fi
    prev="\$arg"
  done
  [ -n "\$OUT" ] && printf 'MIDDLEBOX ERROR PAGE — not a dylib' > "\$OUT"
  exit 0
fi
exec "$REAL_CURL" "\$@"
EOF
chmod +x "$SHIM/curl"

run_seed() { # $1 = ws dir; rest = extra env assignments (VAL=KEY form)
  local ws="$1"; shift
  env \
    PATH="$SHIM:$PATH" \
    SQLITE3_RELEASE_MIRROR="file://$WORK/mirror" \
    "$@" \
    bash "$SCRIPT" "$ws" macos arm64 x64
}

# File:// mirror tree the REAL curl serves — layout mirrors the upstream
# release: <mirror>/<release tag>/<asset name>.
MIRROR="$WORK/mirror/sqlite3-selftest-1.0.0"
mkdir -p "$MIRROR"
cp "$WORK/arm64.dylib" "$MIRROR/libsqlite3.arm64.macos.dylib"
cp "$WORK/x64.dylib" "$MIRROR/libsqlite3.x64.macos.dylib"

check() { # check <name> <expected 0|nonzero> <logfile> <grep-pattern>
  local name="$1" expect_fail="$2" log="$3" pattern="$4"
  local code="${5:-}"
  if [ "$expect_fail" = 0 ] && [ "$code" = 0 ] && grep -q "$pattern" "$log"; then
    echo "PASS T$name ($pattern)"; pass=$((pass + 1))
  elif [ "$expect_fail" != 0 ] && [ "$code" != 0 ] && grep -q "$pattern" "$log"; then
    echo "PASS T$name ($pattern)"; pass=$((pass + 1))
  else
    echo "FAIL T$name — exit=$code, log:"; sed 's/^/    /' "$log" | tail -8
    fail=$((fail + 1))
  fi
}

cache_path() { # $1 = ws, $2 = hash — the hook's stable shared cache path
  echo "$1/.dart_tool/hooks_runner/shared/sqlite3/build/download-${2:0:8}/libsqlite3.dylib"
}

# ── T1 FRESH ────────────────────────────────────────────────────────────────
WS="$WORK/ws-t1"; make_ws "$WS" yes
: > "$SHIM/count"
LOG="$WORK/t1.log"; run_seed "$WS" >"$LOG" 2>&1; code=$?
check 1 0 "$LOG" "installed libsqlite3.arm64.macos.dylib" "$code"
if [ -f "$(cache_path "$WS" "$ARM64_HASH")" ] \
   && [ "$( (command -v shasum >/dev/null 2>&1 && shasum -a 256 "$(cache_path "$WS" "$ARM64_HASH")" || sha256sum "$(cache_path "$WS" "$ARM64_HASH")") | cut -d' ' -f1)" = "$ARM64_HASH" ] \
   && [ -f "$(cache_path "$WS" "$X64_HASH")" ]; then
  echo "PASS T1 (cache files at download-<hash8>/libsqlite3.dylib, sha-valid)"; pass=$((pass + 1))
else
  echo "FAIL T1 — cache files missing or wrong bytes"; fail=$((fail + 1))
fi

# ── T2 RETRY — the incident: transient 504-class failures, then success ─────
WS="$WORK/ws-t2"; make_ws "$WS" yes
: > "$SHIM/count"; printf '2' > "$SHIM/fail-until"
LOG="$WORK/t2.log"; run_seed "$WS" >"$LOG" 2>&1; code=$?
check 2 0 "$LOG" "installed libsqlite3.arm64.macos.dylib" "$code"
if grep -q "attempt 1/4 failed" "$LOG" && grep -q "attempt 2/4 failed" "$LOG" \
   && [ "$(wc -l < "$SHIM/count")" -ge 3 ]; then
  echo "PASS T2 (transient failures retried within one run — the legacy hook died on the first)"; pass=$((pass + 1))
else
  echo "FAIL T2 — no retry evidence in log or shim count"; fail=$((fail + 1))
fi

# ── T3 GARBAGE — the bef140a1a signature: HTTP 200, wrong body ──────────────
WS="$WORK/ws-t3"; make_ws "$WS" yes
: > "$SHIM/count"
LOG="$WORK/t3.log"; SEED_SHIM_SERVE_GARBAGE=1 run_seed "$WS" >"$LOG" 2>&1; code=$?
check 3 nonzero "$LOG" "::error::" "$code"
if grep -q "expected $ARM64_HASH" "$LOG" && grep -qi "purged" "$LOG" \
   && ! ls "$WS"/.dart_tool/hooks_runner/shared/sqlite3/build/download-*/libsqlite3.dylib >/dev/null 2>&1 \
   && ! ls "$WS"/.dart_tool/hooks_runner/shared/sqlite3/build/download-*/libsqlite3.dylib.tmp >/dev/null 2>&1; then
  echo "PASS T3 (wrong bytes purged — nothing installed, no .tmp left)"; pass=$((pass + 1))
else
  echo "FAIL T3 — garbage must never be installed"; fail=$((fail + 1))
fi

# ── T4 WARM — hash-valid cache skips the download (zero curl calls) ─────────
: > "$SHIM/count"; printf '99' > "$SHIM/fail-until"
LOG="$WORK/t4.log"; run_seed "$WORK/ws-t1" >"$LOG" 2>&1; code=$?
if [ "$code" = 0 ] \
   && grep -q "already cached" "$LOG" \
   && [ ! -s "$SHIM/count" ]; then
  echo "PASS T4 (warm cache: no download attempt at all — FAIL_FIRST=99 would have failed any attempt)"; pass=$((pass + 1))
else
  echo "FAIL T4 — warm cache must skip the network (curl calls: $(wc -l < "$SHIM/count"))"; sed 's/^/    /' "$LOG" | tail -5
  fail=$((fail + 1))
fi

# ── T5 MISSING — no sqlite3 in package_config fails loud before download ────
WS="$WORK/ws-t5"; make_ws "$WS" no
: > "$SHIM/count"
LOG="$WORK/t5.log"; run_seed "$WS" >"$LOG" 2>&1; code=$?
check 5 nonzero "$LOG" "not found in" "$code"
if [ ! -s "$SHIM/count" ]; then
  echo "PASS T5 (fails before ANY download attempt)"; pass=$((pass + 1))
else
  echo "FAIL T5 — must fail before the network"; fail=$((fail + 1))
fi

# ── T6 EXHAUST — persistent failures → exactly $ATTEMPTS attempts, loud ─────
WS="$WORK/ws-t6"; make_ws "$WS" yes
: > "$SHIM/count"; printf '99' > "$SHIM/fail-until"
LOG="$WORK/t6.log"
SQLITE3_SEED_ATTEMPTS=3 run_seed "$WS" >"$LOG" 2>&1; code=$?
check 6 nonzero "$LOG" "failed after 3 attempts" "$code"
if [ "$(wc -l < "$SHIM/count")" -eq 3 ]; then
  echo "PASS T6 (exactly 3 attempts under SQLITE3_SEED_ATTEMPTS=3)"; pass=$((pass + 1))
else
  echo "FAIL T6 — attempt count: $(wc -l < "$SHIM/count") != 3"; fail=$((fail + 1))
fi

# ── T7 STALE — a wrong-bytes cache file is replaced, never trusted ──────────
WS="$WORK/ws-t7"; make_ws "$WS" yes
rm -f "$SHIM/fail-until"   # T6's countdown must not leak into T7
STALE="$(cache_path "$WS" "$ARM64_HASH")"
mkdir -p "$(dirname "$STALE")"
printf 'stale-corrupt-bytes' > "$STALE"
LOG="$WORK/t7.log"; run_seed "$WS" >"$LOG" 2>&1; code=$?
check 7 0 "$LOG" "re-downloading" "$code"
GOT="$( (command -v shasum >/dev/null 2>&1 && shasum -a 256 "$STALE" || sha256sum "$STALE") | cut -d' ' -f1)"
if [ "$GOT" = "$ARM64_HASH" ]; then
  echo "PASS T7 (stale cache replaced with pinned bytes)"; pass=$((pass + 1))
else
  echo "FAIL T7 — stale cache file not replaced (sha $GOT)"; fail=$((fail + 1))
fi

echo
echo "seed_sqlite3_native_assets self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
