#!/usr/bin/env python3
"""Duration-balanced test sharding (issue #177, AC3).

Builds scripts/test_shards.json: a manifest mapping N shards to units of
test/. Units are the top-level directories under test/ (test/integration is
excluded — it runs in its own CI job) plus the loose *_test.dart files at
the test/ root (unit name "test", expanded by shard_files.py).

Modes:
    --from-junit <dir>   Parse JUnit XML reports in <dir>, sum testcase
                         durations per unit, greedy bin-pack into shards.
    --from-filecount     Fallback: weight each unit by its *_test.dart count.

Options:
    --shards N           Number of shards (default: 3).
    --root DIR           Test root (default: test).
    --output PATH        Manifest path (default: scripts/test_shards.json).

Skew check: warns when the longest shard exceeds 1.2x the shortest.

Manifest format:
    {"shards": [["test/cli", ...], [...], ...],
     "meta": {"generated": "<iso>", "source": "timing|filecount",
              "weights": {"test/cli": 12.3, ...}}}

Pure stdlib.
"""

import argparse
import datetime
import glob
import json
import os
import sys
import xml.etree.ElementTree as ET

SKEW_LIMIT = 1.2


def list_units(root: str) -> dict:
    """Return {unit: [test files]} for top-level dirs + loose root files."""
    units = {}
    for entry in sorted(os.listdir(root)):
        path = os.path.join(root, entry)
        if os.path.isdir(path):
            if entry == "integration":
                continue  # integration suite runs in its own CI job
            files = glob.glob(os.path.join(path, "**", "*_test.dart"), recursive=True)
            if files:
                units[path.replace(os.sep, "/")] = sorted(files)
    root_files = sorted(glob.glob(os.path.join(root, "*_test.dart")))
    if root_files:
        units[root] = root_files  # loose root files, expanded by shard_files.py
    return units


def weights_from_filecount(units: dict) -> dict:
    return {unit: float(len(files)) for unit, files in units.items()}


def weights_from_junit(units: dict, junit_dir: str) -> dict:
    """Sum JUnit testcase durations per unit; unseen units get the mean."""
    # Map each test file to its unit for prefix matching.
    file_to_unit = {}
    for unit, files in units.items():
        for f in files:
            file_to_unit[os.path.abspath(f)] = unit
    totals = {unit: 0.0 for unit in units}
    seen = set()
    for xml_path in glob.glob(os.path.join(junit_dir, "**", "*.xml"), recursive=True):
        try:
            tree = ET.parse(xml_path)
        except ET.ParseError:
            continue
        for case in tree.iter("testcase"):
            t = float(case.get("time", "0") or 0)
            # JUnit classname/file attributes vary by reporter; match any
            # attribute that looks like a path against known test files.
            target = None
            for attr in ("file", "classname", "name"):
                val = case.get(attr, "")
                if not val:
                    continue
                val_norm = val.replace("\\", "/")
                for f, unit in file_to_unit.items():
                    if f.replace("\\", "/").endswith(val_norm) or val_norm.endswith(f.replace(os.sep, "/")):
                        target = unit
                        break
                if target:
                    break
            if target:
                totals[target] += t
                seen.add(target)
    # Units with no timing data get the mean of the seen ones (keeps the
    # bin-pack sane instead of dumping them all at weight 0).
    if seen:
        mean = sum(totals[u] for u in seen) / len(seen)
        for unit in units:
            if unit not in seen:
                totals[unit] = mean
    else:
        print("WARNING: no JUnit timings matched any unit; falling back to file count",
              file=sys.stderr)
        return weights_from_filecount(units)
    return totals


# ponytail: unit = top-level test dir, so a flat monster (test/cli = 87 files,
# ~40% of suite time) cannot be split — post-rebalance skew bottoms out around
# 1.5x. If that ever hurts, chunk flat dirs by sorted filename here and teach
# shard_files.py to print the chunk's files.
def bin_pack(weights: dict, n: int) -> list:
    """Greedy longest-processing-time bin-pack into n shards."""
    shards = [[] for _ in range(n)]
    loads = [0.0] * n
    for unit in sorted(weights, key=lambda u: weights[u], reverse=True):
        i = loads.index(min(loads))
        shards[i].append(unit)
        loads[i] += weights[unit]
    return shards, loads


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate a balanced test-shard manifest.")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--from-junit", metavar="DIR",
                      help="Directory with JUnit XML reports (timing-based)")
    mode.add_argument("--from-filecount", action="store_true",
                      help="Weight units by *_test.dart count (fallback)")
    ap.add_argument("--shards", type=int, default=3)
    ap.add_argument("--root", default="test")
    ap.add_argument("--output", default="scripts/test_shards.json")
    args = ap.parse_args()

    if args.shards < 1:
        print("ERROR: --shards must be >= 1", file=sys.stderr)
        return 1
    units = list_units(args.root)
    if not units:
        print(f"ERROR: no test units found under {args.root}/", file=sys.stderr)
        return 1

    if args.from_junit:
        weights = weights_from_junit(units, args.from_junit)
        source = "timing"
    else:
        weights = weights_from_filecount(units)
        source = "filecount"

    n = min(args.shards, len(units))
    shards, loads = bin_pack(weights, n)
    for shard in shards:
        shard.sort()

    longest = max(loads)
    shortest = min(loads)
    skew_ok = shortest == 0 or longest <= SKEW_LIMIT * shortest
    print(f"Shards ({source}): " +
          ", ".join(f"[{i}] {load:.1f} ({len(shards[i])} units)" for i, load in enumerate(loads)))
    if not skew_ok:
        print(f"WARNING: shard skew {longest / shortest:.2f}x exceeds {SKEW_LIMIT}x "
              "(longest %.1f vs shortest %.1f)" % (longest, shortest), file=sys.stderr)

    manifest = {
        "shards": shards,
        "meta": {
            "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "source": source,
            "weights": {u: round(w, 3) for u, w in sorted(weights.items())},
        },
    }
    with open(args.output, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print(f"Wrote {args.output} ({n} shards, {len(units)} units)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
