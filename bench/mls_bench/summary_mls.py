#!/usr/bin/env python3
"""Per-domain aggregate + restore-and-inspect for bench-mls.yml (issue #1160).

Usage:
    summary_mls.py [--run-config mls-run-config.json] <jobs-dir>

Reads <jobs-dir>/<agent-job>/<trial>/result.json (only job dirs named
*-agent-shard-*; the nop/oracle ladder jobs are ladder evidence, not scores)
and writes to $GITHUB_STEP_SUMMARY (or stdout):

  - run identity replay (AC6): dataset SHA, model, fa commit, budget statement
  - per-domain arithmetic mean of combined_score (upstream scoring: each
    task's verifier emits a single combined_score in [0, 1]; the paper
    aggregates tasks within an area by arithmetic mean)
  - E1: which of this run's tasks carry a >24h agent+verifier budget when
    provider=modal (clip risk surfaced, not hidden)
  - comparability guard (contract 4): any trial whose recorded config used a
    timeout multiplier or override_timeout_sec fails the step
  - completeness verdict: fewer attempted trials than expected fails the step
    (harbor exits 0 even with lost trials)

Exit 1 only for infra problems (incomplete run, comparability violation,
missing run-config fields). Errored trials are routine frontier-run outcomes
(5h agent budgets time out); they are reported as ::warning:: annotations and
kept out of the per-domain means - the scoreboard, not a failure. stdlib-only.
"""
import argparse
import json
import os
import sys
from pathlib import Path

REQUIRED_RUN_FIELDS = (
    "mls_bench_sha", "provider", "subset", "model", "fa_commit",
    "agent_budget", "expected_trials", "tasks",
)
AGENT_JOB_MARKER = "-agent-shard-"


def load_trials(jobs_dir: Path) -> list[dict]:
    rows = []
    for path in sorted(jobs_dir.glob("*/*/result.json")):
        job = path.parents[1].name
        if AGENT_JOB_MARKER not in job:
            continue
        rows.append({
            "job": job,
            "trial": path.parent.name,
            "data": json.loads(path.read_text()),
        })
    return rows


def trial_task(data: dict) -> str:
    """Short task name ('ml-clustering-algorithm') from a TrialResult."""
    name = data.get("task_name") or ""
    return name.split("__")[-1]


def trial_score(data: dict) -> float | None:
    """The verifier's combined_score in [0, 1]; upstream emits one reward."""
    rewards = (data.get("verifier_result") or {}).get("rewards") or {}
    values = [float(v) for v in rewards.values()]
    return sum(values) / len(values) if values else None


def aggregate(rows: list[dict], areas: dict[str, str]) -> tuple[dict[str, list[float]], list[str]]:
    """-> (area -> scores, errored task names). Errored trials are harness
    failures, not scores (same semantics as bench/harbor_fa/summary.py)."""
    per: dict[str, list[float]] = {}
    errored: list[str] = []
    for row in rows:
        data = row["data"]
        exception = (data.get("exception_info") or {}).get("exception_type") or ""
        if exception:
            errored.append(trial_task(data))
            continue
        try:
            score = trial_score(data)
        except (TypeError, ValueError):
            errored.append(trial_task(data))
            continue
        if score is None:
            errored.append(trial_task(data))
            continue
        per.setdefault(areas.get(trial_task(data), "other"), []).append(score)
    return per, errored


def comparability_violations(rows: list[dict]) -> list[str]:
    """Contract 4: a run that changed the 5h budget is not comparable."""
    bad = []
    for row in rows:
        config = row["data"].get("config") or {}
        multiplier = config.get("timeout_multiplier")
        if multiplier is not None:
            try:
                value = float(multiplier)
            except (TypeError, ValueError):
                bad.append(f"{row['trial']}: unparseable timeout_multiplier={multiplier!r}")
                continue
            if value != 1.0:
                bad.append(f"{row['trial']}: timeout_multiplier={multiplier}")
        if config.get("override_timeout_sec") is not None:
            bad.append(f"{row['trial']}: override_timeout_sec={config['override_timeout_sec']}")
    return bad


