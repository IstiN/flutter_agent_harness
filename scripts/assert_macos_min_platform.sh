#!/bin/bash
# gh-180 REG gate — assert the macOS release lane's effective min-platform
# invariants BEFORE any compile minute is spent ("fail loud at build time,
# not at release time").
#
# Incident (gh-180, build-macos run 39905803673, 2026-10-23, first run on
# the Xcode 27 runner): Flutter 3.47 stable ships Swift Package Manager
# enabled BY DEFAULT, migrates a fresh clone at build time, and generates
# FlutterGeneratedPluginSwiftPackage at the macOS 12.0 floor
# (flutter_tools darwin.dart: macos => Version(12, 0, null)). It raises
# that floor to the app's MACOSX_DEPLOYMENT_TARGET (14.0) only via a
# best-effort, silent `xcodebuild -showBuildSettings` read whose failures
# are swallowed (build_macos.dart → SwiftPackageManager.updateMinimumDeployment;
# "showBuildSettings is reported to occasionally timeout"). When the read
# skipped, Xcode hard-failed the build:
#
#   error: The package product 'flutter-inappwebview-macos-product'
#   requires minimum platform version 14.0 for the macOS platform, but
#   this target supports a lower version
#
# The lane decision (gh-180): the build-macos release legs build PURE
# CocoaPods. The job-level FLUTTER_SWIFT_PACKAGE_MANAGER=0 pin turns the
# feature off for every flutter invocation in the job, the tool's SPM
# migration then skips cleanly, and every macOS plugin is already pinned in
# flutter_app/macos/Podfile.lock — the Podfile platform (:osx, '14.0'), not
# a silent tool bump, is the authority for the effective pod floors.
#
# This gate runs in the Build macOS release step AFTER
# `flutter build macos --config-only` (which drives the tool's real SPM/pods
# config pass without compiling) and asserts, in order:
#
#   1. the app floor is intact — every MACOSX_DEPLOYMENT_TARGET in the
#      Runner Xcode project equals APP_MIN (default 14.0) and the Podfile
#      platform equals APP_MIN;
#   2. the vendored flutter_inappwebview_macos keeps its SwiftPM manifest
#      deleted (its mere presence is the SwiftPM opt-in signal — gh-1798);
#   3. NO SwiftPM state exists after the config pass — neither the
#      FlutterGeneratedPluginSwiftPackage marker in the pbxproj nor an
#      ephemeral generated package tree. If any exists, a floor scan
#      produces the specific diagnostic (product floor vs generated floor —
#      the literal gh-180 error shape) and the gate fails with the lane
#      remediation.
#
# Usage: scripts/assert_macos_min_platform.sh [APP_MIN] [REPO_ROOT]
#   APP_MIN    — the app's minimum macOS version (default 14.0)
#   REPO_ROOT  — repository root (default: the script's grandparent dir)
# Pinned by test/macos_min_platform_gate_test.dart and
# test/build_macos_spm_lane_guard_test.dart.
set -euo pipefail

APP_MIN="${1:-14.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${2:-$(cd "$SCRIPT_DIR/.." && pwd)}"

MACOS_DIR="$REPO_ROOT/flutter_app/macos"
PBXPROJ="$MACOS_DIR/Runner.xcodeproj/project.pbxproj"
PODFILE="$MACOS_DIR/Podfile"
EPHEMERAL_PKGS="$MACOS_DIR/Flutter/ephemeral/Packages"
VENDORED_PACKAGE_SWIFT="$REPO_ROOT/vendor/flutter_inappwebview_macos/macos/flutter_inappwebview_macos/Package.swift"
SPM_PACKAGE_NAME="FlutterGeneratedPluginSwiftPackage"

fail() { echo "::error::$*" >&2; exit 1; }

# ver_gt A B — true (exit 0) when version A > version B (numeric dotted
# compare; awk's exit status is the answer, not its output).
ver_gt() {
  printf '%s' "$1" | awk -F. -v b="$2" 'BEGIN{split(b,xb,".")}
    {for(i=1;i<=NF;i++){x=$i+0;y=xb[i]+0;if(x<y)exit 1;if(x>y)exit 0}exit 1}'
}

[ -f "$PBXPROJ" ] || fail "min-platform gate: $PBXPROJ not found — the build must run from a full flutter_app checkout"
[ -f "$PODFILE" ] || fail "min-platform gate: $PODFILE not found — the CocoaPods lane is the pinned macOS release lane (gh-180)"

