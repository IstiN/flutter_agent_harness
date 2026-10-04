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

Tag-scoped manifests (issue #931: the integration shards) pass --tags so
both the selection AND the expected suite derive from the same matcher:

    python3 scripts/assert_shard_manifest.py \
        scripts/test_integration_shards.json --shards 3 \
        --tags integration --exclude browser_ext --exclude-tag llm

The --exclude-tag form (gh-1199 AC1) asserts the live boundary too: the
expected suite is tagged-minus-excluded, and any excluded-tag file
reaching a selection is a loud leak.

Delegates the actual selection to shard_files.py (same interpreter the CI
test step uses), so the assert can never drift from what CI really runs.

Pure stdlib. Exit 0 on success, 1 on any violation.
"""

import argparse
import glob
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shard_files import file_has_tag


def full_suite(root: str, exclude: list, tag=None, exclude_tags=None) -> set:
    out = set()
    for path in glob.glob(os.path.join(root, "**", "*_test.dart"), recursive=True):
        norm = path.replace(os.sep, "/")
        if any(x in norm for x in exclude):
            continue
        if tag is not None:
            # Tag-scoped manifest: the suite IS the tagged files (same
            # matcher the runtime selector bin-packs with).
            if not file_has_tag(path, tag):
                continue
        elif "/integration/" in norm:
            continue
        if exclude_tags and any(file_has_tag(path, t) for t in exclude_tags):
            continue  # gh-1199 AC1: the live boundary shrinks the suite
        out.add(norm)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Assert shard-manifest union/disjointness/no-leak.")
    ap.add_argument("manifest")
    ap.add_argument("--shards", type=int, default=3)
    ap.add_argument("--root", default="test")
    ap.add_argument("--exclude", action="append", default=[])
    ap.add_argument("--exclude-tag", action="append", default=[],
                    help="gh-1199 AC1: files carrying this tag must NOT appear "
                         "in any selection and are removed from the expected suite")
    ap.add_argument("--tags", default=None,
                    help="tag-scoped manifest (e.g. integration): the expected "
                         "suite is the tagged files, not root-minus-integration")
    args = ap.parse_args()

    shard_files_py = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                  "shard_files.py")
    selections = []
    for i in range(args.shards):
        cmd = [sys.executable, shard_files_py, args.manifest, str(i)]
        if args.tags:
            cmd += ["--tags", args.tags]
        for x in args.exclude:
            cmd += ["--exclude", x]
        for t in args.exclude_tag:
            cmd += ["--exclude-tag", t]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"::error::shard_files.py failed for shard {i}:\n{proc.stderr}",
                  file=sys.stderr)
            return 1
        selections.append({ln.strip() for ln in proc.stdout.splitlines() if ln.strip()})

    ok = True
    full = full_suite(args.root, args.exclude, tag=args.tags,
                      exclude_tags=args.exclude_tag)
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

    # gh-1199 AC1: the live boundary — a file carrying an excluded tag must
    # never reach a gate shard selection, from the manifest or a bin-pack.
    for tag in args.exclude_tag:
        live_leaks = sorted(f for f in union if file_has_tag(f, tag))
        if live_leaks:
            ok = False
            print(f"::error::live-boundary violation: {len(live_leaks)} file(s) "
                  f"tagged '{tag}' leaked into the gate shards: {live_leaks}",
                  file=sys.stderr)

    if not ok:
        return 1
    counts = ", ".join(f"shard{i}={len(s)}" for i, s in enumerate(selections))
    print(f"Shard manifest OK: union={len(union)} files == full suite, "
          f"pairwise disjoint, no excluded leaks ({counts})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
