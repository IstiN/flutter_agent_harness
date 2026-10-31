#!/usr/bin/env bash
# Regenerate every launcher/store icon from the canonical Fa Squircle-V4
# geometry. Python + Pillow render the non-Android assets deterministically;
# the existing Dart image tool then derives Android and Play icons from the
# exact iOS master (the SSIM guards in test/android_icon_test.dart pin this).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"

python3 "$ROOT/tool/generate_fa2_icons.py"
(cd "$ROOT" && dart run tool/generate_android_adaptive_icons.dart)

echo "All Fa 2.0 icons regenerated."
