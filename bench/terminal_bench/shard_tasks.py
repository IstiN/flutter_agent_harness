#!/usr/bin/env python3
"""Split a terminal-bench dataset's task ids into matrix shards.

Usage:
    shard_tasks.py --dataset-dir DIR [--shards N] [--tasks 'PATTERN [PATTERN...]']

Resolves task ids exactly like `tb run -t`: the union of Path.glob matches
per pattern against the dataset dir (empty pattern list = all tasks).
Shards are balanced longest-processing-time-first by each task's declared
timeout budget (max_agent_timeout_sec + max_test_timeout_sec, tb defaults
360/60): with bench's --global-timeout-multiplier the per-shard worst case
is the sum of declared budgets, and LPT keeps every shard under the job
timeout where the old alphabetical-contiguous split could blow past the
GitHub Actions 6 h cap (issue #142).
Emits GitHub Actions outputs (matrix + count) on $GITHUB_OUTPUT: one
matrix include entry per non-empty shard, tasks space-joined.
"""
import argparse
import heapq
import json
import os
import re
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


def task_budget(dataset_dir, task_id):
    """Declared wall-clock budget (agent + test seconds) for one task."""
    agent, test = 360.0, 60.0  # tb TrialHandler defaults
    cfg = dataset_dir / task_id / "task.yaml"
    if cfg.is_file():
        text = cfg.read_text(errors="replace")
        m = re.search(r"^\s*max_agent_timeout_sec:\s*([\d.]+)", text, re.M)
        if m:
            agent = float(m.group(1))
        m = re.search(r"^\s*max_test_timeout_sec:\s*([\d.]+)", text, re.M)
        if m:
            test = float(m.group(1))
    return agent + test


def split_lpt(ids, budgets, n):
    """Pack tasks into n shards, longest budget first, least-loaded shard next.

    Deterministic: equal budgets tie-break on sorted task id.
    """
    shards = [[] for _ in range(n)]
    loads = [0.0] * n
    heap = [(0.0, i) for i in range(n)]
    heapq.heapify(heap)
    for tid in sorted(ids, key=lambda t: (-budgets[t], t)):
        load, i = heapq.heappop(heap)
        shards[i].append(tid)
        loads[i] += budgets[tid]
        heapq.heappush(heap, (loads[i], i))
    return shards


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
    dataset_dir = Path(args.dataset_dir)
    budgets = {tid: task_budget(dataset_dir, tid) for tid in ids}
    shards = []
    for i, part in enumerate(s for s in split_lpt(ids, budgets, n) if s):
        shards.append({"i": i, "tasks": " ".join(part)})

    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a") as f:
        f.write(f"matrix={json.dumps({'include': shards})}\n")
        f.write(f"count={len(ids)}\n")
    print(f"{len(ids)} task(s) across {len(shards)} shard(s)")
    for s in shards:
        print(f"  shard {s['i']}: {s['tasks']}")


if __name__ == "__main__":
    main()
