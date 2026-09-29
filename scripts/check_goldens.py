#!/usr/bin/env python3
"""Golden-test gate for flutter_app.

Verifies that golden (screenshot) tests exist and are up to date:

  1. test/golden/goldens/ holds generated snapshots (*.png);
  2. every committed snapshot is still REFERENCED by a golden test
     (orphan check — deleted widgets/tests must not leave stale PNGs
     rotting in the repo and in git history);
  3. every lib/ widget file has golden coverage (enforced by
     test/golden/golden_guard_test.dart — this script runs it plus the
     golden suite, unless --quick is passed, in which case only the
     snapshot-existence and orphan checks run).

Usage:
  python3 scripts/check_goldens.py           # full: run the golden suite
  python3 scripts/check_goldens.py --quick   # existence + orphan checks only

Regenerate snapshots after intentional UI changes:
  cd flutter_app && flutter test test/golden --update-goldens
…then REVIEW every changed PNG before committing.
"""

import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_DIR = os.path.join(REPO_ROOT, "flutter_app")
GOLDENS_DIR = os.path.join(APP_DIR, "test", "golden", "goldens")
GUARD_TEST = os.path.join(APP_DIR, "test", "golden", "golden_guard_test.dart")
GOLDEN_TESTS_DIR = os.path.join(APP_DIR, "test", "golden")
# Committed PTY reference fixtures (issue #810, S7): the omp reference
# captures are the ONLY tracked files under the PTY screenshots dir (the
# runtime screenshot outputs are gitignored, issue #860) — the orphan guard
# covers them so a renamed/dropped scenario never leaves dead PNGs/TXTs.
PTY_SHOTS_DIR = os.path.join(REPO_ROOT, "test", "integration", "screenshots")
PTY_SOURCE_DIRS = [
    GOLDEN_TESTS_DIR,
    os.path.join(APP_DIR, "test", "cli_visual"),
    os.path.join(REPO_ROOT, "test", "cli"),
]

# Single-line quoted string literal carrying an interpolation (multi-line
# scanning would mispair on apostrophes inside comments; golden names are
# always single-line).
_STRING_LITERAL = re.compile(r"'([^'\n]*\$[^'\n]*)'|\"([^\"\n]*\$[^\"\n]*)\"")
# Dart interpolation inside a literal: $identifier or ${expression}.
_INTERPOLATION = re.compile(r"\$[A-Za-z_]\w*|\$\{[^}]*\}")


def golden_name_patterns(sources: str) -> list[re.Pattern[str]]:
    """Regexes for golden names built by string interpolation.

    Tests compose snapshot names like 'chat_header_${width.round()}' or
    'chat_bubble_1_image_$suffix' — a verbatim substring search can never
    see the generated PNG stems, so interpolated literals become regexes
    with each interpolation matching any non-quote run.
    """
    patterns = []
    for match in _STRING_LITERAL.finditer(sources):
        literal = match.group(1) if match.group(1) is not None else match.group(2)
        # A pure-interpolation literal ('$suffix') would degrade to a
        # match-everything pattern and whitelist every root-level golden
        # stem — skip literals without a usable literal anchor.
        if len(_INTERPOLATION.sub("", literal).strip()) < 3:
            continue
        # Substitute BEFORE escaping so re.escape does not mangle the $.
        regex = re.escape(_INTERPOLATION.sub("\x00", literal)).replace(
            "\x00", "[^'/]+"
        )
        patterns.append(re.compile(f"^{regex}$"))
    return patterns


def fail(msg: str) -> int:
    print(f"ERROR: {msg}")
    print()
    print("Golden tests keep the UI pixel-stable. To fix:")
    print("  1. Write/extend tests in flutter_app/test/golden/ (see")
    print("     golden_test_helper.dart) for every widget you added or changed.")
    print("  2. Regenerate snapshots:")
    print("     cd flutter_app && flutter test test/golden --update-goldens")
    print("  3. Review every changed/added PNG, then rerun this script.")
    return 1


def collect_source_text() -> str:
    """All golden-related Dart sources in one blob (tests + the store
    marketing frame, which carries the dynamic store shot names)."""
    chunks = []
    for root, _dirs, files in os.walk(GOLDEN_TESTS_DIR):
        for name in files:
            if name.endswith(".dart"):
                with open(os.path.join(root, name), encoding="utf-8") as fh:
                    chunks.append(fh.read())
    return "\n".join(chunks)


