#!/usr/bin/env bash
# install_local.sh — build the Fa CLI from source and install it locally to ~/.local/bin.
#
# Run from the repo root:
#   sh install_local.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$REPO_ROOT/fa-local/bundle"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

mkdir -p "$INSTALL_DIR/../lib"

cd "$REPO_ROOT"

echo "→ Building Fa CLI bundle..."
dart pub get >/dev/null 2>&1 || dart pub get
dart build cli --target=bin/fah.dart --output=fa-local

# gh-1522: the committed pubspec carries the 0.0.0-dev placeholder (the git
# tag is the single source of truth) — stamp the build version from git
# describe: the exact tag when HEAD is tagged, else <tag>-<n>-g<sha>[-dirty].
# A plain `dart run` (no install) shows 0.0.0-dev — acceptable and
# self-explanatory.
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo 0.0.0-dev)"
VERSION="${VERSION#v}"
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
# gh-1574: the AOT binary's native-assets resolver looks for the bundle
# libs in <exe_dir>/../lib — with the exe at $INSTALL_DIR/fa that is
# $INSTALL_DIR/../lib (e.g. ~/.local/lib for ~/.local/bin/fa), never
# $INSTALL_DIR/lib.
if [ -d "$BUNDLE_DIR/lib" ]; then
  if ! cp -R "$BUNDLE_DIR/lib/"* "$INSTALL_DIR/../lib/"; then
    echo "⚠  failed to copy the bundle libs into $INSTALL_DIR/../lib — SQLite reads will fail until that directory holds the bundled libsqlite3; check permissions and disk space, then reinstall" >&2
  fi
fi

echo "→ Installed $INSTALL_DIR/fa"

if ! command -v fa >/dev/null 2>&1; then
  echo "⚠  $INSTALL_DIR is not on your PATH. Add this to your shell rc:"
  echo "   export PATH=\"\$PATH:$INSTALL_DIR\""
else
  INSTALLED_VERSION="$(fa --version)"
  echo "✔  $INSTALLED_VERSION is on PATH"
fi
