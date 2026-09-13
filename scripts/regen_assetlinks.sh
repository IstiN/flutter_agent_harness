#!/usr/bin/env bash
# Regenerates site/.well-known/assetlinks.json (Android App Links statements
# for dev.fa1.app). Fingerprints are public by design — they ship inside every
# signed APK. Issue #289 (E2).
#
# Usage: scripts/regen_assetlinks.sh <upload-keystore.jks> [<debug.keystore>] \
#            [<play-app-signing-cert.sha256-colon> ...]
#   - upload keystore (mandatory): the release/upload signing key
#   - debug keystore (optional, default ~/.android/debug.keystore): emulator
#     and local install verification
#   - any additional args are extra SHA-256 fingerprints (colon-separated),
#     e.g. the Play App Signing certificate SHA-256 from Play Console →
#     Release → Setup → App signing — add it once Play App Signing is
#     enrolled so links verify for store-installed builds (which Google
#     re-signs with the app signing key).
set -euo pipefail

UPLOAD_KS="${1:?usage: regen_assetlinks.sh <upload.jks> [debug.keystore] [extra sha256 ...]}"
DEBUG_KS="${2:-$HOME/.android/debug.keystore}"
shift $(( $# > 1 ? 2 : 1 )) || true
EXTRA=("$@")

KEYTOOL="${KEYTOOL:-$(find "/Applications/Android Studio.app/Contents/jbr" -name keytool 2>/dev/null | head -1)}"
[ -x "$KEYTOOL" ] || KEYTOOL=keytool

fp() { # keystore -> colon-separated SHA-256 fingerprint
  local ks="$1" pass="${2:-}" alias="${3:-}"
  "$KEYTOOL" -list -v -keystore "$ks" $([ -n "$pass" ] && echo "-storepass $pass") \
    $([ -n "$alias" ] && echo "-alias $alias") 2>/dev/null \
    | awk '/SHA256:/{print $2; exit}'
}

UPLOAD_PASS="${UPLOAD_PASS:-$(dirname "$UPLOAD_KS")/fa-upload.jks.password.txt}"
[ -f "$UPLOAD_PASS" ] && UPLOAD_PASS="$(cat "$UPLOAD_PASS")" || UPLOAD_PASS=""

fps=()
fps+=("$(fp "$UPLOAD_KS" "$UPLOAD_PASS" fa-upload)")
[ -f "$DEBUG_KS" ] && fps+=("$(fp "$DEBUG_KS" android androiddebugkey)")
fps+=("${EXTRA[@]+"${EXTRA[@]}"}")

out="$(dirname "$0")/../site/.well-known/assetlinks.json"
mkdir -p "$(dirname "$out")"
{
  echo '['
  echo '  {'
  echo '    "relation": ["delegate_permission/common.handle_all_urls"],'
  echo '    "target": {'
  echo '      "namespace": "android_app",'
  echo '      "package_name": "dev.fa1.app",'
  echo '      "sha256_cert_fingerprints": ['
  for i in "${!fps[@]}"; do
    comma=""; [ "$i" -lt $((${#fps[@]} - 1)) ] && comma=","
    echo "        \"${fps[$i]}\"$comma"
  done
  echo '      ]'
  echo '    }'
  echo '  }'
  echo ']'
} > "$out"
echo "wrote $out"
cat "$out"
