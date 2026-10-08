#!/usr/bin/env python3
"""Floor + per-task override the declared test timeout of a tb dataset.

gh-1206 floor: pads each task's declared max_test_timeout_sec up to a
floor, because the declared budgets (tb default 60s) classify
slow-but-healthy verifier phases as failure_mode=test_timeout —
slow-start server tasks (jupyter, databases) burn tens of seconds on
first boot and judge phases still install their own deps inside the task
container (run 37144207185: jupyter-notebook-server ended test_timeout
with the agent's pane DONE). tb multiplies the declared value by
--global-timeout-multiplier, so a 120s floor is 240s effective at the
bench's multiplier 2 — and costs nothing for fast verifier phases: the
cap is a cap, not a wait. The floor serves FAST suites; it cannot save a
task whose verifier phase needs more than any sane global floor.

gh-1407 override table: for repeat-offender tasks with runner-MEASURED
test-phase p95 evidence (bench/terminal_bench/test_budget_overrides.json)
the declared budget is padded so that declared x multiplier >=
measured_p95_sec x 1.5 — a per-task effective budget, NOT a global floor
bump. Entries carry their run-artifact source; censored samples (the
phase died at the cap, so only a lower bound is known) are marked in the
table and the resulting budget is a NEEDS-CI-RUN until a no-agent dry
run completes under it. shard_tasks.py sizes LPT shards on the same
padded values and warns when a planned task's effective budget is still
below its measured p95 (the never-again fairness guard).

The floor rides ONE knob everywhere: --floor flag > env
FA_TEST_TIMEOUT_FLOOR_SEC (policy: test_timeout_policy.py). The override
table: checked-in JSON by default, --overrides PATH to replace it,
FA_TEST_BUDGET_OVERRIDES to merge an extra table, --no-overrides to
disable; --multiplier / FA_TEST_TIMEOUT_MULTIPLIER must match the tb
run's --global-timeout-multiplier (bench default 2). Absent/empty floor
= no floor (byte-for-byte legacy); 0 is an explicit no-op.

Usage:
    patch_test_timeouts.py <dataset-dir> [--floor SEC]
        [--overrides PATH | --no-overrides] [--multiplier N]

Idempotent: values already at/above the floor (and override) are left
byte-identical.
"""
import argparse
from pathlib import Path

from test_timeout_policy import (
    FLOOR_ENV,
    MULTIPLIER_ENV,
    OVERRIDES_ENV,
    floor_task_yaml,
    load_overrides,
    padded_task_yaml,
    resolve_floor,
    resolve_multiplier,
)


def patch_dataset(root: Path, floor: float, overrides=None,
                  multiplier: float = 2.0) -> tuple:
    """Floor (+ override) every */task.yaml; returns (changed, total)."""
    task_yamls = sorted(root.glob("*/task.yaml"))
    if not task_yamls:
        raise SystemExit(f"::error::no task.yaml files under {root}")

    overrides = overrides or {}
    changed = 0
    for path in task_yamls:
        entry = overrides.get(path.parent.name)
        p95 = entry["measured_p95_sec"] if entry else None
        text = path.read_text(errors="replace")
        if p95 is None:
            new, declared, padded = floor_task_yaml(text, floor)
        else:
            new, declared, padded = padded_task_yaml(
                text, floor, p95=p95, multiplier=multiplier
            )
        if new == text:
            continue
        path.write_text(new)
        changed += 1
        if p95 is None:
            print(
                f"patched {path.relative_to(root)} "
                f"(test timeout {declared} -> {padded})"
            )
        else:
            print(
                f"patched {path.relative_to(root)} "
                f"(test timeout {declared} -> {padded} "
                f"override p95 {p95}s x {1.5:g} / {multiplier:g}x)"
            )
    return changed, len(task_yamls)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "Floor declared task.yaml test timeouts (gh-1206) and apply "
            "the per-task measured-p95 override table (gh-1407)"
        )
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
    parser.add_argument(
        "--overrides",
        default=None,
        help=(
            "override-table JSON REPLACING the checked-in "
            f"test_budget_overrides.json (default: ${OVERRIDES_ENV} merges "
            "an extra table over the checked-in one)"
        ),
    )
    parser.add_argument(
        "--no-overrides",
        action="store_true",
        help="disable the override table entirely (floor-only dispatch)",
    )
    parser.add_argument(
        "--multiplier",
        default="",
        help=(
            "tb --global-timeout-multiplier in force, for the override "
            f"math (default: ${MULTIPLIER_ENV} or 2)"
        ),
    )
    args = parser.parse_args(argv)

    try:
        floor = resolve_floor(args.floor)
        multiplier = resolve_multiplier(args.multiplier)
        overrides = load_overrides(
            path=args.overrides, no_overrides=args.no_overrides
        )
    except ValueError as exc:
        raise SystemExit(f"::error::{exc}")

    if floor is None and not overrides:
        print(
            f"no floor configured (--floor / ${FLOOR_ENV}) and no override "
            "entries loaded; leaving task.yaml files untouched"
        )
        return
    if overrides:
        print(
            f"override table: {len(overrides)} task(s) "
            f"({', '.join(sorted(overrides))})"
        )

    dataset_dir = Path(args.dataset_dir)
    override_ids = set(overrides) & {
        path.parent.name for path in dataset_dir.glob("*/task.yaml")
    }
    if floor is None and not override_ids:
        print(
            f"no floor configured (--floor / ${FLOOR_ENV}) and no override "
            "entries match this dataset; leaving task.yaml files untouched"
        )
        return

    changed, total = patch_dataset(
        dataset_dir, floor,
        overrides=None if args.no_overrides else overrides,
        multiplier=multiplier,
    )
    if override_ids:
        # gh-1407 log line (mentions the floor and the table in one place)
        floor_note = f"{floor}s" if floor is not None else "no floor"
        print(f"{changed} of {total} task.yaml(s) patched (floor {floor_note})")
    else:
        # gh-1206 legacy line, byte-stable for log scrapers
        print(f"{changed} of {total} task.yaml(s) floored at {floor}s")


if __name__ == "__main__":
    main()
