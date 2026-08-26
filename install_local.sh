#!/usr/bin/env bash
# install_local.sh — build the Fa CLI from source and install it locally to ~/.local/bin.
#
# Run from the repo root:
#   sh install_local.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$REPO_ROOT/fa-local/bundle"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

mkdir -p "$INSTALL_DIR/lib"

cd "$REPO_ROOT"

echo "→ Building Fa CLI bundle..."
dart pub get >/dev/null 2>&1 || dart pub get
dart build cli --target=bin/fah.dart --output=fa-local

VERSION="$(grep '^version:' pubspec.yaml | awk '{print $2}')"
echo "$VERSION" > "$BUNDLE_DIR/version.txt"
echo "→ Built fa v$VERSION"

echo "→ Installing to $INSTALL_DIR..."
cp "$BUNDLE_DIR/bin/fah" "$INSTALL_DIR/fa"
chmod +x "$INSTALL_DIR/fa"
# macOS ARM kills unsigned native executables; ad-hoc sign so the copied
# binary is allowed to run from ~/.local/bin.
if [ "$(uname -s)" = "Darwin" ] && command -v codesign >/dev/null 2>&1; then
  codesign -s - -f "$INSTALL_DIR/fa" >/dev/null 2>&1 || true
fi
cp "$BUNDLE_DIR/version.txt" "$INSTALL_DIR/version.txt"
if [ -d "$BUNDLE_DIR/lib" ]; then
  cp -R "$BUNDLE_DIR/lib/"* "$INSTALL_DIR/lib/" 2>/dev/null || true
fi

echo "→ Installed $INSTALL_DIR/fa"

if ! command -v fa >/dev/null 2>&1; then
  echo "⚠  $INSTALL_DIR is not on your PATH. Add this to your shell rc:"
  echo "   export PATH=\"\$PATH:$INSTALL_DIR\""
else
  INSTALLED_VERSION="$(fa --version)"
  echo "✔  $INSTALLED_VERSION is on PATH"
fi
