#!/usr/bin/env bash
# Package browser_ext/ into build/fa-extension.zip (runtime files only:
# manifest, sw/, content/, panel/ — README, dart/ sources, test/, and
# compiled artifacts' side files stay out).
# `--with-app` first builds the Flutter web app (flutter_app/ → build/web) and
# bundles it as browser_ext/app/ so the side panel hosts the full fa app.
# browser_ext/app/ is a build artifact (gitignored, never committed).
# Compiles the embedded Dart agent first when a Dart SDK is available
# (scripts must FAIL LOUDLY on compile errors — CI always builds it).
# Without dart: a previously built sw/agent.js ships if present, else the
# zip is scaffold-only with a warning (never a failure).
# Runs green on ubuntu-latest and macOS: needs zip + python3|node|grep.
set -euo pipefail
cd "$(dirname "$0")/.."

with_app=0
case "${1:-}" in
  --with-app) with_app=1 ;;
  "") ;;
  *) echo "unknown option: $1 (usage: $0 [--with-app])" >&2; exit 1 ;;
esac

manifest=browser_ext/manifest.json

# The manifest carries // comments (Chrome's parser is lenient, strict
# JSON validators are not) — strip them before validating, the same
# regex test/browser_ext/chrome_driver.dart uses.
if command -v python3 >/dev/null 2>&1; then
  python3 -c '
import json, re, sys
raw = open(sys.argv[1]).read()
json.loads(re.sub(r"^\s*//.*$", "", raw, flags=re.M))
' "$manifest"
elif command -v node >/dev/null 2>&1; then
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8").replace(/^\s*\/\/.*$/gm, ""))' "$manifest"
else
  grep -q '"manifest_version"[[:space:]]*:[[:space:]]*3' "$manifest"
fi

# --- Vendored interpreter runtimes for the run_script tool (offscreen
# document). Extension CSP forbids remote scripts — these ship in-bundle. ---
"$(dirname "$0")/vendor_interpreters.sh"

# --- Embedded agent (dart2js). Output is a build artifact: never committed. ---
agent_js=browser_ext/sw/agent.js
if command -v dart >/dev/null 2>&1; then
  echo "building embedded agent (dart2js)…"
  ( cd browser_ext/dart \
    && dart pub get >/dev/null \
    && dart compile js -O2 -o ../sw/agent.js agent_main.dart )
  rm -f "${agent_js}.deps" "${agent_js}.map"
elif [ -f "$agent_js" ]; then
  echo "dart SDK not found — shipping prebuilt $agent_js"
else
  echo "WARNING: no dart SDK and no prebuilt sw/agent.js — scaffold-only zip (embedded agent disabled)"
fi

# --- Optional fa web app (flutter_app → browser_ext/app). Build artifact. ---
if [ "$with_app" -eq 1 ]; then
  if ! command -v flutter >/dev/null 2>&1; then
    echo "ERROR: --with-app passed but flutter is not installed — cannot build browser_ext/app/" >&2
    exit 1
  fi
  echo "building fa web app (flutter build web --release)…"
  # --base-href MUST match the panel-relative location: panel.js resolves
  # 'app/index.html' against panel/panel.html, so the bundle lives at
  # browser_ext/panel/app/ (a root-level copy is invisible to the panel).
  ( cd flutter_app && flutter pub get >/dev/null
    # .env is gitignored but declared as a Flutter asset (pubspec.yaml),
    # so the web build dies bundling it when the file is absent (#140).
    # Create it AFTER pub get — pub get removes a placeholder touched
    # earlier (runs 34593431895, 34596707238) — and keep it non-empty:
    # the populated placeholder is the shape build-macos.yml's app job
    # has shipped green. A real local .env (developer keys) is never
    # overwritten.
    if [ ! -f .env ]; then
      printf 'OPENROUTER_API_KEY=\nMODEL_ID=\nBASE_URL=\n' > .env
    fi
    FLUTTER_WEB_CANVASKIT_URL=./canvaskit/ \
    flutter build web --release --pwa-strategy=none --base-href=/panel/app/ \
      --dart-define=FA_HOST=extension )
  rm -rf browser_ext/panel/app
  mkdir -p browser_ext/panel/app
  cp -R flutter_app/build/web/. browser_ext/panel/app/
  # The extension CSP forbids remote hosts: point the bootstrap at the
  # bundled canvaskit copy (FLUTTER_WEB_CANVASKIT_URL does not reach the
  # generated bootstrap in this flutter).
  python3 - <<'PYS'
import glob
for f in glob.glob('flutter_app/build/web/flutter_bootstrap.js') + glob.glob('browser_ext/panel/app/flutter_bootstrap.js'):
    t = open(f).read()
    t = t.replace('https://www.gstatic.com/flutter-canvaskit/', './canvaskit/')
    t = t.replace('https:\\/\\/www.gstatic.com\\/flutter-canvaskit\\/', '.\\/canvaskit\\/')
    t = t.replace('"https://www.gstatic.com/flutter-canvaskit"', '"./canvaskit"')
    open(f, 'w').write(t)
