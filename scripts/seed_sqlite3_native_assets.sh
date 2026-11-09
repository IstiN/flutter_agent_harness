#!/usr/bin/env bash
# seed_sqlite3_native_assets.sh — pre-seed the package:sqlite3 native-assets
# hook cache so the macOS release builds never depend on the hook's single
# un-retried build-time download (gh-2075).
#
# INCIDENT (gh-2075, build-macos run 42566734746, 2026-11-09): every
# package:sqlite3 build hook in the cli leg died on its ONE download GET:
#   - Build macOS CLI arm64 (`dart build cli`, hosted macos-latest):
#     "Unexpected response code: 504 Gateway Time-out" → `Running build
#     hooks failed`, exit 255 — the CLI bundle never built.
#   - Build macOS arm64 / x86_64 (`flutter build macos --release`, the
#     Flutter Assemble phase, ~20 min into the build): the download came
#     back HTTP 200 with the SAME wrong body for BOTH distinct arch
#     assets (sha256 bef140a1a… for arm64 AND x64 — a middlebox error
#     page, not a dylib), caught by the hook's own digest pin: "Bad
#     state: Hash of downloaded file … is bef140a1a…, expected
#     649fdf22…/5b956194…" → `Target build_hooks failed` → `** BUILD
#     FAILED **`.
# Upstream assets are intact — post-incident fetches of sqlite3-3.7.0 and
# sqlite3-3.9.1 (arm64 + x64) hash-match the package-pinned digests
# exactly. Pure transport flake, one un-retried request — the same egress
# class gh-1759 solved for WasmRun.xcframework (bounded curl retries +
# pinned sha256 + purge on mismatch) and gh-1644 for the git mirrors.
#
# WHY SEEDING THE HOOK CACHE IS SAFE: the sqlite3 hook (3.7.0 and 3.9.1
# verified identical here) caches per content hash under
#   <workspace>/.dart_tool/hooks_runner/shared/sqlite3/build/download-<hash8>/
#   (the file name the target OS resolves: libsqlite3.dylib on macOS)
# — a STABLE path, NOT a per-input-hash dir (hooks_runner build_runner:
# outDirSharedUri = dartToolHooksRunner.resolve('shared/<pkg>/build/')) —
# and it REUSES a present file ONLY when its sha256 matches the
# package-pinned digest from the installed package's own
# lib/src/hook/asset_hashes.dart, else re-downloads
# (PrecompiledBinary.downloadIntoOutputDirectoryShared). So a seeded file
# is trusted only when it is the pinned bytes: wrong content can never
# reach the build through this script — the hook re-validates.
#
# WHAT THIS DOES, per <workspace> and arch:
#   1. resolve the installed package:sqlite3 from
#      <workspace>/.dart_tool/package_config.json (fail loud if missing —
#      run the workspace's pub resolution first),
#   2. read release tag + pinned sha256 from the package's own
#      asset_hashes.dart — single source of truth, a lockfile bump
#      self-updates, nothing pinned here,
#   3. skip when a hash-valid dylib is already cached (warm path — the
#      release and no-sandbox builds share the workspace),
#   4. otherwise download the pinned asset with the gh-1759 WasmRun
#      recipe — curl --fail -L, bounded attempts, per-attempt wall cap,
#      sha256 verify BEFORE install, purge on mismatch — into the hook
#      cache path.
# Every failure exits nonzero BEFORE the build spends compile minutes:
# the gh-2075 class surfaces here in seconds with a named ::error::, not
# ~20 minutes into a release build.
#
# Usage:
#   seed_sqlite3_native_assets.sh <workspace-dir> macos <arch> [<arch>…]
#     arch: arm64 | x64  (the GitHub release asset naming: macOS x86_64 is
#     "x64" upstream — map the matrix arch BEFORE calling, the
#     build-macos.yml size-manifest step idiom)
#
# Env:
#   SQLITE3_RELEASE_MIRROR — optional base URL override for the asset
#     source (default: the upstream GitHub release path). The pinned
#     sha256 applies to ANY source, so a mirror can never ship wrong
#     bytes past this script nor past the hook's own reuse check.
#   SQLITE3_SEED_ATTEMPTS — download attempts (default 4, the gh-1759
#     WasmRun budget). SQLITE3_SEED_MAX_TIME — per-attempt curl
#     --max-time seconds (default 240).
#
# Guard: test/ci_sqlite3_native_asset_seed_guard_test.dart pins the
# build-macos.yml wiring (seed after clean/config, before the builds, all
# three gh-2075 jobs). Selftest: scripts/seed_sqlite3_native_assets_selftest.sh
# drives the real script through the incident scenarios with a
# fault-injected curl — hermetic, no real egress.

set -euo pipefail

usage() {
  echo "usage: $0 <workspace-dir> macos <arch> [<arch>…]  (arch: arm64|x64)" >&2
  exit 2
}

[ "$#" -ge 3 ] || usage
WS="$1"
TARGET_OS="$2"
shift 2

if [ "$TARGET_OS" != "macos" ]; then
  echo "::error::only 'macos' is wired today (the gh-2075 legs); got '$TARGET_OS'" >&2
  exit 2
fi

for ARCH in "$@"; do
  case "$ARCH" in
    arm64|x64) ;;
    *) echo "::error::unsupported arch '$ARCH' (arm64|x64)" >&2; exit 2 ;;
  esac
done

CONFIG="$WS/.dart_tool/package_config.json"
if [ ! -f "$CONFIG" ]; then
  echo "::error::$CONFIG not found — run the workspace's package resolution (flutter/dart pub get) before seeding (gh-2075)" >&2
  exit 1
