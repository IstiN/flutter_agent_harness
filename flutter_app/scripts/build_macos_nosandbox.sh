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
# from the matching certificate's subject: DEVELOPMENT_TEAM keeps the app's
# TeamIdentifier stable for TCC prompts and Developer ID notarization (the
# shipped no-sandbox entitlement set declares no team-scoped claims — the
# gh-2132 prune removed HealthKit/HomeKit).
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

# gh-2039 pre-flight — the pinned identity must be resolvable by the
# SAME search list codesign reads, BEFORE the multi-minute flutter
# build whose xcode_backend codesign is the first real consumer. A
# missing/locked/expired identity used to surface as `error: no
# identity found` 5+ minutes into the build (run 41393469972); fail
# here in ~1s with the exact remediation instead.
#
# No `-v` (gh-2039 rework review): the verbose listing includes INVALID
# identities too, each with its failure reason (e.g.
# CSSMERR_TP_CERT_EXPIRED) AND its SHA-1 — an expired pinned identity
# would match the grep and the exact "expired cert" case this guard
# exists to catch would slip into the 5-minute build. The plain
# listing is VALID identities only, which is also the closer
# approximation of what codesign will accept. `-i` because
# `codesign --sign <SHA1>` and ci-sign's validity check are
# case-insensitive — the pre-flight must be no stricter than its
# consumers.
if [[ "$identity" != "-" ]]; then
  if ! security find-identity -p codesigning 2>/dev/null | grep -Fiq -- "$identity"; then
    echo "::error::signing identity '$identity' is not resolvable as a VALID identity via 'security find-identity -p codesigning' (missing, expired, or the signing keychain is locked) — codesign inside 'flutter build' would fail after a full build. Re-assert the signing state first: ~/bin/ci-sign install fa-macos (unlock + identity verify + search-list rewrite), then re-run." >&2
    exit 1
  fi
  echo "[build_macos_nosandbox] identity pre-flight OK: '$identity' resolvable for codesigning"
fi

readonly APP="build/macos/Build/Products/ReleaseNoSandbox/Fa.app"
readonly ENTITLEMENTS="macos/Runner/ReleaseNoSandbox.entitlements"

# Configuration pass (SPM migration + pod install) — the same tool pass the
# sandboxed leg drives before its release build (build-macos.yml "Build
# macOS release"): it writes the Generated.xcconfig + ephemeral package the
# xcodebuild below consumes and puts the checkout in the SPM-lane state the
# gate asserts.
echo "[build_macos_nosandbox] Config pass (identity='${identity}', team='${team:-}')..."
flutter build macos --config-only

# gh-1814 gate, same post-config assertion as the sandboxed leg: floors
# intact + SwiftPM lane adopted BEFORE any compile minute is spent.
bash ../scripts/assert_macos_min_platform.sh 14.0 ..

# #2132 (review 5876405113): CONSUME the ReleaseNoSandbox configuration —
# the real compile runs THE configuration the PR wires, so its
# CODE_SIGN_ENTITLEMENTS pin signs the bundle at build time and the
# configuration is not an inert artifact. Flags mirror flutter's own
# xcodebuild invocation (build_macos.dart: -clonedSourcePackagesDirPath /
# -workspace / -scheme / -derivedDataPath / -destination / OBJROOT /
# SYMROOT / COMPILER_INDEX_STORE_ENABLE / -quiet / build) with the
# mode-mapped Release swapped for ReleaseNoSandbox; xcode_backend maps the
# name to release mode (contains('release')). ARCHS rides
# FLUTTER_XCODE_ARCHS exactly like the tool's env→build-setting mapping.
echo "[build_macos_nosandbox] Building ReleaseNoSandbox configuration..."
arch_args=()
if [[ -n "${FLUTTER_XCODE_ARCHS:-}" ]]; then
  arch_args+=(ARCHS="$FLUTTER_XCODE_ARCHS")
fi
xcodebuild \
  -clonedSourcePackagesDirPath "$PWD/build/macos/PackageCache" \
  -workspace macos/Runner.xcworkspace \
  -configuration ReleaseNoSandbox \
  -scheme Runner \
  -derivedDataPath "$PWD/build/macos" \
  -destination 'platform=macOS' \
  OBJROOT="$PWD/build/macos/Build/Intermediates.noindex" \
  SYMROOT="$PWD/build/macos/Build/Products" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  "${arch_args[@]+${arch_args[@]}}" \
  -quiet \
  build

# #2132: the size diet (prune_flutter_assets.sh, #1096) must run BEFORE any
# codesign so the seal covers the shipped tree — pruning a signed bundle
# breaks it (missing sealed resource). Same two cuts and the same fail-loud
# script the sandboxed DMG leg uses (its "before any codesign" doctrine
# comment); the workflow step used to prune AFTER the re-sign below, which
# shipped a broken seal.
bash ../scripts/prune_flutter_assets.sh \
  "${APP}/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets" \
  assets/wasm packages/js_widget_runtime/test

echo "[build_macos_nosandbox] Re-signing after the prune (seal repair — the build-time signature already carries the same no-sandbox set)..."
codesign --force \
  --deep \
  --sign "${identity}" \
  --entitlements "${ENTITLEMENTS}" \
  --options runtime \
  "${APP}"

# #2132 AC3 pipeline assertion: the shipped entitlement set must be EXACTLY
# the pruned trio from ReleaseNoSandbox.entitlements — no app-sandbox, none
# of the stale personal-information / healthkit / homekit claims (they are
# sandbox-scoped or iOS-only and poison profile-free Developer ID
# notarization), JIT present for the Flutter engine. Fail the release leg
# loud instead of attaching a mis-entitled DMG.
SIGNED_ENTS="$(codesign -d --entitlements :- "${APP}" 2>/dev/null || true)"
for BAD in app-sandbox personal-information healthkit homekit; do
  if grep -q "${BAD}" <<<"${SIGNED_ENTS}"; then
    echo "::error::the signed no-sandbox app declares '${BAD}' — build_macos_nosandbox.sh must ship EXACTLY {com.apple.security.cs.allow-jit, com.apple.security.network.client, com.apple.security.network.server} (macos/Runner/ReleaseNoSandbox.entitlements); fix the entitlements file or the re-sign and re-run." >&2
    exit 1
  fi
done
if ! grep -q 'cs.allow-jit' <<<"${SIGNED_ENTS}"; then
  echo "::error::the signed no-sandbox app is missing com.apple.security.cs.allow-jit — the Flutter engine needs JIT without the App Sandbox; re-sign with macos/Runner/ReleaseNoSandbox.entitlements." >&2
  exit 1
fi
echo "[build_macos_nosandbox] entitlement set OK (no sandbox, no stale claims, JIT present)"
spctl -a -vv -t exec "${APP}" 2>/dev/null || true

echo "[build_macos_nosandbox] Done: ${APP}"
