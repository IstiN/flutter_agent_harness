#!/bin/bash
# gh-1814 REG gate — assert the macOS release lane's effective min-platform
# invariants BEFORE any compile minute is spent ("fail loud at build time,
# not at release time").
#
# Lane history:
#   gh-180 (incident run 39905803673): Flutter 3.47 stable shipped the Swift
#   Package Manager feature enabled BY DEFAULT, migrated a fresh clone at
#   build time, and generated FlutterGeneratedPluginSwiftPackage at the
#   macOS 12.0 floor (flutter_tools darwin.dart: macos => Version(12, 0,
#   null)), raising it to the app's MACOSX_DEPLOYMENT_TARGET only via a
#   best-effort, silent `xcodebuild -showBuildSettings` read whose failures
#   are swallowed (build_macos.dart → SwiftPackageManager.
#   updateMinimumDeployment; "showBuildSettings is reported to occasionally
#   timeout"). When that read skipped, Xcode hard-failed the build:
#
#     error: The package product 'flutter-inappwebview-macos-product'
#     requires minimum platform version 14.0 for the macOS platform, but
#     this target supports a lower version
#
#   The gh-180 answer was a PURE CocoaPods lane: a job-level env pin turned
#   the SwiftPM feature off for every flutter invocation and this gate
#   FORBADE any SwiftPM state after the config pass.
#
#   gh-1814 (runs 39991663029 / 40022900373, the latter after the #1812
#   residue clean): upstream REMOVED the disable knob between 3.47.4 and
#   3.47.7 (flutter/flutter#193978 — the deprecation the gh-180 comment
#   predicted). The env pin is a no-op: the config pass always adds SwiftPM
#   integration, and this gate's old "no SwiftPM state" rule became the
#   failure itself. The #1813 escape (pin the legs to 3.47.4) is
#   operationally dead — the runners' ~60kB/s link cannot fetch that SDK
#   (run 40034163885). Owner ruling: the minimum macOS version may be
#   raised — the lane ADOPTS SwiftPM.
#
# Floor audit (gh-1814 step 1): the gh-180 sub-14.0 target was the
# GENERATED package at its 12.0 tool default with the silent bump skipped.
# On 3.47.7 the bump works (the failing runs' diagnostic reported
# `generated floor: 14.0`), so every floor in the lane already satisfies
# the 14.0 minimum and nothing needs raising — this gate now ENFORCES it:
#
#   1. the app floor is intact — every MACOSX_DEPLOYMENT_TARGET in the
#      Runner Xcode project equals APP_MIN (default 14.0) and the Podfile
#      platform equals APP_MIN;
#   2. the SPM lane is ADOPTED — the FlutterGeneratedPluginSwiftPackage
#      marker in the pbxproj AND the ephemeral generated package exist
#      after `flutter build macos --config-only`. Absence means the
#      migration did not run (tool behavior changed) — fail loud, never
#      silently pass as the retired pods-only lane;
#   3. the floor audit — the generated package floor is ≥ APP_MIN (the
#      tool's silent bump must have landed — the literal gh-180 killer),
#      every OTHER package manifest under the generated tree is floored at
#      ≤ APP_MIN (no SwiftPM product may exceed the app minimum — the
#      Runner target consumes every product at APP_MIN), and the vendored
#      flutter_inappwebview_macos Package.swift, if it ever reappears, is
#      floored AT APP_MIN (below: raise it; above: exceeds the app min).
#      The hybrid lane keeps the plugin's manifest deleted (gh-1798) — it
#      rides CocoaPods at the Podfile platform, pinned in Podfile.lock.
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
[ -f "$PODFILE" ] || fail "min-platform gate: $PODFILE not found — the hybrid lane's CocoaPods half (Podfile.lock pins) must stay wired (gh-1798/gh-1814)"

# ── 1. App floor intact ────────────────────────────────────────────────────
entries="$(grep -E 'MACOSX_DEPLOYMENT_TARGET = ' "$PBXPROJ" || true)"
[ -n "$entries" ] || fail "min-platform gate: no MACOSX_DEPLOYMENT_TARGET entry in $PBXPROJ — the Runner target must pin the app floor ($APP_MIN) per config"
bad_entries="$(printf '%s\n' "$entries" | grep -v "MACOSX_DEPLOYMENT_TARGET = $APP_MIN;" || true)"
if [ -n "$bad_entries" ]; then
  printf '%s\n' "$bad_entries" >&2
  fail "min-platform gate: MACOSX_DEPLOYMENT_TARGET drift — every entry must equal $APP_MIN (gh-1814: every SPM/pods target ≥ $APP_MIN)"
fi

grep -q "^platform :osx, '$APP_MIN'" "$PODFILE" || fail "min-platform gate: $PODFILE must keep 'platform :osx, $APP_MIN' — the Podfile platform (not a silent tool bump) is the authority for the CocoaPods half's effective pod floors (gh-180)"

# ── 2. The SPM lane is adopted (expected after the config pass) ───────────
marker_present=0
if grep -q "$SPM_PACKAGE_NAME" "$PBXPROJ"; then
  marker_present=1
fi
ephemeral_present=0
if [ -e "$EPHEMERAL_PKGS" ]; then
  ephemeral_present=1
fi

