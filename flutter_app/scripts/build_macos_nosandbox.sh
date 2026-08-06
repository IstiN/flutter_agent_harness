#!/bin/bash
# Build a hardened-runtime, *non-sandboxed* macOS release of Fa.
# This flavor can spawn system interpreters (python3, bash, node, etc.)
# and is intended for GitHub Releases, not the App Store.
#
# Usage:
#   scripts/build_macos_nosandbox.sh
#
# Optional environment variables:
#   MACOS_IDENTITY  - signing identity (default: '-' for ad-hoc signature).
#   MACOS_TEAM_ID   - Apple Team ID; exported into the archive for notarization.
#
set -euo pipefail

cd "$(dirname "$0")/.."

readonly IDENTITY="${MACOS_IDENTITY:--}"
readonly APP="build/macos/Build/Products/Release/Fa.app"
readonly ENTITLEMENTS="macos/Runner/ReleaseNoSandbox.entitlements"

echo "[build_macos_nosandbox] Building Release..."
flutter build macos --release

echo "[build_macos_nosandbox] Re-signing with no-sandbox entitlements..."
codesign --force \
  --deep \
  --sign "${IDENTITY}" \
  --entitlements "${ENTITLEMENTS}" \
  --options runtime \
  "${APP}"

echo "[build_macos_nosandbox] Entitlements now applied:"
codesign -d --entitlements - "${APP}" | grep -E 'app-sandbox|jit|personal-information|homekit|healthkit' || true

echo "[build_macos_nosandbox] Done: ${APP}"
