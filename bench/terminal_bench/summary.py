#!/usr/bin/env python3
"""Accuracy summary for terminal-bench run dirs.

Usage:
    summary.py [--no-fail] <runs-dir> [expected-count] [--model MODEL_ID]

Reads every <runs-dir>/*/results.json (sharded runs pin --run-id, so one
subdir per shard) and prints a GitHub-flavoured-markdown accuracy table,
also appending it to $GITHUB_STEP_SUMMARY when set.

Token/cost columns (issue #1123): total_input/output_tokens come from the
trial's fa session records (folded in by fa_agent.py at perform_task time).
Per-trial cost is derived from the pinned price table bench/pricing.json
($/Mtok, data not code); the model id is taken from the trial's synced
session records when present, else --model (or the MODEL /
FA_PROVIDER_CONFIG env), else the cost renders n/a — never a made-up
price. Tokens estimated where a provider omitted usage (chars/4, done by
fa_agent.py) are flagged in a note when > 0.

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

_BENCH_DIR = str(Path(__file__).resolve().parent.parent)
if _BENCH_DIR not in sys.path:
    sys.path.insert(0, _BENCH_DIR)
import fa_usage

_PRICING_PATH = Path(_BENCH_DIR) / "pricing.json"


def _model_override():
    """--model flag, then MODEL / FA_PROVIDER_CONFIG env, else None."""
    args = sys.argv[1:]
    if "--model" in args:
        i = args.index("--model")
        if i + 1 < len(args):
            return args[i + 1]
    if os.environ.get("MODEL"):
        return os.environ["MODEL"]
    config = os.environ.get("FA_PROVIDER_CONFIG")
    if config:
        try:
            return json.loads(config).get("model")
        except json.JSONDecodeError:
            pass
    return None


def _session_facts(runs_dir: Path) -> dict:
    """trial_name → {"model": str|None, "estimated": int} from synced sessions.

    tb ships each trial's fa sessions in the run artifacts
    (<run>/<task>/<trial>/agent-logs|agent/fah-sessions). Best-effort and
    fail-soft: old artifacts without session logs just yield no facts.
    """
    facts = {}
    try:
        # <runs>/<run>/<task>/<trial>/agent-logs|agent/fah-sessions (both
        # the tb-synced and the pinned issue layout have 4 levels above).
        candidates = list(runs_dir.glob("*/*/*/*/fah-sessions"))
    except OSError:
        return facts
    for sessions in candidates:
        usage = fa_usage.extract_from_dir(sessions)
        models = sorted(m for m in usage.models if m)
        facts[sessions.parent.parent.name] = {
            # One model per trial is the norm; mixed → None (cost n/a).
            "model": models[0] if len(models) == 1 else None,
            "estimated": usage.estimated_tokens,
        }
    return facts


def _cost_cell(pricing, facts, trial, tin, tout, model_override):
    """(cost_usd|None, model) for one trial row; None cost renders n/a."""
    model = (facts.get(trial) or {}).get("model") or model_override
    entry = fa_usage.price_entry(pricing, model) if model else None
    if entry is None:
        return None, model
    return fa_usage.cost_usd(entry, tin or 0, tout or 0), model


def render(runs_dir: Path, expected=None, model_override=None):
    """Build the summary (lines, problems) for a runs dir — pure, testable."""
    runs_dir = Path(runs_dir)
    paths = sorted(glob.glob(str(runs_dir / "*" / "results.json")))
    lines = ["### fa on terminal-bench", ""]
    problems = []

    if not paths:
        lines.append("**No results.json produced — the tb run did not complete.**")
        problems.append("no results.json produced")
        return lines, problems

    pricing = fa_usage.load_pricing(_PRICING_PATH)
    facts = _session_facts(runs_dir)
    rows = []
    for p in paths:
        data = json.loads(Path(p).read_text())
        for r in data.get("results", []):
            resolved = r.get("is_resolved")
            mark = {True: "yes", False: "no", None: "pending"}[resolved]
            tin = r.get("total_input_tokens")
            tout = r.get("total_output_tokens")
            cost, model = _cost_cell(
                pricing, facts, r.get("trial_name", "?"), tin, tout, model_override
            )
            rows.append((
                r.get("task_id", "?"), r.get("trial_name", "?"), mark,
                r.get("failure_mode") or "", tin, tout, cost,
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

    # Failure families (issue #142): the re-run delta is reported per
    # cluster, not just as one accuracy number. `unset` covers both
    # resolved trials (tb's default mode) and unresolved ones whose
    # tests ran and failed — the model side.
    modes = {}
    for _, _, mark, mode, _, _, _ in rows:
        modes[(mode or "unset", mark)] = modes.get((mode or "unset", mark), 0) + 1
    lines.append("Failure families (mode x resolved):")
    for (mode, mark), n in sorted(modes.items()):
        lines.append(f"- {mode or 'unset'} / {mark}: {n}")
    lines.append("")

    # Token/cost totals (issue #1123): sums over exactly the rows above.
    total_in = sum(r[4] or 0 for r in rows)
    total_out = sum(r[5] or 0 for r in rows)
    priced = [r[6] for r in rows if r[6] is not None]
    unpriced = len(rows) - len(priced)
    if any(r[4] or r[5] for r in rows):
        cost_total = f"${sum(priced):.4f}" if priced else "n/a"
        suffix = f" — {unpriced} trial(s) unpriced (model missing from pricing.json)" if unpriced else ""
        lines.append(f"**tokens in/out: {total_in}/{total_out} — est. cost: {cost_total}{suffix}**")
        estimated = sum((facts.get(r[1]) or {}).get("estimated", 0) for r in rows)
        if estimated:
            lines.append(
                f"includes ~{estimated} estimated tokens (chars/4 where the provider omitted usage)"
            )
    lines.append("| task | trial | resolved | failure mode | tokens in/out | est cost |")
    lines.append("|---|---|---|---|---|---|")
    for task, trial, mark, mode, tin, tout, cost in rows:
        tokens = f"{tin}/{tout}" if tin is not None or tout is not None else ""
        cost_cell = "n/a" if cost is None else f"${cost:.4f}"
        lines.append(f"| {task} | {trial} | {mark} | {mode} | {tokens} | {cost_cell} |")

    if missing > 0:
        problems.append(f"only {len(rows)}/{expected} expected tasks attempted")
    return lines, problems


def main():
    args = sys.argv[1:]
    no_fail = "--no-fail" in args
    args = [a for a in args if a != "--no-fail"]
    if "--model" in args:
        i = args.index("--model")
        args = args[:i] + args[i + 2 :]
    runs_dir = Path(args[0])
    expected = int(args[1]) if len(args) > 1 else None

    lines, problems = render(runs_dir, expected, _model_override())

    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("\n".join(lines) + "\n")
    else:
        print("\n".join(lines))

    sys.exit(0 if no_fail or not problems else 1)


if __name__ == "__main__":
    main()
