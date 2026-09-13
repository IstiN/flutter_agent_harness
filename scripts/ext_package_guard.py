#!/usr/bin/env python3
"""Extension packaging hygiene guard (issue #291).

Chrome Web Store hard-rejects any package with more than one manifest
("More than one manifest found in package: manifest.json,
panel/app/manifest.json") — the exact failure that killed the 2026-09-13
fa-extension.zip upload: the Flutter web build staged under
browser_ext/panel/app ships its own PWA manifest. This script encodes the
store's structural rules as build-time assertions so that whole failure
class dies in CI (and locally), never again at upload.

Two verbs, both wired from scripts/build_browser_ext.sh:

  strip <dir>   Remove the PWA manifest from a STAGED app dir (the
                gitignored browser_ext/panel/app copy — sources in
                flutter_app/web stay untouched): deletes manifest.json and
                drops the <link rel="manifest"> tag from index.html.
                Idempotent (a Flutter template without the tag is a no-op,
                #291 E3). DELETION, not a rename to .webmanifest: inside
                an extension page the PWA manifest is functionally dead
                (extension pages are not installable PWAs, and the CSP
                blocks nothing the manifest needs) — a rename would pass
                the store while shipping dead weight and keeping a link
                nothing consumes.

  check <zip>   Assert the packaged zip's CWS shape and fail loudly:
                  - exactly one manifest.json, at the archive root
                  - no duplicate entry names
                  - no .DS_Store / __MACOSX junk entries
                  - no empty directory entries
                  - the root manifest parses and is manifest_version 3
                  - every icon the root manifest references exists in zip

Errors print as GitHub Actions annotations (::error ...) — rendered by
CI, plain readable text locally — and exit non-zero, failing the build.
"""

import json
import os
import re
import sys

# E2 escape hatch: a future LEGIT nested manifest (e.g. a packaged
# sub-extension) must be allowlisted HERE, in reviewable source, never
# silently. Any manifest.json not at the root and not in this list fails
# the build on purpose.
ALLOW_NESTED_MANIFESTS: "list[str]" = []


def error(rule: str, detail: str) -> None:
    """One ::error workflow-command line; single-line by contract."""
    print(f"::error title={rule}::{detail}", file=sys.stderr)


def cmd_strip(staged_dir: str) -> int:
    index_path = os.path.join(staged_dir, "index.html")
    if not os.path.isfile(index_path):
        error(
            "ext-package-strip",
            f"strip: {staged_dir}/index.html not found — the staged app "
            "dir is malformed (the Flutter web build always emits one)",
        )
        return 1

    # 1) Delete the nested PWA manifest (missing already → fine, E3).
    manifest_path = os.path.join(staged_dir, "manifest.json")
    removed_manifest = False
    if os.path.isfile(manifest_path):
        os.remove(manifest_path)
        removed_manifest = True

    # 2) Drop the <link rel="manifest"> tag — any attribute order, single
    #    or double quotes. Zero matches → no-op (E3: a Flutter template
    #    change that drops the tag must not fail the build).
    html = open(index_path, encoding="utf-8").read()
    html2, n = re.subn(r'<link\b[^>]*\brel=["\']manifest["\'][^>]*>\s*', "", html)
    if n:
        open(index_path, "w", encoding="utf-8").write(html2)

    what = []
    if removed_manifest:
        what.append("manifest.json deleted")
    if n:
        what.append(f"{n} <link rel=manifest> tag(s) dropped")
    print(
        "strip: " + ("; ".join(what) if what else "nothing to strip (clean)")
        + f" [{staged_dir}]"
    )
    return 0


