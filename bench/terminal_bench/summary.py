#!/usr/bin/env python3
"""Accuracy summary for terminal-bench run dirs.

Usage:
    summary.py [--no-fail] <runs-dir> [expected-count]

Reads every <runs-dir>/*/results.json (sharded runs pin --run-id, so one
subdir per shard) and prints a GitHub-flavoured-markdown accuracy table,
also appending it to $GITHUB_STEP_SUMMARY when set.

tb exits 0 even with unresolved tasks, so the exit code is the verdict on
run COMPLETENESS only: 1 when nothing was produced or fewer than
expected-count tasks were attempted (lost/killed shard). Unresolved or
pending tasks are the run's scoreboard, not an infra failure — they are
reported in the table and accuracy line without failing the step.
--no-fail turns the verdict off (informational per-shard tallies).
"""
import glob
import json
import os
import sys
from pathlib import Path


def main():
    args = sys.argv[1:]
    no_fail = "--no-fail" in args
    args = [a for a in args if a != "--no-fail"]
    runs_dir = Path(args[0])
    expected = int(args[1]) if len(args) > 1 else None

    paths = sorted(glob.glob(str(runs_dir / "*" / "results.json")))
    lines = ["### fa on terminal-bench", ""]
    problems = []

    if not paths:
        lines.append("**No results.json produced — the tb run did not complete.**")
        problems.append("no results.json produced")
    else:
        rows = []
        for p in paths:
            data = json.loads(Path(p).read_text())
            for r in data.get("results", []):
                resolved = r.get("is_resolved")
                mark = {True: "yes", False: "no", None: "pending"}[resolved]
                rows.append((
                    r.get("task_id", "?"), r.get("trial_name", "?"), mark,
                    r.get("failure_mode") or "",
                    r.get("total_input_tokens"), r.get("total_output_tokens"),
                ))
        n_resolved = sum(1 for r in rows if r[2] == "yes")
        accuracy = n_resolved / len(rows) if rows else 0.0
        missing = expected - len(rows) if expected is not None else 0
        note = (
            f" — {expected - len(rows)} of {expected} expected tasks missing"
            " (shard lost or timed out)" if expected is not None and len(rows) < expected else ""
        )
        lines.append(
            f"**{n_resolved}/{len(rows)} resolved — accuracy {accuracy:.0%}{note}**"
        )
        lines.append("")
        lines.append("| task | trial | resolved | failure mode | tokens in/out |")
        lines.append("|---|---|---|---|---|")
        for task, trial, mark, mode, tin, tout in rows:
            tokens = f"{tin}/{tout}" if tin is not None or tout is not None else ""
            lines.append(f"| {task} | {trial} | {mark} | {mode} | {tokens} |")

        if missing > 0:
            problems.append(f"only {len(rows)}/{expected} expected tasks attempted")

    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("\n".join(lines) + "\n")
    else:
        print("\n".join(lines))

    sys.exit(0 if no_fail or not problems else 1)


if __name__ == "__main__":
    main()
