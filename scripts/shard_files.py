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

Pure stdlib.
"""

import glob
import json
import os
import sys


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
        shard = manifest["shards"][index]
    except (ValueError, KeyError, IndexError):
        print(f"ERROR: no shard with index {index_s} in {manifest_path}", file=sys.stderr)
        return 1

    for unit in shard:
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
