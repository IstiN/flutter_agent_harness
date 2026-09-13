#!/usr/bin/env python3
"""Shard-manifest assert (issue #283, AC1/E4): proves a shard manifest
covers EXACTLY the intended suite before any test runs.

Checks (all must hold, each failure is loud):
    1. union of all shard selections == the full suite on disk
       (root/**/*_test.dart minus --exclude matches minus integration);
    2. pairwise intersection of shard selections is empty — a test file is
       executed by exactly ONE shard;
    3. zero excluded files (e.g. host-locked goldens) leak into any shard.

Run from the package whose test/ dir is being sharded:

    cd packages/fa_ui
    python3 ../../scripts/assert_shard_manifest.py \
        ../../scripts/faui_test_shards.json --shards 3 --exclude golden

Delegates the actual selection to shard_files.py (same interpreter the CI
test step uses), so the assert can never drift from what CI really runs.

Pure stdlib. Exit 0 on success, 1 on any violation.
"""

import argparse
import glob
import os
import subprocess
import sys


def full_suite(root: str, exclude: list) -> set:
    out = set()
    for path in glob.glob(os.path.join(root, "**", "*_test.dart"), recursive=True):
        norm = path.replace(os.sep, "/")
        if "/integration/" in norm or any(x in norm for x in exclude):
            continue
        out.add(norm)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Assert shard-manifest union/disjointness/no-leak.")
    ap.add_argument("manifest")
    ap.add_argument("--shards", type=int, default=3)
    ap.add_argument("--root", default="test")
    ap.add_argument("--exclude", action="append", default=[])
    args = ap.parse_args()

    shard_files_py = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                  "shard_files.py")
    selections = []
    for i in range(args.shards):
        cmd = [sys.executable, shard_files_py, args.manifest, str(i)]
        for x in args.exclude:
            cmd += ["--exclude", x]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"::error::shard_files.py failed for shard {i}:\n{proc.stderr}",
                  file=sys.stderr)
            return 1
        selections.append({ln.strip() for ln in proc.stdout.splitlines() if ln.strip()})

    ok = True
    full = full_suite(args.root, args.exclude)
    union = set().union(*selections) if selections else set()

    missing = sorted(full - union)
    unexpected = sorted(union - full)
    if missing:
        ok = False
        print(f"::error::shard manifest misses {len(missing)} test file(s): {missing}",
              file=sys.stderr)
    if unexpected:
        ok = False
        print(f"::error::shard manifest selects {len(unexpected)} file(s) outside the "
              f"suite (stale or excluded): {unexpected}", file=sys.stderr)

    for i in range(len(selections)):
        for j in range(i + 1, len(selections)):
            overlap = sorted(selections[i] & selections[j])
            if overlap:
                ok = False
                print(f"::error::shards {i} and {j} overlap on {len(overlap)} file(s): "
                      f"{overlap}", file=sys.stderr)

    leaks = sorted(f for f in union if any(x in f for x in args.exclude))
    if leaks:
        ok = False
        print(f"::error::excluded file(s) leaked into shards "
              f"({args.exclude}): {leaks}", file=sys.stderr)

    if not ok:
        return 1
    counts = ", ".join(f"shard{i}={len(s)}" for i, s in enumerate(selections))
    print(f"Shard manifest OK: union={len(union)} files == full suite, "
          f"pairwise disjoint, no excluded leaks ({counts})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