# ── 1. App floor intact ────────────────────────────────────────────────────
entries="$(grep -E 'MACOSX_DEPLOYMENT_TARGET = ' "$PBXPROJ" || true)"
[ -n "$entries" ] || fail "min-platform gate: no MACOSX_DEPLOYMENT_TARGET entry in $PBXPROJ — the Runner target must pin the app floor ($APP_MIN) per config"
bad_entries="$(printf '%s\n' "$entries" | grep -v "MACOSX_DEPLOYMENT_TARGET = $APP_MIN;" || true)"
if [ -n "$bad_entries" ]; then
  printf '%s\n' "$bad_entries" >&2
  fail "min-platform gate: MACOSX_DEPLOYMENT_TARGET drift — every entry must equal $APP_MIN (gh-180 AC: every SPM/pods target ≥ $APP_MIN)"
fi

grep -q "^platform :osx, '$APP_MIN'" "$PODFILE" || fail "min-platform gate: $PODFILE must keep 'platform :osx, $APP_MIN' — the Podfile platform (not a silent tool bump) is the authority for the effective pod floors (gh-180)"

# ── 2. The vendored plugin stays on the pods lane ─────────────────────────
if [ -e "$VENDORED_PACKAGE_SWIFT" ]; then
  fail "min-platform gate: $VENDORED_PACKAGE_SWIFT exists again — its mere presence is the SwiftPM opt-in signal and republishes the ${APP_MIN}-floored flutter-inappwebview-macos product (gh-1798/gh-180). Delete it; the plugin rides the CocoaPods lane (podspec floor ${APP_MIN}, pinned in flutter_app/macos/Podfile.lock)"
fi

# ── 3. No SwiftPM state after the config pass ─────────────────────────────
marker_present=0
if grep -q "$SPM_PACKAGE_NAME" "$PBXPROJ"; then
  marker_present=1
fi
ephemeral_present=0
if [ -e "$EPHEMERAL_PKGS" ]; then
  ephemeral_present=1
fi

if [ "$marker_present" = 1 ] || [ "$ephemeral_present" = 1 ]; then
  # Specific diagnostic first: the literal gh-180 violation shape — a
  # package product floor above the generated package's own floor.
  generated_floor=""
  generated_manifest="$EPHEMERAL_PKGS/$SPM_PACKAGE_NAME/Package.swift"
  if [ -f "$generated_manifest" ]; then
    generated_floor="$(sed -n 's/.*\.macOS("\([0-9][0-9.]*\)").*/\1/p' "$generated_manifest" | head -1 || true)"
  fi
  while IFS= read -r -d '' manifest; do
    floor="$(sed -n 's/.*\.macOS("\([0-9][0-9.]*\)").*/\1/p' "$manifest" | head -1 || true)"
    [ -n "$floor" ] || continue
    if ver_gt "$floor" "$APP_MIN"; then
      fail "min-platform gate: $manifest requires macOS $floor > the app floor $APP_MIN — no SwiftPM product may exceed the app minimum (gh-180 AC)"
    fi
    if [ -n "$generated_floor" ] && ver_gt "$floor" "$generated_floor"; then
      fail "min-platform gate: a package product requires minimum platform version $floor for the macOS platform, but FlutterGeneratedPluginSwiftPackage supports $generated_floor — the exact gh-180 failure (the tool's silent xcodebuild -showBuildSettings floor bump skipped). Remediation: keep the FLUTTER_SWIFT_PACKAGE_MANAGER=0 job pin and the plugin's Package.swift deleted; the pods lane builds the same sources at the Podfile platform"
    fi
  done < <(find -L "$EPHEMERAL_PKGS" -name Package.swift -print0 2>/dev/null || true)

  diag="generated floor: ${generated_floor:-<none>}"
  if [ -n "$generated_floor" ] && ver_gt "$APP_MIN" "$generated_floor"; then
    diag="$diag (below the app floor — the tool's silent floor bump skipped again)"
  fi
  fail "min-platform gate: Swift Package Manager state present after a config-only pass ($diag) — the build-macos lane is pinned to PURE CocoaPods (job env FLUTTER_SWIFT_PACKAGE_MANAGER=0; every macOS plugin is pinned in flutter_app/macos/Podfile.lock). The pin was lost or a plugin re-opted into SwiftPM (Package.swift); re-entering the FlutterGeneratedPluginSwiftPackage lane is what red run 39905803673 (gh-180)"
fi

echo "min-platform gate: OK — app floor $APP_MIN (pbxproj + Podfile), pods lane pinned, no SwiftPM state (gh-180)"
