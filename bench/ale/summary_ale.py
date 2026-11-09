#!/usr/bin/env python3
"""summary_ale.py — aggregate fa-on-ALE shard runs (issue #1686).

Input: one or more shard output roots (the ``.logs/ale-shard-<i>`` dirs
uploaded as per-shard artifacts). Each run unit lands as
``<root>/<agent_id>/<task...>/<variant>/<ts>/`` (RunWriter) with
``run.json`` + ``trajectory.json`` + ``eval_result.json`` + events.jsonl.

Outputs:
  * the markdown summary table + verdict on stdout (the workflow
    redirects into $GITHUB_STEP_SUMMARY),
  * ``--json-summary`` with the exact field names
    bench/leaderboard/record.py --summary consumes (family/model/
    resolved/total/date/fa_ref/run_url) so a complete full run can
    upsert the fa-results ledger (gh-1682 contract, self_reported).

Verdict rules (harbor summary parity):
  * a shard that contributed ZERO trials fails the run by name
    (gh-1658 C3),
  * coverage X/N over the expected task set; missing tasks listed.

resolved = eval_status == "success" and score >= 1.0 (ALE rewards are
graded in [0,1]; partial credit is not a resolution).
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_FAMILY = "ALE-v1.1-docker"


def _load_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        return None


def collect_trials(roots: list[Path]) -> list[dict]:
    """Walk shard roots → one row per run unit (per attempt)."""
    rows: list[dict] = []
    for root in roots:
        shard = root.name
        for run_json in sorted(root.rglob("run.json")):
            run_dir = run_json.parent
            run_meta = _load_json(run_json)
            if run_meta is None:
                continue  # unparsable run dir — skipped, never fatal
            eval_meta = _load_json(run_dir / "eval_result.json") or {}
            traj_meta = _load_json(run_dir / "trajectory.json") or {}
            final = traj_meta.get("final_metrics") or {}
            agent_id = run_meta.get("agent_id") or _agent_from_path(run_dir, root)
            rows.append(
                {
                    "shard": shard,
                    "task": run_meta.get("task_path") or run_meta.get("task") or "?",
                    "agent_id": agent_id,
                    "status": run_meta.get("status"),
                    "eval_status": eval_meta.get("eval_status"),
                    "score": eval_meta.get("score", run_meta.get("score")),
                    "error": eval_meta.get("error") or run_meta.get("error"),
                    "duration_s": run_meta.get("total_duration_s"),
                    "steps": final.get("total_steps"),
                    "input_tokens": final.get("total_input_tokens"),
                    "output_tokens": final.get("total_output_tokens"),
                    "cost_usd": final.get("total_cost_usd"),
                }
            )
    return rows


def _agent_from_path(run_dir: Path, root: Path) -> str:
    rel = run_dir.relative_to(root)
    return rel.parts[0] if rel.parts else "?"


def resolved(row: dict) -> bool:
    return row.get("eval_status") == "success" and _score(row) >= 1.0


def _score(row: dict) -> float:
    try:
        return float(row.get("score") or 0.0)
    except (TypeError, ValueError):
        return 0.0


def build_verdict(
    rows: list[dict],
    *,
    expected_tasks: int,
    expected_shards: int,
) -> tuple[bool, list[str]]:
    problems: list[str] = []
    shards_seen = sorted({row["shard"] for row in rows})
    counts: dict[str, int] = {shard: 0 for shard in shards_seen}
    for row in rows:
        counts[row["shard"]] = counts.get(row["shard"], 0) + 1
    if len(rows) == 0:
        problems.append("no trials found under the shard roots")
    else:
        empty = [s for s, n in counts.items() if n == 0]
        if empty:
            problems.append("shards with zero trials: " + ", ".join(empty))
    seen_tasks = {row["task"] for row in rows}
    if expected_tasks and len(rows) and len(seen_tasks) < expected_tasks:
        missing = expected_tasks - len(seen_tasks)
        problems.append(f"coverage {len(seen_tasks)}/{expected_tasks} ({missing} task(s) produced no run dir)")
    if expected_shards and len(rows) and len(shards_seen) < expected_shards:
        problems.append(f"only {len(shards_seen)}/{expected_shards} shards contributed artifacts")
    return (not problems), problems


def render_markdown(
    rows: list[dict],
    *,
    ok: bool,
    problems: list[str],
    model: str,
    run_label: str,
) -> str:
    lines = [
        f"## fa on Agents' Last Exam — {run_label}",
        "",
        f"Model: `{model}` · trials: {len(rows)} · "
        f"resolved: {sum(1 for r in rows if resolved(r))}",
        "",
        "| task | status | eval | score | dur (s) | steps | in/out tok |",
        "|---|---|---|---|---:|---:|---:|",
    ]
    for row in rows:
        score = "-" if row.get("score") is None else f"{_score(row):.2f}"
        lines.append(
            "| {task} | {status} | {eval_status} | {score} | {dur} | {steps} | {tok} |".format(
                task=str(row.get("task", "?"))[:80],
                status=row.get("status") or "?",
                eval_status=row.get("eval_status") or "?",
                score=score,
                dur=row.get("duration_s") if row.get("duration_s") is not None else "-",
                steps=row.get("steps") if row.get("steps") is not None else "-",
                tok=(
                    f"{row.get('input_tokens') or 0}/{row.get('output_tokens') or 0}"
                ),
            )
        )
    lines.append("")
    if ok:
        lines.append("verdict: PASS — all expected shards contributed; coverage complete")
    else:
        lines.append("verdict: FAIL")
        for problem in problems:
            lines.append(f"- {problem}")
    return "\n".join(lines) + "\n"


def json_summary(
    rows: list[dict],
    *,
    model: str,
    fa_ref: str,
    run_url: str,
    family: str,
) -> dict:
    """Exact consumer contract: bench/leaderboard/record.py --summary
    requires family/model/resolved/total/date (+fa_ref/run_url optional
    but expected)."""
    tasks = {row["task"]: row for row in rows}
    resolved_count = sum(1 for row in tasks.values() if resolved(row))
    return {
        "family": family,
        "model": model,
        "resolved": resolved_count,
        "total": len(tasks),
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "fa_ref": fa_ref,
        "run_url": run_url,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("roots", nargs="+", type=Path, help="shard output roots")
    parser.add_argument("--expected-tasks", type=int, default=0)
    parser.add_argument("--expected-shards", type=int, default=0)
    parser.add_argument("--model", default="glm-5.3-flash")
    parser.add_argument("--run-label", default="ALE-V1")
    parser.add_argument("--fa-ref", default="")
    parser.add_argument("--run-url", default="")
    parser.add_argument("--family", default=DEFAULT_FAMILY)
    parser.add_argument(
        "--json-summary",
        dest="json_summary",
        default=None,
        help="write the record.py-compatible totals JSON here",
    )
    args = parser.parse_args(argv)

    rows = collect_trials(args.roots)
    ok, problems = build_verdict(
        rows,
        expected_tasks=args.expected_tasks,
        expected_shards=args.expected_shards,
    )
    sys.stdout.write(
        render_markdown(
            rows, ok=ok, problems=problems, model=args.model, run_label=args.run_label
        )
    )
    if args.json_summary:
        Path(args.json_summary).write_text(
            json.dumps(
                json_summary(
                    rows,
                    model=args.model,
                    fa_ref=args.fa_ref,
                    run_url=args.run_url,
                    family=args.family,
                ),
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
