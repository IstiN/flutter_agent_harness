#!/usr/bin/env python3
"""Classify a nightly pty-integration leg failure as the #1696 abort class.

Issue #1696: the `dart test` RUNNER process itself dies with SIGABRT (exit
134, glibc heap-corruption detector — three signatures observed:
`malloc_consolidate(): unaligned fastbin chunk`, `corrupted double-linked
list`, `tcache_thread_shutdown(): unaligned tcache chunk`) while test
results so far are entirely green. The aborting process runs no package
code (no FFI in the package:test runner; pty2/sqlite3 native code loads
only inside per-file child processes), so a hit is an environment-class
VM/native fault, NOT a test regression — but the leg still goes red.

This script makes that classification explicit in the step summary on the
next recurrence. Annotation only: it never changes the leg's result, and
it always exits 0 (the red comes from the test step itself).

    python3 scripts/classify_native_abort.py test-results/exit-code \
        test-results/integration.json

Pure stdlib. The JSONL parse mirrors junit_from_dart_json.py's tolerant
reader: torn/partial trailing lines (the reporter flushes periodically, so
an abort-night file ends at the last flush, possibly mid-line) are skipped,
never fatal.
"""

import json
import sys

# The abort class: bash reports a SIGABRT death as exit 134 (128+6).
ABORT_EXIT = "134"


def summarize_report(json_path):
    """Count visible test results in a (possibly torn) dart json report.

    Returns (success, failure_or_error, torn_lines). Hidden pseudo-tests
    (suite loaders) are excluded, like every other consumer of the
    canonical span walk.
    """
    success = failure = torn = 0
    with open(json_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                torn += 1
                continue
            if ev.get("type") != "testDone" or ev.get("hidden"):
                continue
            if ev.get("result") == "success":
                success += 1
            elif ev.get("result") in ("failure", "error"):
                failure += 1
    return success, failure, torn


def main():
    if len(sys.argv) != 3:
        print("usage: classify_native_abort.py <exit-code-file> <report.json>")
        return 0

    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            exit_code = fh.read().strip()
    except OSError:
        exit_code = "unknown"

    if exit_code != ABORT_EXIT:
        print(
            f"leg failed with exit {exit_code} — not the #1696 native-abort "
            "signature (SIGABRT / 134); treat as an ordinary test failure."
        )
        return 0

    print("## :rotating_light: Nightly pty-integration leg: #1696 abort class")
    print()
    print(
        "`dart test` exited 134 (SIGABRT) — the runner PROCESS died natively,"
        " not a test. Signature history (issue #1696, all on the"
        " ubuntu-24.04-arm runner):"
    )
    print()
    print("- `malloc_consolidate(): unaligned fastbin chunk detected` (Oct-17)")
    print("- `corrupted double-linked list` (Oct-19)")
    print("- `tcache_thread_shutdown(): unaligned tcache chunk detected` (Oct-20)")
    print()
    print(
        "The runner process runs no package/native code — a hit is"
        " environment-class (Dart VM / runner image), not a test regression."
        " Report tail:"
    )
    print()
    try:
        success, failure, torn = summarize_report(sys.argv[2])
    except OSError:
        print(
            "- no report flush survived — abort happened before the first"
            " periodic flush; fully inconclusive on test state."
        )
        return 0
    print(
        f"- {success} visible tests succeeded, {failure} failed up to the"
        " report's last flush"
        + (f"; {torn} torn trailing line(s) — the file is a mid-run truncation" if torn else "")
        + "."
    )
    if failure == 0:
        print(
            "- zero failures at truncation: this red leg carries NO test"
            " regression — do not bisect package code; re-check the runner"
            " image / Dart SDK correlation in #1696."
        )
    else:
        print(
            "- REAL test failures present — handle as an ordinary red leg"
            " AND note the abort in #1696 (coincidence so far unobserved)."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
