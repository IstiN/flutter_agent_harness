#!/usr/bin/env python3
"""gh-1630 — stage the on-device engine loaders for the extension panel app.

The plain web build (fa1.dev, Office taskpane) loads WebLLM /
transformers.js / LiteRT-LM from the jsdelivr `+esm` CDN via
flutter_app/web/inline_script_4/5/6.js. The extension package must carry
NO remote code (CWS Blue Argon), and its CSP blocks remote scripts anyway
— so `build_browser_ext.sh` stages the panel app copy and this script
rewrites its index.html to load the SAME engines from the package-local,
checksum-pinned vendor dir instead (browser_ext/vendor/<engine>/<version>/,
fetched by scripts/fetch_vendor_assets.sh from browser_ext/vendor.lock.json).

What it does (idempotent — safe to re-run over an already-staged tree):

  1. drops the three CDN `inline_script_[456].js` module tags (and any
     leftover on-device stub from the pre-gh-1630 staging);
  2. writes vendor_loader_{webllm,transformers,litert}.js module files
     next to index.html — byte-for-byte the same `window.*` installs the
     CDN scripts perform, imported from ../../vendor/…;
  3. injects the three loader tags before the flutter bootstrap tag.

The engine versions come from browser_ext/vendor.lock.json (single source
of truth) — a lock/layout drift fails loud here, not at store review.

Usage: stage_extension_panel.py --app-dir <staged panel app dir>
"""

import argparse
import json
import os
import re
import sys


def error(detail: str) -> None:
    print(f"::error title=stage-extension-panel::{detail}", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app-dir", required=True)
    args = ap.parse_args()
    app_dir = args.app_dir
    index_path = os.path.join(app_dir, "index.html")
    if not os.path.isfile(index_path):
        error(f"strip/stage: {index_path} not found — the staged app dir "
              "is malformed (the Flutter web build always emits one)")
        return 1

    here = os.path.dirname(os.path.abspath(__file__))
    lock_path = os.path.join(here, os.pardir, "browser_ext", "vendor.lock.json")
    try:
        with open(lock_path, encoding="utf-8") as f:
            lock = json.load(f)
        webllm_v = lock["engines"]["webllm"]["version"]
        transformers_v = lock["engines"]["transformers"]["version"]
        litert_v = lock["engines"]["litert"]["version"]
    except (OSError, ValueError, KeyError) as e:
        error(f"vendor.lock.json unreadable/incomplete ({e}) — run "
              "scripts/fetch_vendor_assets.sh first; the loader paths must "
              "come from the lock, never be hardcoded")
        return 1

    html = open(index_path, encoding="utf-8").read()

    # 1) Drop the CDN loader tags (attribute order agnostic), the old
    #    on-device stub tag, and any stale loader tags (idempotency).
    html, n_cdn = re.subn(
        r'<script type="module" src="inline_script_[456]\.js"></script>\s*',
        "", html)
    html, n_stub = re.subn(
        r'<script type="module" src="ondevice_stub\.js"></script>\s*',
        "", html)
    html, n_prev = re.subn(
        r'<script type="module" src="vendor_loader_[a-z]+\.js"></script>\s*',
        "", html)

    loaders = {
        "vendor_loader_webllm.js": (
            "// gh-1630: on-device WebLLM from the package-local vendor dir\n"
            "// (checksum-pinned in browser_ext/vendor.lock.json) — the\n"
            "// extension CSP forbids and CWS forbids shipping the CDN\n"
            "// import the web build uses. Same window.webllm install as\n"
            "// flutter_app/web/inline_script_4.js.\n"
            f"import * as webllm from '../../vendor/webllm/{webllm_v}/webllm.mjs';\n"
            "window.webllm = webllm;\n"
        ),
        "vendor_loader_transformers.js": (
            "// gh-1630: on-device transformers.js from the package-local\n"
            "// vendor dir (ORT wasm files ride the same dir; the vendored\n"
            "// bundle's default wasmPaths was rewritten onto it by the\n"
            "// fetch step). Same window.transformersjs install as\n"
            "// flutter_app/web/inline_script_5.js.\n"
            "import * as transformersjs from "
            f"'../../vendor/transformers/{transformers_v}/transformers.min.js';\n"
            "window.transformersjs = transformersjs;\n"
        ),
        "vendor_loader_litert.js": (
            "// gh-1630: LiteRT-LM from the package-local vendor dir. Same\n"
            "// awaited window.litertLmReady handshake as\n"
            "// flutter_app/web/inline_script_6.js — a failed local import\n"
            "// rejects it, which is the state the Dart side already\n"
            "// handles (fail fast instead of hanging).\n"
            "window.litertLmReady = (async () => {\n"
            f"  const m = await import('../../vendor/litert/{litert_v}/litert.mjs');\n"
            "  window.Engine = m.Engine;\n"
            "  return m.Engine;\n"
            "})();\n"
        ),
    }

    # 2) Write the loader files.
    for name, body in loaders.items():
        with open(os.path.join(app_dir, name), "w", encoding="utf-8") as f:
            f.write(body)

    # 3) Inject the three loader tags before the bootstrap tag.
    loader_tags = "".join(
        f'  <script type="module" src="{name}"></script>\n'
        for name in loaders
    )
    marker = '<script src="flutter_bootstrap.js" async></script>'
    if marker not in html:
        error("flutter bootstrap tag not found in " + index_path)
        return 1
    html = html.replace(
        marker, loader_tags + "  " + marker, 1)

    # 4) Local sanity: the staged index must not carry remote-code markers.
    leftover = re.findall(r"jsdelivr|unpkg|cdnjs|https://cdn\.", html)
    if leftover:
        error(f"{index_path} still carries remote-code markers after "
              f"staging: {leftover[:3]}")
        return 1

    # 5) The obsolete stub file must not ship.
    stub = os.path.join(app_dir, "ondevice_stub.js")
    if os.path.isfile(stub):
        os.remove(stub)

    open(index_path, "w", encoding="utf-8").write(html)
    print(f"on-device loaders staged from the vendor dir "
          f"(cdn tags removed: {n_cdn}, stub tags removed: {n_stub}, "
          f"previous loader tags removed: {n_prev})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
