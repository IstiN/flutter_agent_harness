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
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_DIR = os.path.join(REPO_ROOT, "flutter_app")
GOLDENS_DIR = os.path.join(APP_DIR, "test", "golden", "goldens")
GUARD_TEST = os.path.join(APP_DIR, "test", "golden", "golden_guard_test.dart")
GOLDEN_TESTS_DIR = os.path.join(APP_DIR, "test", "golden")


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
            # Dynamic store shots: match on the screen basename.
            if rel.startswith("store/") and stem.rsplit("/", 1)[-1] in sources:
                continue
            orphans.append(rel)
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
