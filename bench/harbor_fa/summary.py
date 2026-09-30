#!/usr/bin/env python3
"""Resolution-rate summary for harbor job dirs.

Usage:
    summary.py [--expected-trials N] <jobs-dir>

Reads <jobs-dir>/<job>/*/result.json (per-trial TrialResults; each job's
top-level result.json is a file, not a dir, so the glob skips it) and
prints a GitHub-flavoured-markdown resolution table, also appending it to
$GITHUB_STEP_SUMMARY when set.

Token/cost columns (issue #1123): each trial's fa session usage is folded
into result.json's agent_result by fa_agent.py (n_input/n_output/
n_cache_tokens, estimated share in metadata, cost_usd derived from the
pinned bench price table bench/pricing.json — null renders n/a, never a
made-up price). The table gains per-split tokens/cost columns next to the
resolution rate; a spend line carries the overall totals.

Jobs named fa-4.0-<env>-gpu-<shard> count as the GPU split; everything
else is CPU (bench-4.0.yml names jobs fa-4.0-<env>-<kind>-<shard>; the
legacy fa-4.0-{docker,modal}-<shard> names map modal -> GPU).

A trial is resolved when every verifier reward is 1.0; the resolution rate
is resolved trials / attempted trials. harbor exits 0 even with unresolved
trials, so the exit code is the verdict on run COMPLETENESS only: 1 when
nothing was produced or fewer than --expected-trials trials were attempted
(lost shard). Unresolved trials are the scoreboard, not an infra failure —
reported without failing the step.
"""
import argparse
import glob
import json
import os
import sys
from pathlib import Path


def _trial_rows(job_dir: Path) -> list[dict]:
    rows = []
    for path in sorted(glob.glob(str(job_dir / "*" / "result.json"))):
        data = json.loads(Path(path).read_text())
        rewards = (data.get("verifier_result") or {}).get("rewards") or {}
        scores = [float(v) for v in rewards.values()]
        resolved = bool(scores) and all(v >= 1.0 for v in scores)
        exception = (data.get("exception_info") or {}).get("exception_type") or ""
        # Issue #1123: token/cost accounting folded in by fa_agent.py at
        # populate_context_post_run time; absent (old runs) → zeros + n/a.
        agent = data.get("agent_result") or {}
        metadata = agent.get("metadata") or {}
        rows.append({
            "resolved": resolved,
            "exception": exception,
            "tokens_in": agent.get("n_input_tokens") or 0,
            "tokens_out": agent.get("n_output_tokens") or 0,
            "cost": agent.get("cost_usd"),
            "estimated": metadata.get("estimated_tokens") or 0,
        })
    return rows


def render(splits: dict, expected=None):
    """Build the summary (lines, problems) — pure, testable."""
    lines = ["### fa on Terminal-Bench 4.0", ""]
    problems: list[str] = []
    has_jobs = any(rows for rows in splits.values())

    if not has_jobs:
        lines.append("**No harbor jobs found — the run did not complete.**")
        problems.append("no harbor jobs found")
        return lines, problems

    total_resolved = total_rows = 0
    total_in = total_out = total_est = 0
    costs: list[float] = []
    unpriced = 0
    table = [
        "| split | resolved | rate | tokens in/out | est cost |",
        "|---|---|---|---|---|",
    ]
    for split, label in (("cpu", "CPU shards"), ("gpu", "GPU shards")):
        rows = splits[split]
        if not rows:
            table.append(f"| {label} | 0/0 | no trials | — | n/a |")
            continue
        scored = [r for r in rows if not r["exception"]]
        errored = len(rows) - len(scored)
        resolved = sum(1 for r in scored if r["resolved"])
        total_resolved += resolved
        total_rows += len(scored)
        note = f"{errored} errored" if errored else f"{resolved / len(scored):.1%}"
        split_in = sum(r["tokens_in"] for r in scored)
        split_out = sum(r["tokens_out"] for r in scored)
        split_costs = [r["cost"] for r in scored if r["cost"] is not None]
        unpriced += sum(1 for r in scored if r["tokens_in"] and r["cost"] is None)
        costs.extend(split_costs)
        total_in += split_in
        total_out += split_out
        total_est += sum(r["estimated"] for r in scored)
        cost_cell = f"${sum(split_costs):.4f}" if split_costs else "n/a"
        table.append(
            f"| {label} | {resolved}/{len(scored)} | {note} | {split_in}/{split_out} | {cost_cell} |"
        )
    lines.append(f"**Resolution: {total_resolved}/{total_rows} scored trials**")
    if total_in or total_out:
        cost_total = f"${sum(costs):.4f}" if costs else "n/a"
        suffix = f" — {unpriced} trial(s) unpriced (model missing from pricing.json)" if unpriced else ""
        lines.append(f"**Spend: {cost_total} — tokens in/out: {total_in}/{total_out}{suffix}**")
        if total_est:
            lines.append(
                f"includes ~{total_est} estimated tokens (chars/4 where the provider omitted usage)"
            )
    lines.append("")
    lines.extend(table)

    exceptions: dict[str, int] = {}
    for rows in splits.values():
        for r in rows:
            if r["exception"]:
                exceptions[r["exception"]] = exceptions.get(r["exception"], 0) + 1
    if exceptions:
        lines.append("")
        lines.append(
            "Errored trials (harness/infra failure, not scored): "
            + ", ".join(f"{k} ×{v}" for k, v in sorted(exceptions.items()))
        )
        problems.append(
            f"{sum(exceptions.values())} trial(s) errored before producing a verdict"
        )

    if expected is not None and total_rows < expected:
        lines.append("")
        lines.append(
            f"**Incomplete run: {total_rows}/{expected} expected trials attempted"
            " (lost or timed-out shard).**"
        )
        problems.append(f"only {total_rows}/{expected} expected trials attempted")
    return lines, problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("jobs_dir", type=Path)
    parser.add_argument("--expected-trials", type=int, default=None)
    args = parser.parse_args()

    splits: dict[str, list[dict]] = {"cpu": [], "gpu": []}
    job_dirs = [d for d in sorted(args.jobs_dir.glob("*")) if d.is_dir()]
    for job_dir in job_dirs:
        name = job_dir.name
        if "-gpu-" in name:
            split = "gpu"
        elif "-cpu-" in name:
            split = "cpu"
        else:
            # legacy scheme: docker shards were CPU, modal was the GPU leg
            split = "gpu" if "modal" in name else "cpu"
        splits[split].extend(_trial_rows(job_dir))

    lines, problems = render(splits, args.expected_trials)

    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("\n".join(lines) + "\n")
    else:
        print("\n".join(lines))

    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