def cmd_check(zip_path: str) -> int:
    import zipfile

    if not os.path.isfile(zip_path):
        error("ext-package-check", f"check: zip not found: {zip_path}")
        return 1

    failures = 0
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()

        # --- single root manifest (THE CWS rule, #291) ------------------
        manifests = sorted(n for n in names if os.path.basename(n) == "manifest.json")
        allowed = {"manifest.json", *ALLOW_NESTED_MANIFESTS}
        offenders = [m for m in manifests if m not in allowed]
        if "manifest.json" not in names or offenders:
            error(
                "single-manifest (CWS)",
                f"{zip_path}: {len(manifests)} manifest.json entries — the "
                "Chrome Web Store rejects any package with more than one "
                f"manifest (and it must be at the root): {', '.join(manifests) or 'none found'}. "
                "Strip nested PWA manifests in packaging; a legit nested "
                "manifest needs an explicit ALLOW_NESTED_MANIFESTS entry.",
            )
            failures += 1

        # --- duplicate entry names (appending zip tooling) --------------
        dupes = sorted({n for n in names if names.count(n) > 1})
        if dupes:
            error(
                "duplicate-entries",
                f"{zip_path}: duplicate entry names: {', '.join(dupes)}",
            )
            failures += 1

        # --- junk entries -----------------------------------------------
        junk = sorted(
            n for n in names if os.path.basename(n) == ".DS_Store" or n.startswith("__MACOSX/")
        )
        if junk:
            error(
                "zip-junk",
                f"{zip_path}: store-hostile junk entries: {', '.join(junk)}",
            )
            failures += 1

        # --- empty directories ------------------------------------------
        empty_dirs = sorted(
            n
            for n in names
            if n.endswith("/") and not any(o.startswith(n) and o != n for o in names)
        )
        if empty_dirs:
            error(
                "empty-dirs",
                f"{zip_path}: empty directory entries: {', '.join(empty_dirs)}",
            )
            failures += 1

        # --- root manifest shape: MV3 parse + icons exist ---------------
        if "manifest.json" in names:
            raw = z.read("manifest.json").decode("utf-8")
            # The manifest carries // comments (Chrome's parser is lenient,
            # strict JSON validators are not) — same strip as the build
            # script's pre-zip validation.
            commented = re.sub(r"^\s*//.*$", "", raw, flags=re.M)
            try:
                manifest = json.loads(commented)
            except json.JSONDecodeError as e:
                error(
                    "manifest-parse",
                    f"{zip_path}: root manifest.json does not parse: {e}",
                )
                manifest = None
            if isinstance(manifest, dict):
                if manifest.get("manifest_version") != 3:
                    error(
                        "manifest-mv3",
                        f"{zip_path}: root manifest.json manifest_version="
                        f"{manifest.get('manifest_version')!r} — the store "
                        "requires 3",
                    )
                    failures += 1
                icons: "set[str]" = set()
                top = manifest.get("icons")
                if isinstance(top, dict):
                    icons.update(str(v) for v in top.values() if isinstance(v, str))
                action = manifest.get("action")
                if isinstance(action, dict):
                    di = action.get("default_icon")
                    if isinstance(di, str):
                        icons.add(di)
                    elif isinstance(di, dict):
                        icons.update(str(v) for v in di.values() if isinstance(v, str))
                missing = sorted(i for i in icons if i not in names)
                if missing:
                    error(
                        "manifest-icons",
                        f"{zip_path}: icons referenced by the root manifest "
                        f"missing from the zip: {', '.join(missing)}",
                    )
                    failures += 1

    if failures:
        error(
            "ext-package-check",
            f"{zip_path}: {failures} packaging-shape failure(s) — fix the "
            "build, do not upload this zip (Chrome Web Store would reject "
            "it)",
        )
        return 1

    print(
        f"check: {zip_path} OK — single root manifest.json (MV3), "
        f"{len(names)} entries, icons present, no junk"
    )
    return 0


def main() -> int:
    args = sys.argv[1:]
    if len(args) != 2 or args[0] not in ("strip", "check"):
        print(
            "usage: ext_package_guard.py strip <staged-app-dir> | "
            "check <zip>",
            file=sys.stderr,
        )
        return 2
    return cmd_strip(args[1]) if args[0] == "strip" else cmd_check(args[1])


if __name__ == "__main__":
    sys.exit(main())
