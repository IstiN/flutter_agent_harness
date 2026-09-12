#!/usr/bin/env bash
# Assemble the Office add-in site slice into build/pages/root/outlook/
# (issues #89, #182): manifest, the Flutter web app bundle (outlook/app/ —
# the taskpane IS the fa app), the one-release redirect shim, support /
# privacy pages and icons. Build artifact — never committed. Fail loudly:
# manifest validation errors and flutter build errors abort the build.
# `--dev` rewrites every https://fa1.dev URL to https://localhost:8443
# and validates the REWRITTEN manifest (what will actually ship).
# Runs green on ubuntu-latest and macOS: needs bash + dart + flutter +
# python3 (the app bundle is mandatory now — the pane has no other
# surface).
set -euo pipefail
cd "$(dirname "$0")/.."

dev=0
for arg in "$@"; do
  case "$arg" in
    --dev) dev=1 ;;
    *) echo "unknown option: $arg (usage: $0 [--dev])" >&2; exit 1 ;;
  esac
done

manifest=office_addin/manifest/outlook.xml
out=build/pages/root/outlook

# --- 1. Assemble + validate the manifest exactly as it will ship. ---
rm -rf "$out"
mkdir -p "$out/icons"
if [ "$dev" -eq 1 ]; then
  sed 's|https://fa1.dev|https://localhost:8443|g' "$manifest" > "$out/manifest.xml"
else
  cp "$manifest" "$out/manifest.xml"
fi
dev_flag=""
if [ "$dev" -eq 1 ]; then dev_flag="--dev"; fi
( cd office_addin/dart \
  && dart pub get >/dev/null \
  && dart run tool/validate_manifest.dart "../../$out/manifest.xml" $dev_flag )

# --- 2. Static pages + icons (index.html is a redirect shim kept one
# release so existing sideloaded manifests land on the app). ---
cp office_addin/web/index.html office_addin/web/privacy.html office_addin/web/support.html "$out/"
cp office_addin/icons/fa-16.png office_addin/icons/fa-32.png office_addin/icons/fa-80.png office_addin/icons/fa-64.png office_addin/icons/fa-128.png "$out/icons/"

# --- 3. The fa web app (flutter_app → outlook/app) — MANDATORY. ---
if ! command -v flutter >/dev/null 2>&1; then
  echo "ERROR: flutter is not installed — cannot build outlook/app/" >&2
  exit 1
fi
echo "building fa web app (flutter build web --release)…"
# --base-href MUST match the taskpane URL: the pane opens
# /outlook/app/index.html directly (manifest 1.2.0.0), so the bundle
# lives at build/pages/root/outlook/app/.
( cd flutter_app && flutter pub get >/dev/null && \
  FLUTTER_WEB_CANVASKIT_URL=./canvaskit/ \
  flutter build web --release --pwa-strategy=none --base-href=/outlook/app/ \
    --dart-define=FA_HOST=office )
rm -rf "$out/app"
mkdir -p "$out/app"
cp -R flutter_app/build/web/. "$out/app/"

# fa1.dev is a hosted page (no extension CSP): CDN scripts are allowed,
# but the canvaskit copy still must mirror the layout the bootstrap
# asks for — same blocks as build_browser_ext.sh.
python3 - <<'PYS'
import glob
for f in glob.glob('flutter_app/build/web/flutter_bootstrap.js') + glob.glob('build/pages/root/outlook/app/flutter_bootstrap.js'):
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
  mkdir -p "build/pages/root/outlook/app/canvaskit/$REV"
  cp -R "flutter_app/build/web/canvaskit/." "build/pages/root/outlook/app/canvaskit/$REV/"
  for f in canvaskit.js canvaskit.wasm; do
    [ -f "build/pages/root/outlook/app/canvaskit/$REV/chromium/$f" ] || {
      echo "FATAL: canvaskit/$REV/chromium/$f missing after mirror" >&2
      exit 1
    }
  done
  echo "canvaskit mirrored to canvaskit/$REV/chromium/ (verified)"
else
  echo "FATAL: engineRevision not found in flutter_bootstrap.js" >&2
  exit 1
fi

# --- 4. Office host wiring inside the app page (issue #182). ---
# (a) Office.js from the official CDN, BEFORE the flutter bootstrap so
#     Office.initialize/onReady is defined when the app's JsOfficeApi
#     facade calls into it. (b) The pane CSP as a meta tag — pinned
#     without 'unsafe-inline' for scripts: helper code rides blob: URLs
#     (web_interpreters_web.dart); connect-src is open because provider
#     endpoints are user-configured arbitrary origins; script-src allows
#     jsdelivr (quickjs / pyodide / sql.js / webllm / transformers) and
#     appsforoffice.microsoft.com. NOTE: frame-ancestors is NOT
#     enforceable via meta (only via an HTTP header, which GitHub Pages
#     cannot set) — Outlook's own taskpane framing relies on Outlook's
#     sandboxing, documented in docs/outlook-addin.md.
python3 - "$out/app/index.html" <<'PYS'
import re, sys

path = sys.argv[1]
html = open(path).read()

office_script = (
    '<!-- Office.js (official CDN) — the mail bridge the fa app calls '
    '(issue #182). Must precede the flutter bootstrap. -->\n'
    '  <script src="https://appsforoffice.microsoft.com/lib/1/hosted/office.js"></script>\n'
)
csp = (
    '  <!-- Pane CSP (meta-only: GitHub Pages cannot set headers; '
    'frame-ancestors is unenforceable via meta — see docs/outlook-addin.md). -->\n'
    '  <meta http-equiv="Content-Security-Policy" content="'
    "default-src 'self'; "
    "script-src 'self' 'wasm-unsafe-eval' blob: "
    'https://appsforoffice.microsoft.com https://cdn.jsdelivr.net; '
    "style-src 'self' 'unsafe-inline'; "
    "img-src 'self' data: blob:; "
    "font-src 'self' data:; "
    "worker-src 'self' blob:; "
    'connect-src * data: blob:; '
    "media-src 'self' blob: data:; "
    'frame-src \'self\' blob: data: about:\'" />'
)

if 'appsforoffice.microsoft.com' in html:
    print(f'FATAL: {path} already wired (office.js present) — rebuild from a clean bundle')
    sys.exit(1)
html, n_boot = re.subn(
    r'([ \t]*)<script src="flutter_bootstrap\.js"',
    lambda m: m.group(1) + office_script + m.group(1) + '<script src="flutter_bootstrap.js"',
    html, count=1)
html, n_meta = re.subn(r'</head>', csp + '\n</head>', html, count=1)
if n_boot != 1 or n_meta != 1:
    print(f'FATAL: injection anchors not found in {path} (bootstrap={n_boot}, head={n_meta})')
    sys.exit(1)
open(path, 'w').write(html)
print('injected office.js + pane CSP into', path)
PYS

echo "bundled fa web app (build/pages/root/outlook/app/)"

echo "assembled $out/:"
find "$out" -type f | sort | while read -r f; do
  printf '%8d  %s\n' "$(wc -c < "$f")" "${f#"$out"/}"
done
