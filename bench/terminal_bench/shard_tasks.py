#!/usr/bin/env python3
"""Split a terminal-bench dataset's task ids into matrix shards.

Usage:
    shard_tasks.py --dataset-dir DIR [--shards N] [--tasks 'PATTERN [PATTERN...]']

Resolves task ids exactly like `tb run -t`: the union of Path.glob matches
per pattern against the dataset dir (empty pattern list = all tasks).
Emits GitHub Actions outputs (matrix + count) on $GITHUB_OUTPUT: one
matrix include entry per non-empty shard, tasks space-joined.
"""
import argparse
import json
import os
from pathlib import Path


def resolve_task_ids(dataset_dir, patterns):
    ids = set()
    for pattern in patterns:
        matching = [p.name for p in dataset_dir.glob(pattern)]
        if not matching:
            raise SystemExit(f"::error::no dataset tasks match pattern: {pattern}")
        ids.update(matching)
    if not ids:
        raise SystemExit("::error::no tasks resolved")
    return sorted(ids)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset-dir", required=True)
    parser.add_argument("--shards", default="8")
    parser.add_argument("--tasks", default="")
    args = parser.parse_args()

    try:
        n = max(1, int(args.shards))
    except ValueError:
        raise SystemExit(f"::error::shards input must be an integer, got: {args.shards!r}")

    ids = resolve_task_ids(Path(args.dataset_dir), args.tasks.split() or ["*"])
    shards = []
    for i in range(n):
        part = ids[i * len(ids) // n:(i + 1) * len(ids) // n]
        if part:
            shards.append({"i": i, "tasks": " ".join(part)})

    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a") as f:
        f.write(f"matrix={json.dumps({'include': shards})}\n")
        f.write(f"count={len(ids)}\n")
    print(f"{len(ids)} task(s) across {len(shards)} shard(s)")
    for s in shards:
        print(f"  shard {s['i']}: {s['tasks']}")


if __name__ == "__main__":
    main()
