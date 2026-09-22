#!/usr/bin/env bash
# 16 KB page-size gate for the PACKAGED Android bundle (gh-746; layout fix +
# owned verdict in gh-786). Called by build-mobile.yml's "Verify AAB" step
# and self-tested in CI by aab-gate-selftest.yml against fixture bundles
# (gh-798 AC3) — keep the two fixture expectations in sync with this file.
#
# Usage: verify_aab_native_libs.sh <path-to-aab>
#
# The gate owns its verdict: it never rides unzip's exit code — after the
# extraction it checks what matched and prints a named pass/fail. Native
# libs are EXPECTED in the store bundle (libapp/libflutter/libwasm_run_dart
# + LiteRT/QNN), so zero matches is a packaging regression, not a skip.
set -euo pipefail

AAB_PATH="${1:?usage: verify_aab_native_libs.sh <path-to-aab>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP_LIBS="$(mktemp -d)"
trap 'rm -rf "$TMP_LIBS"' EXIT
# AAB layout: native libs live at base/lib/<abi>/*.so — 'lib/*' is the APK
# layout and matches nothing (gh-786).
unzip -o -q "$AAB_PATH" 'base/lib/*' -d "$TMP_LIBS" || true
LIB_COUNT=$(find "$TMP_LIBS" -type f -name '*.so' | wc -l)
if [ "$LIB_COUNT" -eq 0 ]; then
  echo "::error::expected native libs at base/lib/*/*.so in the AAB, found none — packaging regression (gh-786)"
  exit 1
fi
echo "Native libs in the bundle: $LIB_COUNT"
find "$TMP_LIBS" -type f -name '*.so' | sed "s|$TMP_LIBS/||"
dart "$SCRIPT_DIR/patch_elf_16k_alignment.dart" --check "$TMP_LIBS"
echo "✅ 16 KB alignment check green"