def find_orphan_snapshots() -> list[str]:
    """Committed PNGs no golden test references anymore.

    A snapshot is covered when its path relative to goldens/ (without
    .png) appears verbatim in a golden source — literal `expectGolden`
    names and `golden:` args match this way, including launcher/ subdir
    names. Store shots are generated dynamically
    (`goldens/store/<lang>/<device>/<screen>.png`), so for them the
    <screen> basename is enough (it is a `kStoreCopy` key /
    `_StoreScreen.name` in the sources).
    """
    if not os.path.isdir(GOLDENS_DIR):
        return []
    sources = collect_source_text()
    patterns = golden_name_patterns(sources)
    orphans = []
    for root, _dirs, files in os.walk(GOLDENS_DIR):
        for name in sorted(files):
            if not name.endswith(".png"):
                continue
            full = os.path.join(root, name)
            rel = os.path.relpath(full, GOLDENS_DIR).replace(os.sep, "/")
            stem = rel[: -len(".png")]
            if stem in sources:
                continue
            # Interpolated names ('foo_$suffix', 'chat_header_${width}'):
            # the stem matches a source literal's interpolation pattern.
            if any(pattern.match(stem) for pattern in patterns):
                continue
            # Dynamic store shots: match on the screen basename.
            if rel.startswith("store/") and stem.rsplit("/", 1)[-1] in sources:
                continue
            orphans.append(rel)
    return orphans


def find_pty_orphans() -> list[str]:
    """Committed omp reference twins (png/txt) nothing references anymore.

    A twin is covered when its stem ('01_welcome_idle') appears verbatim in
    the capture/parity test sources — the capture test writes exactly those
    names and the REG suites read them back. provenance.json and stray
    runtime files that are gitignored are not tracked, so they cannot be
    orphans in git terms; anything tracked but unreferenced is one.
    """
    if not os.path.isdir(PTY_SHOTS_DIR):
        return []
    omp_ref = os.path.join(PTY_SHOTS_DIR, "omp_ref")
    if not os.path.isdir(omp_ref):
        return []
    sources = ""
    for root_dir in PTY_SOURCE_DIRS:
        for root, _dirs, files in os.walk(root_dir):
            for name in files:
                if name.endswith(".dart"):
                    with open(os.path.join(root, name), encoding="utf-8") as fh:
                        sources += fh.read()
    orphans = []
    for name in sorted(os.listdir(omp_ref)):
        if not (name.endswith(".png") or name.endswith(".txt")):
            continue
        stem = name[: name.rfind(".")]
        if stem in sources:
            continue
        orphans.append(f"omp_ref/{name}")
    return orphans


def main() -> int:
    quick = "--quick" in sys.argv

    if not os.path.isdir(APP_DIR):
        return fail(f"flutter_app not found at {APP_DIR}")
    if not os.path.isfile(GUARD_TEST):
        return fail("test/golden/golden_guard_test.dart is missing")

    if not os.path.isdir(GOLDENS_DIR) or not any(
        f.endswith(".png") for f in os.listdir(GOLDENS_DIR)
    ):
        return fail(
            "no golden snapshots found — run: "
            "cd flutter_app && flutter test test/golden --update-goldens"
        )

    orphans = find_orphan_snapshots()
    if orphans:
        listing = "\n".join(f"  - {name}" for name in orphans)
        return fail(
            "stale golden snapshots no test references (delete them —\n"
            "every regenerated/deleted widget otherwise keeps its PNGs in\n"
            "git history forever):\n" + listing
        )

    pty_orphans = find_pty_orphans()
    if pty_orphans:
        listing = "\n".join(f"  - {name}" for name in pty_orphans)
        return fail(
            "stale omp reference twins no test references (issue #810 —\n"
            "re-capture or delete them; every omp_ref file must be written\n"
            "by the capture test):\n" + listing
        )

    if quick:
        print("✅ Golden snapshots present, no orphans (quick mode — suite not run)")
        return 0

    print("🧪 Running golden tests (flutter test test/golden)...")
    result = subprocess.run(
        ["flutter", "test", "test/golden"],
        cwd=APP_DIR,
    )
    if result.returncode != 0:
        return fail(
            "golden tests failed — UI changed without updating snapshots, "
            "or a widget lost coverage (see the guard test output above)"
        )
    print("✅ Golden gate OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
