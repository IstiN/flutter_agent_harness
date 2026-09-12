#!/usr/bin/env python3
"""PR diff coverage ratchet (issue #177).

Computes line coverage over only the lines CHANGED between a base and head
revision under lib/, using `git diff -U0` for the changed-line set and an
lcov file for hit counts. Files with zero changed lines are skipped; the
overall percentage is covered_changed / total_changed across all files.

Usage:
    python3 scripts/diff_coverage.py --lcov coverage/lcov.info \
        --base <sha> --head <sha> [--min 80]

Exit code 1 when the diff coverage is below --min (or inputs are missing).
Pure stdlib.
"""

import argparse
import os
import re
import subprocess
import sys

HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def changed_lines(base: str, head: str) -> dict:
    """Return {relpath: set(line_no)} of lines added/changed in base...head."""
    out = subprocess.run(
        ["git", "diff", "-U0", f"{base}...{head}", "--", "lib/"],
        capture_output=True, text=True, check=True,
    ).stdout
    result = {}
    current = None
    for line in out.splitlines():
        if line.startswith("+++ b/"):
            current = line[len("+++ b/"):]
            result.setdefault(current, set())
        elif line.startswith("+++ "):
            current = None  # e.g. /dev/null (deleted file)
        elif line.startswith("@@") and current is not None:
            m = HUNK_RE.match(line)
            if not m:
                continue
            start = int(m.group(1))
            count = int(m.group(2)) if m.group(2) is not None else 1
            # count == 0: pure deletion hunk, no changed lines on the + side.
            for n in range(start, start + count):
                result[current].add(n)
    return result


def lcov_hits(lcov_path: str) -> dict:
    """Return {relpath: {line_no: hits}} from an lcov file, keyed by repo-relative path."""
    hits = {}
    current = None
    with open(lcov_path, "r") as f:
        for raw in f:
            line = raw.strip()
            if line.startswith("SF:"):
                path = line[3:]
                current = os.path.relpath(path) if os.path.isabs(path) else path
                current = current.replace(os.sep, "/")
                hits.setdefault(current, {})
            elif line.startswith("DA:") and current is not None:
                num, _, count = line[3:].partition(",")
                try:
                    hits[current][int(num)] = int(count)
                except ValueError:
                    continue
    return hits


def main() -> int:
    ap = argparse.ArgumentParser(description="Diff coverage ratchet for lib/.")
    ap.add_argument("--lcov", required=True, help="Path to lcov.info")
    ap.add_argument("--base", required=True, help="Base revision (sha/ref)")
    ap.add_argument("--head", required=True, help="Head revision (sha/ref)")
    ap.add_argument("--min", type=float, default=80.0,
                    help="Minimum diff coverage percentage (default: 80)")
    args = ap.parse_args()

    if not os.path.isfile(args.lcov):
        print(f"ERROR: {args.lcov} not found. Run: dart test --coverage=coverage "
              "&& dart run coverage:format_coverage --lcov -i coverage -o coverage/lcov.info")
        return 1

    try:
        changed = changed_lines(args.base, args.head)
    except subprocess.CalledProcessError as e:
        print(f"ERROR: git diff failed: {e.stderr.strip()}")
        return 1
    hits = lcov_hits(args.lcov)

    total_changed = 0
    total_covered = 0
    for path in sorted(changed):
        lines = changed[path]
        file_hits = hits.get(path, {})
        # Only lcov-instrumented (executable) lines count: doc comments
        # and blanks carry no DA record and would cap any heavily
        # documented new file below the bar no matter the real coverage.
        executable = [n for n in lines if n in file_hits]
        if not executable:
            continue
        covered = sum(1 for n in executable if file_hits[n] > 0)
        total_changed += len(executable)
        total_covered += covered
        pct = 100.0 * covered / len(executable)
        print(f"  {path}: {pct:.1f}% ({covered}/{len(executable)} executable lines covered)")

    if total_changed == 0:
        print(f"Diff coverage: no changed lib/ lines in {args.base}...{args.head} — nothing to ratchet.")
        return 0

    pct = 100.0 * total_covered / total_changed
    print(f"Diff coverage (lib/, {args.base}...{args.head}): "
          f"{pct:.2f}% ({total_covered}/{total_changed} changed lines), minimum {args.min}%")
    if pct < args.min:
        print(f"ERROR: diff coverage {pct:.2f}% is below minimum {args.min}%")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
