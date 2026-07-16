#!/bin/bash
# Copyright (c) 2026, the Flutter Agent Harness authors.
# Use of this source code is governed by a MIT license that can be found
# in the LICENSE file.
#
# Copies the prebuilt WasmRun.xcframework from the pub cache into the vendored
# wasm_run_flutter plugin. The Dart/Objective-C bridge in vendor/ was patched
# to remove unused capturedStdout/capturedStderr symbols, but the native binary
# is unchanged from the published package, so we reuse it from pub.dev.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
SOURCE="$PUB_CACHE/hosted/pub.dev/wasm_run_flutter-0.1.0/ios/Frameworks/WasmRun.xcframework"
DEST="$REPO_ROOT/vendor/wasm_run_flutter/ios/Frameworks/WasmRun.xcframework"

if [[ ! -d "$SOURCE" ]]; then
  echo "Error: prebuilt XCFramework not found in pub cache: $SOURCE"
  echo "Run 'flutter pub get' in the example app first so the original package is cached."
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -R "$SOURCE" "$DEST"
echo "Copied WasmRun.xcframework to $DEST"
