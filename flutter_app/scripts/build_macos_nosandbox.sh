#!/bin/bash
# Build a hardened-runtime, *non-sandboxed* macOS release of Fa.
# This flavor can spawn system interpreters (python3, bash, node, etc.)
# and is intended for GitHub Releases, not the App Store.
#
# Usage:
#   scripts/build_macos_nosandbox.sh
#
# Optional environment variables:
#   FA_CODE_SIGN_IDENTITY / MACOS_IDENTITY - signing identity.
#   FA_DEVELOPMENT_TEAM / MACOS_TEAM_ID     - Apple Team ID.
set -euo pipefail

cd "$(dirname "$0")/.."

# Prefer the new FA_* variables; fall back to the older MACOS_* names.
identity="${FA_CODE_SIGN_IDENTITY:-${MACOS_IDENTITY:--}}"
team="${FA_DEVELOPMENT_TEAM:-${MACOS_TEAM_ID:-}}"

# If no identity was requested, try to use a local Apple Development cert so
# the no-sandbox build still has a stable TeamIdentifier for TCC.
if [[ "$identity" == "-" ]]; then
  development_identity=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 'Apple Development' \
    | sed -n 's/.*"\(.*\)".*/\1/p' || true)
  if [[ -n "$development_identity" ]]; then
    identity="Apple Development"
  fi
fi

# If we have a real identity but no team, extract the team identifier (OU)
# from the matching certificate's subject. HealthKit/HomeKit entitlements
# require a non-empty team.
if [[ "$identity" != "-" && -z "$team" ]]; then
  cert_label=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "$identity" \
    | head -n1 \
    | sed -n 's/.*"\(.*\)".*/\1/p' || true)
  if [[ -n "$cert_label" ]]; then
    team=$(security find-certificate -c "$cert_label" -p 2>/dev/null \
      | openssl x509 -noout -subject 2>/dev/null \
      | grep -oE 'OU=[A-Z0-9]+' \
      | cut -d= -f2 \
      | head -n1 || true)
  fi
fi

# Distribution/Developer ID certificates require manual signing; local
# Apple Development certificates use automatic signing.
if [[ "$identity" == "-" || "$identity" == "Apple Development" ]]; then
  export FA_CODE_SIGN_STYLE="${FA_CODE_SIGN_STYLE:-Automatic}"
else
  export FA_CODE_SIGN_STYLE="${FA_CODE_SIGN_STYLE:-Manual}"
fi

export FA_CODE_SIGN_IDENTITY="$identity"
export FA_DEVELOPMENT_TEAM="$team"
export FA_PROVISIONING_PROFILE_SPECIFIER="${FA_PROVISIONING_PROFILE_SPECIFIER:-}"

readonly APP="build/macos/Build/Products/Release/Fa.app"
readonly ENTITLEMENTS="macos/Runner/ReleaseNoSandbox.entitlements"

echo "[build_macos_nosandbox] Building Release (identity='${identity}', team='${team:-}')..."
flutter build macos --release

echo "[build_macos_nosandbox] Re-signing with no-sandbox entitlements..."
codesign --force \
  --deep \
  --sign "${identity}" \
  --entitlements "${ENTITLEMENTS}" \
  --options runtime \
  "${APP}"

echo "[build_macos_nosandbox] Entitlements now applied:"
codesign -d --entitlements - "${APP}" | grep -E 'app-sandbox|jit|personal-information|homekit|healthkit' || true

echo "[build_macos_nosandbox] Done: ${APP}"
