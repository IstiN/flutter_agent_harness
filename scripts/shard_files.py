#!/usr/bin/env python3
"""Print the test dirs/files of one shard from scripts/test_shards.json.

Usage:
    python3 scripts/shard_files.py <manifest> <index>

Output: one path per line, suitable for
    dart test $(python3 scripts/shard_files.py scripts/test_shards.json 0)

Directory units are printed as-is (dart test accepts directories). The
special unit "test" (loose *_test.dart files at the test root) is expanded
to the individual root-level files so that `dart test` does not run the
entire suite.

Top-level test dirs that exist on disk but are MISSING from the manifest
(a PR added one after the last weekly rebalance) are bin-packed across the
shards at runtime by file count, so new suites run this PR — not at some
future rebalance (issue #194, AC5). test/integration is excluded: it runs
in its own CI job.

Pure stdlib.
"""

import glob
import json
import os
import sys


def uncovered_units(covered: set, root: str) -> list:
    """Top-level test dirs missing from the manifest, as (path, filecount)."""
    out = []
    for entry in sorted(os.listdir(root)):
        path = os.path.join(root, entry)
        if entry == "integration" or path in covered or not os.path.isdir(path):
            continue  # integration runs in its own CI job
        files = glob.glob(os.path.join(path, "**", "*_test.dart"), recursive=True)
        if files:
            out.append((path.replace(os.sep, "/"), len(files)))
    return out


def bin_pack_by_count(units: list, n: int) -> list:
    buckets = [[] for _ in range(n)]
    loads = [0] * n
    for unit, count in sorted(units, key=lambda u: -u[1]):
        i = loads.index(min(loads))
        buckets[i].append(unit)
        loads[i] += count
    return buckets


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    manifest_path, index_s = sys.argv[1], sys.argv[2]
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"ERROR: cannot read manifest {manifest_path}: {e}", file=sys.stderr)
        return 1
    try:
        index = int(index_s)
        shards = manifest["shards"]
        shard = shards[index]
    except (ValueError, KeyError, IndexError):
        print(f"ERROR: no shard with index {index_s} in {manifest_path}", file=sys.stderr)
        return 1

    # Loose root files expand via glob below, so only directory units can
    # go stale; anything new under test/ runs THIS PR, not next rebalance.
    extra = uncovered_units({u for s in shards for u in s}, "test")
    if extra:
        print(
            "WARNING: test dirs missing from the manifest (new since the "
            f"last rebalance?): {[u for u, _ in extra]}; bin-packing by "
            "file count at runtime",
            file=sys.stderr,
        )
    extra_bucket = bin_pack_by_count(extra, len(shards))[index]

    for unit in list(shard) + extra_bucket:
        if os.path.isdir(unit):
            if os.path.normpath(unit) == "test":
                # Loose root files only — never the directory itself.
                for f in sorted(glob.glob(os.path.join(unit, "*_test.dart"))):
                    print(f.replace(os.sep, "/"))
            else:
                print(unit)
        elif os.path.isfile(unit):
            print(unit)
        else:
            print(f"WARNING: shard unit not found: {unit}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
