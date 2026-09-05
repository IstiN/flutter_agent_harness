#!/usr/bin/env bash
# Package browser_ext/ into build/fa-extension.zip (README excluded).
# Compiles the embedded Dart agent first when a Dart SDK is available
# (scripts must FAIL LOUDLY on compile errors — CI always builds it).
# Without dart: a previously built sw/agent.js ships if present, else the
# zip is scaffold-only with a warning (never a failure).
# Runs green on ubuntu-latest and macOS: needs zip + python3|node|grep.
set -euo pipefail
cd "$(dirname "$0")/.."

manifest=browser_ext/manifest.json

if command -v python3 >/dev/null 2>&1; then
  python3 -m json.tool "$manifest" >/dev/null
elif command -v node >/dev/null 2>&1; then
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$manifest"
else
  grep -q '"manifest_version"[[:space:]]*:[[:space:]]*3' "$manifest"
fi

# --- Embedded agent (dart2js). Output is a build artifact: never committed. ---
agent_js=browser_ext/sw/agent.js
if command -v dart >/dev/null 2>&1; then
  echo "building embedded agent (dart2js)…"
  ( cd browser_ext/dart \
    && dart pub get >/dev/null \
    && dart compile js -O2 -o ../sw/agent.js agent_main.dart )
  rm -f "${agent_js}.deps"
elif [ -f "$agent_js" ]; then
  echo "dart SDK not found — shipping prebuilt $agent_js"
else
  echo "WARNING: no dart SDK and no prebuilt sw/agent.js — scaffold-only zip (embedded agent disabled)"
fi

mkdir -p build
rm -f build/fa-extension.zip
if command -v zip >/dev/null 2>&1; then
  ( cd browser_ext && zip -qr ../build/fa-extension.zip . -x 'README.md' )
else
  python3 - <<'PY'
import os, zipfile
with zipfile.ZipFile("build/fa-extension.zip", "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk("browser_ext"):
        for f in files:
            if root == "browser_ext" and f == "README.md":
                continue
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, "browser_ext"))
PY
fi

echo "build/fa-extension.zip: $(wc -c < build/fa-extension.zip) bytes"