def clip_flag(run_config: dict, rows: list[dict]) -> list[str]:
    """E1: run tasks whose agent+verifier budget exceeds Modal's 24h cap."""
    if run_config.get("provider") != "modal":
        return []
    run_tasks = {trial_task(row["data"]) for row in rows}
    return [
        name for name in run_config.get("clip_risk_modal", [])
        if name.removeprefix("mls-bench__") in run_tasks
    ]


def build_summary(run_config: dict, rows: list[dict]) -> tuple[list[str], list[str], list[str]]:
    """-> (summary lines, structural problems, outcome warnings).

    Problems fail the step (infra/comparability); warnings are ::warning::
    annotations for ordinary outcomes like errored trials (review round 3,
    -ayZ: a timed-out frontier task must not train anyone to ignore the
    verdict that catches real infra failures).
    """
    lines = ["### fa on MLS-Bench", ""]
    problems: list[str] = []
    warnings: list[str] = []

    missing = [k for k in REQUIRED_RUN_FIELDS if run_config.get(k) in (None, "")]
    if missing:
        problems.append(f"run-config.json missing field(s): {', '.join(missing)}")
        lines.append("**Incomplete run-config artifact - run identity cannot be replayed.**")
        return lines, problems, warnings

    # AC6 restore-and-inspect: replay the exact run identity from the bundle.
    lines += [
        f"- dataset: Imbernoulli/MLS-Bench @ `{run_config['mls_bench_sha']}` "
        f"(subset `{run_config['subset']}`, {len(run_config['tasks'])} tasks)",
        f"- model: `{run_config['model']}` (fa commit `{run_config['fa_commit']}`)",
        f"- provider: {run_config['provider']} (gpu_type {run_config.get('gpu_type', 'H100')}), "
        f"harbor {run_config.get('harbor_version', '?')}, attempts {run_config.get('attempts', 1)}",
        f"- budget: {run_config['agent_budget']}",
        "",
    ]

    if not rows:
        lines.append("**No agent trials found - the run did not complete.**")
        problems.append("no agent trials found")
        return lines, problems, warnings

    per, errored = aggregate(rows, run_config.get("areas") or {})
    table = ["| area | tasks | arithmetic mean combined_score |", "|---|---|---|"]
    all_scores: list[float] = []
    for area in sorted(per):
        scores = per[area]
        all_scores += scores
        table.append(f"| {area} | {len(scores)} | {sum(scores) / len(scores):.4f} |")
    if all_scores:
        table.append(f"| **overall** | {len(all_scores)} | {sum(all_scores) / len(all_scores):.4f} |")
    lines += table

    if errored:
        lines += [
            "",
            f"Errored/unscored trials ({len(errored)}): " + ", ".join(sorted(set(errored))),
        ]
        warnings.append(f"{len(errored)} trial(s) errored before producing a verdict (reported, not failing)")

    clips = clip_flag(run_config, rows)
    if clips:
        lines += [
            "",
            "**Modal 24h sandbox cap (E1):** the following run tasks declare "
            "agent+verifier budgets beyond one sandbox and can be cut off "
            "while verifying (budget is a ceiling, not a reservation): "
            + ", ".join(sorted(clips)),
        ]

    violations = comparability_violations(rows)
    if violations:
        problems.append("timeout knobs recorded in trial configs: " + "; ".join(violations))

    expected = int(run_config["expected_trials"])
    if len(rows) < expected:
        lines += [
            "",
            f"**Incomplete run: {len(rows)}/{expected} expected trials attempted (lost shard).**",
        ]
        problems.append(f"only {len(rows)}/{expected} expected trials attempted")

    return lines, problems, warnings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("jobs_dir", type=Path)
    parser.add_argument("--run-config", type=Path, default=Path("mls-run-config.json"))
    args = parser.parse_args()

    try:
        run_config = json.loads(args.run_config.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"::error::run-config artifact unreadable: {exc}", file=sys.stderr)
        return 1

    lines, problems, warnings = build_summary(run_config, load_trials(args.jobs_dir))
    text = "\n".join(lines) + "\n"
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(text)
    else:
        print(text, end="")

    for warning in warnings:
        print(f"::warning::{warning}", file=sys.stderr)
    for problem in problems:
        print(f"::error::{problem}", file=sys.stderr)
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
