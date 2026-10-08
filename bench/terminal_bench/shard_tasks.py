#!/usr/bin/env python3
"""Split a terminal-bench dataset's task ids into matrix shards.

Usage:
    shard_tasks.py --dataset-dir DIR [--shards N] [--tasks 'PATTERN [PATTERN...]']
                   [--test-timeout-floor SEC] [--no-overrides] [--multiplier N]

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

gh-1407: the same budgets honor the per-task override table
(test_budget_overrides.json, runner-measured test-phase p95 per
repeat-offender task; --no-overrides disables, $FA_TEST_BUDGET_OVERRIDES
merges an extra table). The planner is also the fairness guard's home:
when a planned task's EFFECTIVE test budget (padded declared x
--multiplier, default $FA_TEST_TIMEOUT_MULTIPLIER or 2) is still below
its measured p95, it emits a ::warning:: naming both numbers — a
structurally unpassable task must be caught at planning time, not after
burning an agent run + test slot. The count lands in the
fairness_warnings job output.

Emits GitHub Actions outputs (matrix + count + fairness_warnings) on
$GITHUB_OUTPUT: one matrix include entry per non-empty shard, tasks
space-joined.
"""
import argparse
import heapq
import json
import os
import re
from pathlib import Path

from test_timeout_policy import (
    FLOOR_ENV,
    MULTIPLIER_ENV,
    TEST_TIMEOUT_RE,
    effective_test_seconds,
    load_overrides,
    override_declared,
    resolve_floor,
    resolve_multiplier,
)


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


def task_agent_seconds(dataset_dir, task_id):
    """The agent share of a task budget (tb default 360s when undeclared)."""
    cfg = dataset_dir / task_id / "task.yaml"
    if cfg.is_file():
        m = re.search(
            r"^\s*max_agent_timeout_sec:\s*([\d.]+)",
            cfg.read_text(errors="replace"), re.M,
        )
        if m:
            return float(m.group(1))
    return 360.0  # tb TrialHandler default


def task_test_seconds(dataset_dir, task_id):
    """The declared test share of a task budget (tb default 60s)."""
    cfg = dataset_dir / task_id / "task.yaml"
    if cfg.is_file():
        m = TEST_TIMEOUT_RE.search(cfg.read_text(errors="replace"))
        if m:
            return float(m.group(2))
    return 60.0  # tb TrialHandler default


def task_budget(dataset_dir, task_id, test_floor=None, override_p95=None,
                multiplier: float = 2.0):
    """Declared wall-clock budget (agent + test seconds) for one task.

    test_floor (gh-1206) raises the test share to the same floor the
    dataset patcher applies, so shard sizing matches the padded task.yaml
    files the bench job actually runs. override_p95 (gh-1407) is the
    task's runner-measured test-phase p95: the test share is padded so
    the declared value x multiplier covers p95 x 1.5 — the same math
    patch_test_timeouts.py writes into the dataset.
    """
    return task_agent_seconds(dataset_dir, task_id) + override_declared(
        task_test_seconds(dataset_dir, task_id),
        test_floor, override_p95, multiplier,
    )


def check_fairness(effective_test_by_task, measured_p95_by_task):
    """Planned tasks whose EFFECTIVE test budget is below their p95.

    gh-1407 never-again guard: a task whose verifier phase has already
    been observed to need more wall time than its budget buys can never
    resolve — the verdict would measure runner luck, not agent capability.
    Returns [(task_id, effective_seconds, measured_p95_seconds)] sorted by
    task id; empty when every measured task is funded.
    """
    return sorted(
        (tid, effective, measured_p95_by_task[tid])
        for tid, effective in effective_test_by_task.items()
        if tid in measured_p95_by_task
        and effective < measured_p95_by_task[tid]
    )


def warn_fairness(offenders):
    """Emit one ::warning:: annotation per under-funded task."""
    for task_id, effective, p95 in offenders:
        print(
            f"::warning::gh-1407 fairness: task '{task_id}' effective test "
            f"budget {effective:g}s < runner-measured test-phase p95 "
            f"{p95:g}s — structurally unlikely to ever resolve "
            "(the verdict would measure runner luck, not agent "
            "capability). Fund it via test_budget_overrides.json or a "
            "higher --test-timeout-floor."
        )


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
        "--no-overrides",
        action="store_true",
        help=(
            "size without the gh-1407 override table (floor-only "
            "dispatch; the fairness guard then warns for every measured "
            "task the budget under-funds)"
        ),
    )
    parser.add_argument(
        "--multiplier",
        default="",
        help=(
            "tb --global-timeout-multiplier in force, for effective "
            f"budgets (default: ${MULTIPLIER_ENV} or 2)"
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
        multiplier = resolve_multiplier(args.multiplier)
        # The table is always the source of MEASURED p95s (the fairness
        # guard exists precisely for --no-overrides dispatches); only the
        # budget padding honors the opt-out.
        measured = load_overrides()
    except ValueError as exc:
        raise SystemExit(f"::error::{exc}")

    ids = resolve_task_ids(Path(args.dataset_dir), args.tasks.split() or ["*"])
    dataset_dir = Path(args.dataset_dir)
    budget_overrides = {} if args.no_overrides else measured
    p95_by_task = {
        tid: entry["measured_p95_sec"]
        for tid, entry in measured.items()
        if tid in set(ids)
    }
    budgets = {
        tid: task_budget(
            dataset_dir, tid, test_floor,
            override_p95=p95_by_task.get(tid) if budget_overrides else None,
            multiplier=multiplier,
        )
        for tid in ids
    }
    # gh-1407 never-again guard: a planned task whose effective test
    # budget (the DISPATCHED declared test share x multiplier — floor
    # and override as budgets[] computed them) is still below its
    # runner-measured p95 can never resolve — say so at planning time.
    fairness = check_fairness(
        {
            tid: effective_test_seconds(
                budgets[tid] - task_agent_seconds(dataset_dir, tid), multiplier
            )
            for tid in ids
        },
        p95_by_task,
    )
    warn_fairness(fairness)
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
        f.write(f"fairness_warnings={len(fairness)}\n")
    print(f"{len(ids)} task(s) across {len(shards)} shard(s)")
    print(f"fairness warnings: {len(fairness)}")
    if job_cap > 0:
        print(
            f"worst shard {max(loads) / 60:.0f} min "
            f"(cap {job_cap / 60:.0f} min − {HEADROOM_SEC / 60:.0f} min headroom)"
        )
    for s in shards:
        print(f"  shard {s['i']}: {s['tasks']}")


if __name__ == "__main__":
    main()
