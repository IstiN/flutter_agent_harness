#!/usr/bin/env python3
"""Resolution-rate summary for harbor job dirs.

Usage:
    summary.py [--expected-trials N] <jobs-dir>

Reads <jobs-dir>/<job>/*/result.json (per-trial TrialResults; each job's
top-level result.json is a file, not a dir, so the glob skips it) and
prints a GitHub-flavoured-markdown resolution table, also appending it to
$GITHUB_STEP_SUMMARY when set.

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
        rows.append({"resolved": resolved, "exception": exception})
    return rows


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

    lines = ["### fa on Terminal-Bench 4.0", ""]
    problems: list[str] = []

    if not job_dirs:
        lines.append("**No harbor jobs found — the run did not complete.**")
        problems.append("no harbor jobs found")
    else:
        total_resolved = total_rows = 0
        table = ["| split | resolved | rate |", "|---|---|---|"]
        for split, label in (("cpu", "CPU shards"), ("gpu", "GPU shards")):
            rows = splits[split]
            if not rows:
                table.append(f"| {label} | 0/0 | no trials |")
                continue
            scored = [r for r in rows if not r["exception"]]
            errored = len(rows) - len(scored)
            resolved = sum(1 for r in scored if r["resolved"])
            total_resolved += resolved
            total_rows += len(scored)
            note = f"{errored} errored" if errored else f"{resolved / len(scored):.1%}"
            table.append(f"| {label} | {resolved}/{len(scored)} | {note} |")
        lines.append(f"**Resolution: {total_resolved}/{total_rows} scored trials**")
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

        expected = args.expected_trials
        if expected is not None and total_rows < expected:
            lines.append("")
            lines.append(
                f"**Incomplete run: {total_rows}/{expected} expected trials attempted"
                " (lost or timed-out shard).**"
            )
            problems.append(f"only {total_rows}/{expected} expected trials attempted")

    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("\n".join(lines) + "\n")
    else:
        print("\n".join(lines))

    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
