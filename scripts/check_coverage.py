#!/usr/bin/env python3
"""Coverage ratchet for lib/.

Parses coverage/lcov.info and ensures that the line-coverage percentage for
code under lib/ does not fall below the baseline.

Usage: python3 scripts/check_coverage.py [baseline]
"""

import os
import sys

BASELINE = float(sys.argv[1]) if len(sys.argv) > 1 else 80.0


def main() -> int:
    lcov_path = "coverage/lcov.info"
    if not os.path.isfile(lcov_path):
        print(f"ERROR: {lcov_path} not found. Run: dart test --coverage=coverage")
        return 1

    with open(lcov_path, "r") as f:
        content = f.read()

    files = content.split("SF:")
    total_found = 0
    total_hit = 0

    for sec in files[1:]:
        lines = sec.strip().split("\n")
        sf_line = lines[0]
        path = sf_line[3:] if sf_line.startswith("SF:") else sf_line
        relpath = os.path.relpath(path)

        if not relpath.startswith("lib/"):
            continue

        for line in lines[1:]:
            if line.startswith("DA:"):
                total_found += 1
                if int(line[3:].split(",")[1]) > 0:
                    total_hit += 1

    if total_found == 0:
        print("ERROR: no lib/ coverage data found in lcov.info")
        return 1

    pct = 100.0 * total_hit / total_found
    print(f"Coverage (lib/): {pct:.2f}% ({total_hit}/{total_found} lines), baseline {BASELINE}%")
    if pct < BASELINE:
        print(f"ERROR: coverage {pct:.2f}% is below baseline {BASELINE}%")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
