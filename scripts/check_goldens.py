#!/usr/bin/env python3
"""Golden-test gate for flutter_app.

Verifies that golden (screenshot) tests exist and are up to date:

  1. test/golden/goldens/ holds generated snapshots (*.png);
  2. every lib/ widget file has golden coverage (enforced by
     test/golden/golden_guard_test.dart — this script runs it plus the
     golden suite, unless --quick is passed, in which case only the
     snapshot-existence check runs).

Usage:
  python3 scripts/check_goldens.py           # full: run the golden suite
  python3 scripts/check_goldens.py --quick   # existence checks only

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

    if quick:
        print("✅ Golden snapshots present (quick mode — suite not run)")
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