if [ "$marker_present" = 0 ]; then
  fail "min-platform gate: no $SPM_PACKAGE_NAME integration in $PBXPROJ after the config-only pass — Swift Package Manager state is EXPECTED on the build-macos lane (gh-1814 adoption; the disable knob was removed upstream in Flutter 3.47.7, flutter/flutter#193978), and its absence means the migration did not run (tool behavior changed: feature-flag rename, migration skip). Investigate before shipping — this is not the retired pods-only lane"
fi
if [ "$ephemeral_present" = 0 ]; then
  fail "min-platform gate: the pbxproj carries the $SPM_PACKAGE_NAME marker but $EPHEMERAL_PKGS (the ephemeral generated package tree) does not exist — a half-migrated config pass; the SPM lane (gh-1814) requires the generated package the tool writes during 'flutter build macos --config-only'"
fi

generated_manifest="$EPHEMERAL_PKGS/$SPM_PACKAGE_NAME/Package.swift"
[ -f "$generated_manifest" ] || fail "min-platform gate: $generated_manifest not found — the ephemeral Packages dir exists but the generated package manifest is missing; the SPM lane (gh-1814) cannot be asserted without the floor the tool writes into it"
generated_floor="$(sed -n 's/.*\.macOS("\([0-9][0-9.]*\)").*/\1/p' "$generated_manifest" | head -1 || true)"
[ -n "$generated_floor" ] || fail "min-platform gate: could not read a .macOS floor from $generated_manifest — the generated package must declare its platform minimum for this gate to assert the lane (upstream package-generation shape change; investigate)"

if ver_gt "$APP_MIN" "$generated_floor"; then
  fail "min-platform gate: the generated $SPM_PACKAGE_NAME floor $generated_floor is below the app floor $APP_MIN — the tool's silent xcodebuild -showBuildSettings bump skipped again (gh-180 mechanism: build_macos.dart updateMinimumDeployment swallows showBuildSettings failures). Xcode would kill the build with the literal 'requires minimum platform version $APP_MIN ... but this target supports a lower version' error; remediation: re-run the config pass, and if the bump keeps skipping, pin the generated floor knob in flutter_tools or raise the app floor"
fi

# ── 3. Floor audit: no SwiftPM product may exceed the app minimum ─────────
while IFS= read -r -d '' manifest; do
  [ "$manifest" = "$generated_manifest" ] && continue
  floor="$(sed -n 's/.*\.macOS("\([0-9][0-9.]*\)").*/\1/p' "$manifest" | head -1 || true)"
  # A manifest with no platforms declaration supports every version the
  # consumer floors — not a violation.
  [ -n "$floor" ] || continue
  if ver_gt "$floor" "$APP_MIN"; then
    fail "min-platform gate: $manifest requires macOS $floor > the app floor $APP_MIN — no SwiftPM product may exceed the app minimum: the Runner target consumes every package product at $APP_MIN, and Xcode fails the build with 'package product requires minimum platform version $floor ... but this target supports a lower version' (the gh-180 error shape). Remediation: floor the plugin at $APP_MIN (vendor + raise its Package.swift, gh-1798 pattern) or drop it from the macOS lane"
  fi
done < <(find -L "$EPHEMERAL_PKGS" -name Package.swift -print0 2>/dev/null || true)

# ── 3b. Vendored plugin manifest: floored AT the app minimum ──────────────
# The vendored flutter_inappwebview_macos rides the CocoaPods half of the
# hybrid lane with its SwiftPM manifest deleted (gh-1798, pinned by
# test/inappwebview_macos_pods_lane_test.dart). Presence is no longer a
# gate violation (gh-1814 adopts SwiftPM) — but if it reappears it must be
# floored exactly at the app minimum: below is a silent deployment-target
# regression (the podspec pins 14.0 for the same sources), above exceeds
# the app minimum the Runner target consumes products at.
if [ -e "$VENDORED_PACKAGE_SWIFT" ]; then
  vendored_floor="$(sed -n 's/.*\.macOS("\([0-9][0-9.]*\)").*/\1/p' "$VENDORED_PACKAGE_SWIFT" | head -1 || true)"
  [ -n "$vendored_floor" ] || fail "min-platform gate: $VENDORED_PACKAGE_SWIFT reappeared with no readable .macOS floor — a SwiftPM opt-in whose platform minimum cannot be asserted; declare platforms: [.macOS(\"$APP_MIN\")] or delete the manifest (the plugin rides CocoaPods, gh-1798)"
  if ver_gt "$vendored_floor" "$APP_MIN"; then
    fail "min-platform gate: $VENDORED_PACKAGE_SWIFT requires macOS $vendored_floor > the app floor $APP_MIN — the vendored plugin's SwiftPM product exceeds the app minimum (gh-1814); floor it at $APP_MIN to match the podspec (s.platform = :osx, '$APP_MIN')"
  fi
  if ver_gt "$APP_MIN" "$vendored_floor"; then
    fail "min-platform gate: $VENDORED_PACKAGE_SWIFT declares macOS $vendored_floor < the app floor $APP_MIN — a silent deployment-target regression: the podspec floors the SAME sources at $APP_MIN (s.platform = :osx, '$APP_MIN') and Podfile.lock pins it there; raise the Package.swift floor to $APP_MIN (gh-1814)"
  fi
fi

echo "min-platform gate: OK — SPM lane adopted (gh-1814): app floor $APP_MIN (pbxproj + Podfile), generated floor $generated_floor, all product floors ≤ $APP_MIN, vendored plugin on the pods half (manifest deleted)"
