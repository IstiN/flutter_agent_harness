#!/usr/bin/env bash
# Assemble the Office add-in site slice into build/pages/root/outlook/
# (issue #89): manifest, taskpane page, support/privacy pages, icons and
# the compiled Dart agent (office_agent.js). Build artifact — never
# committed. Fail loudly: manifest validation errors and dart2js compile
# errors abort the build (CI always compiles).
# `--dev` rewrites every https://fa1.dev URL to https://localhost:8443
# and validates the REWRITTEN manifest (what will actually ship).
# `--with-app` builds the Flutter web app and bundles it as outlook/app/
# so the taskpane hosts the full fa app (bundled LAST: it must not be
# wiped by the assemble step).
# Runs green on ubuntu-latest and macOS: needs bash + dart + python3.
set -euo pipefail
cd "$(dirname "$0")/.."

with_app=0
dev=0
for arg in "$@"; do
  case "$arg" in
    --with-app) with_app=1 ;;
    --dev) dev=1 ;;
    *) echo "unknown option: $arg (usage: $0 [--with-app] [--dev])" >&2; exit 1 ;;
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

# --- 2. Embedded agent (dart2js). Output is a build artifact. ---
agent_js=office_addin/web/office_agent.js
echo "building office agent (dart2js)…"
( cd office_addin/dart \
  && dart compile js -O2 -o ../web/office_agent.js office_main.dart )
rm -f "${agent_js}.deps" "${agent_js}.map"
cp "$agent_js" "$out/"

# --- 3. Static pages + icons. ---
cp office_addin/web/index.html office_addin/web/privacy.html office_addin/web/support.html "$out/"
cp office_addin/icons/fa-64.png office_addin/icons/fa-128.png "$out/icons/"

# --- 4. Optional fa web app (flutter_app → outlook/app). Build artifact. ---
if [ "$with_app" -eq 1 ]; then
  if ! command -v flutter >/dev/null 2>&1; then
    echo "ERROR: --with-app passed but flutter is not installed — cannot build outlook/app/" >&2
    exit 1
  fi
  echo "building fa web app (flutter build web --release)…"
  # --base-href MUST match the taskpane-relative location: index.html
  # resolves 'app/index.html' against outlook/index.html, so the bundle
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
  echo "bundled fa web app (build/pages/root/outlook/app/)"
fi

echo "assembled $out/:"
find "$out" -type f | sort | while read -r f; do
  printf '%8d  %s\n' "$(wc -c < "$f")" "${f#"$out"/}"
done
