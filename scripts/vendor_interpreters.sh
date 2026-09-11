#!/usr/bin/env bash
# Downloads the sandboxed-interpreter runtimes the extension's run_script
# tool needs into browser_ext/vendor/interpreters/ (gitignored). Extension
# CSP forbids remote scripts, so these CANNOT ride a CDN at runtime —
# they ship inside the extension bundle. Mirrors the web app's sandbox
# versions (flutter_app/lib/sandbox/web_interpreters_web.dart):
#   - quickjs-emscripten@0.31.0 (dist/index.global.js; wasm is embedded
#     as a base64 data URL — one self-contained file)
#   - @jitl/quickjs-wasmfile-release-asyncify@0.31.0 (the ASYNC quickjs
#     variant — asyncify/ subdir: emscripten-module.browser.mjs +
#     emscripten-module.wasm + ffi.mjs with its bare import rewritten to
#     a vendored shim; enables `await fetch(...)` inside scripts via the
#     async runtime)
#   - pyodide v0.26.4 (pyodide.js + pyodide.asm.js + pyodide.asm.wasm +
#     python_stdlib.zip + pyodide-lock.json)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/browser_ext/vendor/interpreters"
QJS_BASE="https://cdn.jsdelivr.net/npm/quickjs-emscripten@0.31.0/dist"
QJS_ASYNC_BASE="https://cdn.jsdelivr.net/npm/@jitl/quickjs-wasmfile-release-asyncify@0.31.0/dist"
PYODIDE_BASE="https://cdn.jsdelivr.net/pyodide/v0.26.4/full"

FILES=(
  "$QJS_BASE/index.global.js"
  "$PYODIDE_BASE/pyodide.js"
  "$PYODIDE_BASE/pyodide.asm.js"
  "$PYODIDE_BASE/pyodide.asm.wasm"
  "$PYODIDE_BASE/python_stdlib.zip"
  "$PYODIDE_BASE/pyodide-lock.json"
  "$QJS_ASYNC_BASE/emscripten-module.browser.mjs"
  "$QJS_ASYNC_BASE/emscripten-module.wasm"
  "$QJS_ASYNC_BASE/ffi.mjs"
)

mkdir -p "$DEST" "$DEST/asyncify"
for url in "${FILES[@]}"; do
  name="$(basename "$url")"
  out="$DEST/$name"
  case "$url" in
    *quickjs-wasmfile-release-asyncify*) out="$DEST/asyncify/$name" ;;
  esac
  if [ -s "$out" ]; then
    echo "vendor: $name already present, skipping"
    continue
  fi
  echo "vendor: downloading $name"
  curl -fsSL "$url" -o "$out.tmp"
  mv "$out.tmp" "$out"
done

# ffi.mjs imports `@jitl/quickjs-ffi-types` (a bare specifier a browser
# page cannot resolve) — but it only needs assertSync from it. Rewrite
# the import onto a vendored one-function shim.
SHIM="$DEST/asyncify/ffi-types-shim.mjs"
if [ ! -s "$SHIM" ]; then
  cat > "$SHIM" <<'EOF'
// Vendored shim for the single @jitl/quickjs-ffi-types export the
// asyncify FFI module uses (scripts/vendor_interpreters.sh rewrites the
// bare import onto this file — a browser page cannot resolve npm
// specifiers). assertSync wraps an emscripten cwrap'd function and
// throws if it ever returns a thenable (i.e. an unexpected asyncify
// suspension on a path declared synchronous).
export function assertSync(fn) {
  return function (...args) {
    const result = fn.apply(this, args);
    if (result != null && typeof result.then === 'function') {
      throw new Error('assertSync: function returned a promise');
    }
    return result;
  };
}
EOF
fi
if grep -q 'from"@jitl/quickjs-ffi-types"' "$DEST/asyncify/ffi.mjs"; then
  sed -i.bak 's|from"@jitl/quickjs-ffi-types"|from"./ffi-types-shim.mjs"|' \
    "$DEST/asyncify/ffi.mjs"
  rm -f "$DEST/asyncify/ffi.mjs.bak"
fi
echo "vendor: interpreters ready in $DEST"