PYS
  # The engine requests canvaskit under <engineRevision>/chromium/; the
  # build lays the copies flat — mirror the layout the bootstrap asks for.
  # Extract the FULL engine revision from the bootstrap config — a bounded
  # grep like [a-f0-9]{32} silently truncates the 40-char SHA1 and the
  # engine then 404s on canvaskit/<rev>/chromium/ (regression).
  REV=$(grep -o '"engineRevision":"[a-f0-9]*"' flutter_app/build/web/flutter_bootstrap.js | head -1 | sed 's/.*":"//;s/"//')
  if [ -n "$REV" ]; then
    if [ ${#REV} -ne 40 ]; then
      echo "FATAL: engineRevision '$REV' is not 40 hex chars" >&2
      exit 1
    fi
    # Copy from the BUILD OUTPUT, never from the bundle copy itself —
    # the rev dir lives inside the bundle copy, so self-copying there
    # recurses into itself (File name too long on the next run).
    mkdir -p "browser_ext/panel/app/canvaskit/$REV"
    cp -R "flutter_app/build/web/canvaskit/." "browser_ext/panel/app/canvaskit/$REV/"
    for f in canvaskit.js canvaskit.wasm; do
      [ -f "browser_ext/panel/app/canvaskit/$REV/chromium/$f" ] || {
        echo "FATAL: canvaskit/$REV/chromium/$f missing after mirror" >&2
        exit 1
      }
    done
    echo "canvaskit mirrored to canvaskit/$REV/chromium/ (verified)"
  else
    echo "FATAL: engineRevision not found in flutter_bootstrap.js" >&2
    exit 1
  fi
  # The extension CSP forbids remote scripts, and the fa web bundle's
  # on-device provider loaders (inline_script_4/5/6.js) import WebLLM /
  # transformers.js / LiteRT-LM from cdn.jsdelivr.net — every panel open
  # sprayed CSP violations (and litert's rejected import threw an uncaught
  # promise error). On-device providers are not an extension feature (the
  # engine is the SW relay provider), so swap the three loader tags for a
  # local stub that mirrors their failure shape: `window.litertLmReady`
  # rejects immediately (the Dart side awaits that promise — an unsettled
  # one would hang provider init; a rejection is the state those loaders
  # already reach behind the CSP), webllm/transformersjs stay undefined.
  python3 - <<'PYS'
import re
p = 'browser_ext/panel/app/index.html'
t = open(p).read()
if 'ondevice_stub.js' not in t:
    t2, n = re.subn(
        r'<script type="module" src="inline_script_[456]\.js"></script>\n?',
        '', t)
    if n == 0:
        raise SystemExit('FATAL: no on-device loader tags found in ' + p)
    stub = ('  <!-- On-device provider loaders (WebLLM / transformers.js /\n'
            '       LiteRT-LM from jsdelivr) are stripped here: the extension\n'
            '       CSP forbids remote scripts and the panel engine is the SW\n'
            '       relay provider. ondevice_stub.js mirrors their failure\n'
            '       shape (litertLmReady rejects at once) so provider init\n'
            '       fails fast instead of hanging. -->\n'
            '  <script type="module" src="ondevice_stub.js"></script>\n')
    marker = '<script src="flutter_bootstrap.js" async></script>'
    assert marker in t2, 'bootstrap tag not found'
    t2 = t2.replace(marker, stub + marker, 1)
    open(p, 'w').write(t2)
    open('browser_ext/panel/app/ondevice_stub.js', 'w').write(
        "// Extension CSP: no remote scripts. See the note in index.html —\n"
        "// this mirrors the CDN loaders' failure shape so the Dart side's\n"
        "// awaited litertLmReady promise rejects immediately.\n"
        "const litertLmUnavailable = Promise.reject(\n"
        "  new Error('on-device providers unavailable in the extension (CSP)'),\n"
        ");\n"
        "// Mark the rejection handled so the console stays clean; awaiters\n"
        "// still get the rejection (fail fast instead of hanging).\n"
        "litertLmUnavailable.catch(() => {});\n"
        "window.litertLmReady = litertLmUnavailable;\n")
    print(f'on-device loaders stripped from the extension panel ({n} tags)')
PYS
  echo "bundled fa web app (browser_ext/panel/app/)"
fi

mkdir -p build
rm -f build/fa-extension.zip
if command -v zip >/dev/null 2>&1; then
  runtime="manifest.json sw content panel icons offscreen.html offscreen vendor"
  # panel/app rides inside the panel/ dir — no separate root entry.
  ( cd browser_ext && zip -qr ../build/fa-extension.zip $runtime \
      -x 'sw/agent.js.map' 'sw/agent.js.deps' )
else
python3 - <<'PY'
import os, zipfile
RUNTIME_DIRS = ("sw", "content", "panel", "icons", "offscreen", "vendor")
SKIP_NAMES = {"README.md", "agent.js.map", "agent.js.deps"}
with zipfile.ZipFile("build/fa-extension.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.write("browser_ext/manifest.json", "manifest.json")
    z.write("browser_ext/offscreen.html", "offscreen.html")
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

# Keep an unpacked copy beside the zip: load THIS directory once via
# chrome://extensions -> "Load unpacked"; after every rebuild a single
# extension Reload picks the new build up.
rm -rf build/fa-extension
python3 - <<'PY'
import zipfile
with zipfile.ZipFile("build/fa-extension.zip") as z:
    z.extractall("build/fa-extension")
PY
echo "build/fa-extension/ (unpacked — load this in chrome://extensions)"