fi

# Resolve the installed sqlite3 package root from the workspace's own
# package config — the same resolution the hooks_runner feeds the hook.
SQLITE_PKG="$(python3 - "$CONFIG" <<'PY'
import json, sys

with open(sys.argv[1]) as fh:
    config = json.load(fh)
for pkg in config.get("packages", []):
    if pkg.get("name") == "sqlite3":
        print(pkg["rootUri"])
        break
PY
)"
if [ -z "${SQLITE_PKG:-}" ]; then
  echo "::error::package:sqlite3 not found in $CONFIG — nothing to seed (the workspace stopped depending on sqlite3? drop the seed step then, and update the gh-2075 guard test)" >&2
  exit 1
fi
case "$SQLITE_PKG" in
  file://*) SQLITE_PKG="${SQLITE_PKG#file://}" ;;
  /*) ;;
  *) SQLITE_PKG="$WS/$SQLITE_PKG" ;;
esac
SQLITE_PKG="$(cd "$SQLITE_PKG" && pwd)"

HASHES="$SQLITE_PKG/lib/src/hook/asset_hashes.dart"
if [ ! -f "$HASHES" ]; then
  echo "::error::$HASHES missing — the installed sqlite3 predates the native-assets hook; drop the seed step (and update the gh-2075 guard test)" >&2
  exit 1
fi

RELEASE_TAG="$(sed -nE "s/^const String\? releaseTag = '([^']+)';.*/\1/p" "$HASHES" | head -1)"
if [ -z "$RELEASE_TAG" ]; then
  echo "::error::could not parse releaseTag from $HASHES — the package layout changed; update the seed script" >&2
  exit 1
fi

MIRROR="${SQLITE3_RELEASE_MIRROR:-https://github.com/simolus3/sqlite3.dart/releases/download}"
ATTEMPTS="${SQLITE3_SEED_ATTEMPTS:-4}"
MAX_TIME="${SQLITE3_SEED_MAX_TIME:-240}"

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

for ARCH in "$@"; do
  ASSET="libsqlite3.${ARCH}.${TARGET_OS}.dylib"
  EXPECTED="$(sed -nE "s/^ *'$ASSET': '([0-9a-f]+)',.*/\1/p" "$HASHES" | head -1)"
  if [ -z "$EXPECTED" ]; then
    echo "::error::no pinned sha256 for $ASSET in $HASHES — the release layout changed; update the seed script" >&2
    exit 1
  fi
  if ! [[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]]; then
    echo "::error::pinned hash for $ASSET malformed ('$EXPECTED') — update the seed script's parse" >&2
    exit 1
  fi

  # The hook's own cache: download-<hash8> (dirname = first 8 hex of the
  # pinned digest) under the stable shared dir; the file name is what
  # targetOS.libraryFileName resolves to on macOS, for every arch.
  CACHE_DIR="$WS/.dart_tool/hooks_runner/shared/sqlite3/build/download-${EXPECTED:0:8}"
  CACHE_FILE="$CACHE_DIR/libsqlite3.dylib"
  mkdir -p "$CACHE_DIR"

  if [ -f "$CACHE_FILE" ]; then
    ACTUAL="$(sha256_file "$CACHE_FILE")"
    if [ "$ACTUAL" = "$EXPECTED" ]; then
      echo "sqlite3 seed: $ASSET already cached (sha256 $EXPECTED) — skipping download"
      continue
    fi
    echo "sqlite3 seed: cached file sha256 $ACTUAL != pinned $EXPECTED — re-downloading" >&2
  fi

  URL="$MIRROR/$RELEASE_TAG/$ASSET"
  TMP="$CACHE_DIR/libsqlite3.dylib.tmp"
  rm -f "$TMP"
  ATTEMPT=1
  while [ "$ATTEMPT" -le "$ATTEMPTS" ]; do
    # --fail (gh-1759): without it curl exits 0 on HTTP errors and writes
    # the error page into the file — exactly the bef140a1a signature when
    # the hook's own status check is bypassed by a 200 error page.
    if curl --fail -L --connect-timeout 30 --max-time "$MAX_TIME" -o "$TMP" "$URL"; then
      break
    fi
    rm -f "$TMP"
    if [ "$ATTEMPT" -eq "$ATTEMPTS" ]; then
      echo "::error::sqlite3 seed: download failed after $ATTEMPTS attempts: $URL — the release build would die on the same request mid-build (gh-2075); check runner egress or point SQLITE3_RELEASE_MIRROR at a reachable mirror" >&2
      exit 1
    fi
    echo "sqlite3 seed: download attempt $ATTEMPT/$ATTEMPTS failed for $URL — retrying in 5s..." >&2
    sleep 5
    ATTEMPT=$((ATTEMPT + 1))
  done

  GOT="$(sha256_file "$TMP")"
  if [ "$GOT" != "$EXPECTED" ]; then
    # Purge, never install (the WasmRun digest-purge): a complete-but-wrong
    # file (proxy page) must not sit in the cache where the hook — or a
    # later step — could reuse it without re-checking.
    rm -f "$TMP"
    echo "::error::sqlite3 seed: downloaded $ASSET with sha256 $GOT, expected $EXPECTED — purged; a proxy/middlebox error page is the gh-2075 signature" >&2
    exit 1
  fi
  mv "$TMP" "$CACHE_FILE"
  echo "sqlite3 seed: installed $ASSET → $CACHE_FILE (sha256 $EXPECTED)"
done

echo "✅ sqlite3 native-asset cache seeded — the build hook will reuse the pinned bytes without a network request (gh-2075)"
