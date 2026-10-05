#!/usr/bin/env python3
"""Floor the declared test timeout of a terminal-bench dataset (gh-1206).

Companion to patch_dataset.py (the Debian apt archival fix): this pass
pads each task's declared max_test_timeout_sec up to a floor, because the
declared budgets (tb default 60s) classify slow-but-healthy verifier
phases as failure_mode=test_timeout — slow-start server tasks (jupyter,
databases) burn tens of seconds on first boot and judge phases still
install their own deps inside the task container (run 37144207185:
jupyter-notebook-server ended test_timeout with the agent's pane DONE).
tb multiplies the declared value by --global-timeout-multiplier, so a
120s floor is 240s effective at the bench's multiplier 2 — and costs
nothing for fast verifier phases: the cap is a cap, not a wait.

The floor rides ONE knob everywhere: --floor flag > env
FA_TEST_TIMEOUT_FLOOR_SEC (policy: test_timeout_policy.py).
shard_tasks.py applies the same floor to its LPT budgets so shard sizing
never under-counts the padded values. Absent/empty = no floor
(byte-for-byte legacy); 0 is an explicit no-op.

Usage:
    patch_test_timeouts.py <dataset-dir> [--floor SEC]

Idempotent: values already at/above the floor are left byte-identical.
"""
import argparse
from pathlib import Path

from test_timeout_policy import FLOOR_ENV, floor_task_yaml, resolve_floor


def patch_dataset(root: Path, floor: float) -> tuple:
    """Floor every */task.yaml; returns (changed_count, total_count)."""
    task_yamls = sorted(root.glob("*/task.yaml"))
    if not task_yamls:
        raise SystemExit(f"::error::no task.yaml files under {root}")

    changed = 0
    for path in task_yamls:
        text = path.read_text(errors="replace")
        new, declared, padded = floor_task_yaml(text, floor)
        if new == text:
            continue
        path.write_text(new)
        changed += 1
        print(
            f"patched {path.relative_to(root)} "
            f"(test timeout {declared} -> {padded})"
        )
    return changed, len(task_yamls)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Floor declared task.yaml test timeouts (gh-1206)"
    )
    parser.add_argument("dataset_dir", help="downloaded tb dataset directory")
    parser.add_argument(
        "--floor",
        default="",
        help=(
            "minimum declared test timeout seconds "
            f"(default: ${FLOOR_ENV}; empty/0 = no floor)"
        ),
    )
    args = parser.parse_args(argv)

    try:
        floor = resolve_floor(args.floor)
    except ValueError as exc:
        raise SystemExit(f"::error::{exc}")

    if floor is None:
        print(
            f"no floor configured (--floor / ${FLOOR_ENV}); "
            "leaving task.yaml files untouched"
        )
        return

    changed, total = patch_dataset(Path(args.dataset_dir), floor)
    print(f"{changed} of {total} task.yaml(s) floored at {floor}s")


if __name__ == "__main__":
    main()
