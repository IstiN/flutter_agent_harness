#!/usr/bin/env python3
"""CLI-surface coverage ratchet for the PTY/terminal integration suites
(issue #177 follow-up: automatically growing terminal-test coverage).

Measures LINE coverage of lib/src/cli/** from an lcov file produced by the
integration suites (mock-endpoint PTY tests + live providers that self-skip)
and compares it against the committed baseline
(scripts/cli_coverage_baseline.txt). The baseline only ever moves UP — the
weekly coverage-gardener.yml workflow measures and bumps it, so terminal-test
coverage of the CLI surface can never silently regress.

Usage:
  check_cli_coverage.py [--lcov coverage/lcov.info] [--min-from BASELINE_FILE]
  check_cli_coverage.py --print   # just print the measured percentage
Exit 1 when below baseline.
"""
import argparse
import os
import sys

PREFIXES = ("SF:", "DA:")


def cli_line_coverage(lcov_path: str, scope: str = "lib/src/cli/") -> float:
    total = 0
    hit = 0
    current_in_scope = False
    with open(lcov_path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if line.startswith("SF:"):
                path = line[3:]
                # lcov paths may be absolute or repo-relative.
                idx = path.find(scope)
                current_in_scope = idx != -1
            elif line.startswith("DA:") and current_in_scope:
                try:
                    _lineno, hits = line[3:].split(",")[:2]
                except ValueError:
                    continue
                total += 1
                if int(hits) > 0:
                    hit += 1
    if total == 0:
        return 0.0
    return 100.0 * hit / total


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lcov", default="coverage/lcov.info")
    ap.add_argument(
        "--baseline",
        default=os.path.join(os.path.dirname(__file__), "cli_coverage_baseline.txt"),
    )
    ap.add_argument("--print", dest="only_print", action="store_true")
    args = ap.parse_args()

    pct = cli_line_coverage(args.lcov)
    print(f"CLI surface coverage (lib/src/cli/**): {pct:.2f}%")
    if args.only_print:
        return 0

    baseline = 0.0
    if os.path.exists(args.baseline):
        with open(args.baseline, encoding="utf-8") as fh:
            baseline = float(fh.read().strip() or "0")
    print(f"Baseline: {baseline:.2f}% (ratchet: only up)")
    if pct + 1e-9 < baseline:
        print(
            f"FAIL: CLI coverage {pct:.2f}% regressed below baseline {baseline:.2f}%.\n"
            "Add terminal/PTY tests for the uncovered CLI paths — the baseline only goes up."
        )
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
