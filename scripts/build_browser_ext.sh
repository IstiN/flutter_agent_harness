#!/usr/bin/env bash
# Package browser_ext/ into build/fa-extension.zip (runtime files only:
# manifest, sw/, content/, panel/ — README, dart/ sources, test/, and
# compiled artifacts' side files stay out).
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
  ( cd browser_ext && zip -qr ../build/fa-extension.zip \
      manifest.json sw content panel \
      -x 'sw/agent.js.map' 'sw/agent.js.deps' )
else
  python3 - <<'PY'
import os, zipfile
RUNTIME_DIRS = ("sw", "content", "panel")
SKIP_NAMES = {"README.md", "agent.js.map", "agent.js.deps"}
with zipfile.ZipFile("build/fa-extension.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.write("browser_ext/manifest.json", "manifest.json")
    for d in RUNTIME_DIRS:
        for root, _, files in os.walk(os.path.join("browser_ext", d)):
            for f in files:
                if f in SKIP_NAMES:
                    continue
                p = os.path.join(root, f)
                z.write(p, os.path.relpath(p, "browser_ext"))
PY
fi

echo "build/fa-extension.zip: $(wc -c < build/fa-extension.zip) bytes"
