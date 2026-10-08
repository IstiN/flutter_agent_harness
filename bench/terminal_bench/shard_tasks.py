#!/usr/bin/env python3
"""Split a terminal-bench dataset's task ids into matrix shards.

Usage:
    shard_tasks.py --dataset-dir DIR [--shards N] [--tasks 'PATTERN [PATTERN...]']
                   [--test-timeout-floor SEC]

Resolves task ids exactly like `tb run -t`: the union of Path.glob matches
per pattern against the dataset dir (empty pattern list = all tasks).
Shards are balanced longest-processing-time-first by each task's declared
timeout budget (max_agent_timeout_sec + max_test_timeout_sec, tb defaults
360/60): with bench's --global-timeout-multiplier the per-shard worst case
is the sum of declared budgets, and LPT keeps every shard under the job
timeout where the old alphabetical-contiguous split could blow past the
GitHub Actions 6 h cap (issue #142).

gh-1206: the test side honors the same floor the dataset patcher applies
(patch_test_timeouts.py / FA_TEST_TIMEOUT_FLOOR_SEC) — the bench job pads
declared max_test_timeout_sec values up to the floor, so the LPT budgets
here must see the padded numbers or shard worst cases would be
under-counted. --test-timeout-floor (default: $FA_TEST_TIMEOUT_FLOOR_SEC;
absent/0 = no floor) raises the test-side share of each budget before
balancing.

Emits GitHub Actions outputs (matrix + count) on $GITHUB_OUTPUT: one
matrix include entry per non-empty shard, tasks space-joined.
"""
import argparse
import heapq
import json
import os
import re
from pathlib import Path

from test_timeout_policy import FLOOR_ENV, TEST_TIMEOUT_RE, floored, resolve_floor


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


def task_budget(dataset_dir, task_id, test_floor=None):
    """Declared wall-clock budget (agent + test seconds) for one task.

    test_floor (gh-1206) raises the test share to the same floor the
    dataset patcher applies, so shard sizing matches the padded task.yaml
    files the bench job actually runs.
    """
    agent, test = 360.0, 60.0  # tb TrialHandler defaults
    cfg = dataset_dir / task_id / "task.yaml"
    if cfg.is_file():
        text = cfg.read_text(errors="replace")
        m = re.search(r"^\s*max_agent_timeout_sec:\s*([\d.]+)", text, re.M)
        if m:
            agent = float(m.group(1))
        m = TEST_TIMEOUT_RE.search(text)
        if m:
            test = float(m.group(2))
    return agent + floored(test, test_floor)


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


# Issue #1392 ShardPacker: the usable per-shard budget is the job cap minus
# a 15-minute headroom — round 2 lost shard-0 by ~1 min with ZERO headroom.
HEADROOM_SEC = 15 * 60.0


def check_cap(shards, budgets, cap_seconds, headroom_seconds=HEADROOM_SEC):
    """Per-shard worst-case loads under the job-cap budget; loud when over.

    cap_seconds <= 0 disables the check (single-task smokes, local runs).
    Returns the per-shard load list on success; raises SystemExit with a
    ::error:: line naming the numbers and the remedy when the packed worst
    case exceeds the usable budget — a silent over-run costs a multi-hour
    shard that dies mid-run.
    """
    if not cap_seconds or cap_seconds <= 0:
        return [sum(budgets[t] for t in shard) for shard in shards]
    allowed = cap_seconds - headroom_seconds
    loads = {i: sum(budgets[t] for t in shard) for i, shard in enumerate(shards)}
    worst_index = max(loads, key=lambda i: loads[i])
    worst = loads[worst_index]
    if worst > allowed:
        raise SystemExit(
            f"::error::packed shard {worst_index} worst case is "
            f"{worst / 60:.0f} min, above the usable job budget "
            f"({allowed / 60:.0f} min = {cap_seconds / 60:.0f} min cap − "
            f"{headroom_seconds / 60:.0f} min headroom). Raise the shards "
            "input (the packer recomputes per shards=N) or lower the "
            "per-task budgets; a shard over the cap dies mid-run."
        )
    return [loads[i] for i in sorted(loads)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset-dir", required=True)
    parser.add_argument("--shards", default="8")
    parser.add_argument("--tasks", default="")
    parser.add_argument(
        "--test-timeout-floor",
        default="",
        help=(
            "minimum declared max_test_timeout_sec seconds to size for "
            f"(default: ${FLOOR_ENV}; empty/0 = none)"
        ),
    )
    parser.add_argument(
        "--job-cap-seconds",
        default="0",
        help=(
            "bench job cap in seconds; the packed worst case must fit "
            f"{HEADROOM_SEC / 60:.0f} min under it (issue #1392 ShardPacker; "
            "0 = no cap check)"
        ),
    )
    args = parser.parse_args()

    try:
        n = max(1, int(args.shards))
    except ValueError:
        raise SystemExit(f"::error::shards input must be an integer, got: {args.shards!r}")

    try:
        job_cap = float(args.job_cap_seconds)
    except ValueError:
        raise SystemExit(
            f"::error::job-cap-seconds must be a number of seconds, got: "
            f"{args.job_cap_seconds!r}"
        )

    try:
        test_floor = resolve_floor(args.test_timeout_floor)
    except ValueError as exc:
        raise SystemExit(f"::error::{exc}")

    ids = resolve_task_ids(Path(args.dataset_dir), args.tasks.split() or ["*"])
    dataset_dir = Path(args.dataset_dir)
    budgets = {tid: task_budget(dataset_dir, tid, test_floor) for tid in ids}
    raw_shards = split_lpt(ids, budgets, n)
    # Issue #1392 AC5: no shard's worst case may exceed the job cap minus
    # headroom — a silent over-run costs a shard that dies mid-run.
    loads = check_cap(raw_shards, budgets, job_cap)
    shards = []
    for i, part in enumerate(s for s in raw_shards if s):
        shards.append({"i": i, "tasks": " ".join(part)})

    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a") as f:
        f.write(f"matrix={json.dumps({'include': shards})}\n")
        f.write(f"count={len(ids)}\n")
        f.write(f"worst_shard_seconds={max(loads) if loads else 0}\n")
    print(f"{len(ids)} task(s) across {len(shards)} shard(s)")
    if job_cap > 0:
        print(
            f"worst shard {max(loads) / 60:.0f} min "
            f"(cap {job_cap / 60:.0f} min − {HEADROOM_SEC / 60:.0f} min headroom)"
        )
    for s in shards:
        print(f"  shard {s['i']}: {s['tasks']}")


if __name__ == "__main__":
    main()
