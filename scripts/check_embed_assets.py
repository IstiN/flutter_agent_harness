#!/usr/bin/env python3
"""Embedded-pane asset guard (issue #470).

The office taskpane IS the fa web app; its persistence (sessions, provider
config, keys) rides web/fs_store.js, which index.html must load with a plain
`<script src="fs_store.js">` tag. The 2026-09-16 owner capture (issue #470,
grounding 2) showed the embedded pane booting with the helper missing —
"[fah] sandbox persist failed … fs_store.js is not loaded" — and every boot
after that created a fresh session. This script encodes the invariant as a
build-time assertion so the failure class dies in CI, never in Outlook:

  check <appdir>  Assert the staged app dir (build/pages/root/outlook/app)
                  is shippable:
                  - index.html references fs_store.js via <script src>
                  - fs_store.js exists next to index.html
                  - the helper defines window.__fahFsGetAll (the exact symbol
                    fs_persistence_web.dart probes)

Errors print as GitHub Actions annotations (::error ...) — rendered by CI,
plain readable text locally — and exit non-zero, failing the build.
"""

import os
import sys


def error(rule: str, detail: str) -> None:
    print(f"::error {rule}: {detail}", file=sys.stderr)
    print(f"check_embed_assets: FAIL {rule}: {detail}", file=sys.stderr)


def check(appdir: str) -> int:
    failures = 0

    index = os.path.join(appdir, "index.html")
    try:
        html = open(index, encoding="utf-8").read()
    except OSError as e:
        error("index.html", f"unreadable: {e}")
        return 1

    if '<script src="fs_store.js">' not in html:
        error(
            "fs_store.js tag",
            f"{index} has no <script src=\"fs_store.js\"> — persistence "
            "dead-on-arrival (issue #470 grounding 2)",
        )
        failures += 1

    helper = os.path.join(appdir, "fs_store.js")
    if not os.path.isfile(helper):
        error(
            "fs_store.js file",
            f"{helper} missing — the tag would 404 and persistence stays "
            "dead (issue #470)",
        )
        failures += 1
    else:
        body = open(helper, encoding="utf-8").read()
        if "__fahFsGetAll" not in body:
            error(
                "fs_store.js symbol",
                f"{helper} does not define __fahFsGetAll — the probe in "
                "fs_persistence_web.dart would still fail",
            )
            failures += 1

    if failures:
        print(
            f"check_embed_assets: {failures} failure(s) in {appdir}",
            file=sys.stderr,
        )
        return 1
    print(f"check_embed_assets: {appdir} OK (fs_store.js tag + file + symbol)")
    return 0


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] != "check":
        print("usage: check_embed_assets.py check <appdir>", file=sys.stderr)
        return 2
    return check(sys.argv[2])


if __name__ == "__main__":
    sys.exit(main())
