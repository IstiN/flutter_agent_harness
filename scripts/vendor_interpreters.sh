#!/usr/bin/env bash
# Downloads the sandboxed-interpreter runtimes the extension's run_script
# tool needs into browser_ext/vendor/interpreters/ (gitignored). Extension
# CSP forbids remote scripts, so these CANNOT ride a CDN at runtime —
# they ship inside the extension bundle. Mirrors the web app's sandbox
# versions (flutter_app/lib/sandbox/web_interpreters_web.dart):
#   - quickjs-emscripten@0.31.0 (dist/index.global.js; wasm is embedded
#     as a base64 data URL — one self-contained file)
#   - pyodide v0.26.4 (pyodide.js + pyodide.asm.js + pyodide.asm.wasm +
#     python_stdlib.zip + pyodide-lock.json)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/browser_ext/vendor/interpreters"
QJS_BASE="https://cdn.jsdelivr.net/npm/quickjs-emscripten@0.31.0/dist"
PYODIDE_BASE="https://cdn.jsdelivr.net/pyodide/v0.26.4/full"

FILES=(
  "$QJS_BASE/index.global.js"
  "$PYODIDE_BASE/pyodide.js"
  "$PYODIDE_BASE/pyodide.asm.js"
  "$PYODIDE_BASE/pyodide.asm.wasm"
  "$PYODIDE_BASE/python_stdlib.zip"
  "$PYODIDE_BASE/pyodide-lock.json"
)

mkdir -p "$DEST"
for url in "${FILES[@]}"; do
  name="$(basename "$url")"
  out="$DEST/$name"
  if [ -s "$out" ]; then
    echo "vendor: $name already present, skipping"
    continue
  fi
  echo "vendor: downloading $name"
  curl -fsSL "$url" -o "$out.tmp"
  mv "$out.tmp" "$out"
done
echo "vendor: interpreters ready in $DEST"
