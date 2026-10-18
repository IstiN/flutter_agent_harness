#!/usr/bin/env python3
"""Aggregate + step-summary for bench-programbench.yml (gh-1685).

Runs in the aggregate job AFTER `programbench submit package` (so
_stats/score.json exists — the tool's own ignored-test-filtered map, never
recomputed here) and BEFORE the Tier-0 verify gate:

  1. computes self-reported per-instance cost/calls from the fa session
     logs (bench/fa_usage.py + bench/pricing.json — the #1123 pipeline)
     into _stats/cost.json + _stats/calls.json, the registry's
     {instance_id: value} convention (package preserves sibling _stats
     files; verified against programbench 1.2.5);
  2. renders the markdown summary table (accuracy/cost/calls per task,
     bench-harbor style) on stdout;
  3. fails the run on structural problems: any expected task missing its
     submission.tar.gz / eval.json / packaged score, or a zero-package run
     (a lost shard must never masquerade as a score — the MLS precedent).

Score display: solved = every scored test true (the ✅ convention — a
100-after-rounding instance that isn't solved is NOT solved). The headline
mean is reported over the FULL official set (package divides by `total`,
so a partial run's number is diluted by design; the table is explicit
about it).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import fa_usage  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent


def solved_fraction(score_map: dict) -> tuple[int, int, bool]:
    """(passed, total, solved) for one instance's {branch/test: bool} map."""
    total = len(score_map)
    passed = sum(1 for v in score_map.values() if v is True)
    return passed, total, total > 0 and passed == total


def instance_usage(tdir: Path, pricing: dict) -> tuple[float | None, int | None]:
    """(cost_usd | None when unpriced, api_calls) from the shard's copied
    fa session logs; (None, None) when the shard uploaded no sessions."""
    sessions = tdir / "fa-artifacts" / "sessions"
    if not sessions.is_dir():
        return None, None
    usage = fa_usage.extract_from_dir(str(sessions))
    calls = 0
    for f in sessions.rglob("*.jsonl"):
        for line in f.read_text(errors="replace").splitlines():
            if '"role": "assistant"' not in line and '"role":"assistant"' not in line:
                continue
            if '"usage"' in line or '"inputTokens"' in line:
                calls += 1
    model = usage.last_model
    entry = fa_usage.price_entry(pricing, model)
    cost = fa_usage.cost_usd(
        entry,
        usage.input_tokens,
        usage.output_tokens,
        usage.cache_read_tokens,
        usage.cache_write_tokens,
    )
    return cost, calls


def main() -> int:
    a = sys.argv[1:]
    run_dir = Path(a[0])

    def opt(flag: str, default: str = "") -> str:
        return a[a.index(flag) + 1] if flag in a else default

    expected = int(opt("--expected", "0"))
    total = int(opt("--total", "0"))
    mode = opt("--mode", "full")
    run_label = opt("--run-label")
    fa_ref = opt("--fa-ref")
    run_url = opt("--run-url")
    pricing = fa_usage.load_pricing(str(REPO_ROOT / "bench" / "pricing.json"))

    iids = sorted(p.name for p in run_dir.iterdir() if p.is_dir() and not p.name.startswith("_"))
    stats = run_dir / "_stats"
    score_path = stats / "score.json"
    score = json.loads(score_path.read_text()) if score_path.is_file() else {}

    # ── cost/calls: self-reported, from OUR trajectories (guide §3) ────
    costs: dict = {}
    calls: dict = {}
    unpriced = False
    for iid in iids:
        cost, n = instance_usage(run_dir / iid, pricing)
        if n is not None:
            calls[iid] = n
        if cost is not None:
            costs[iid] = round(cost, 4)
        elif n is not None:
            unpriced = True
    stats.mkdir(exist_ok=True)
    (stats / "cost.json").write_text(json.dumps(costs, indent=2, sort_keys=True))
    (stats / "calls.json").write_text(json.dumps(calls, indent=2, sort_keys=True))

    # ── the table ──────────────────────────────────────────────────────
    lines: list[str] = []
    lines.append("## ProgramBench run — fa")
    lines.append("")
    lines.append(f"| | |")
    lines.append(f"|---|---|")
    lines.append(f"| Run | {run_label} |")
    lines.append(f"| fa ref | `{fa_ref[:12]}` |")
    lines.append(f"| Mode | {mode} — {len(iids)} of {total} official instances |")
    lines.append("")
    lines.append("| instance | passed | tests | solved | cost (USD) | calls |")
    lines.append("|---|---|---|---|---|---|")
    for iid in iids:
        m = score.get(iid)
        if isinstance(m, dict):
            p, t, ok = solved_fraction(m)
            solved = "✅" if ok else "—"
            passed_s, tests_s = str(p), str(t)
        else:
            solved, passed_s, tests_s = "⚠️ no score", "-", "-"
        c = costs.get(iid)
        c_s = f"{c:.4f}" if isinstance(c, (int, float)) else ("n/a" if iid in calls else "-")
        lines.append(
            f"| {iid} | {passed_s} | {tests_s} | {solved} | {c_s} | {calls.get(iid, '-')} |"
        )
    solved_n = sum(1 for iid in iids if isinstance(score.get(iid), dict) and solved_fraction(score[iid])[2])
    lines.append("")
    if mode != "full":
        dilution = len(iids) / total if total else 0.0
        lines.append(
            f"**Solved {solved_n}/{len(iids)} attempted.** The package headline "
            f"(`_stats` mean) divides by the full official set ({total}), so it reads "
            f"~{dilution:.1%} of the attempted score — a partial run is a pipeline "
            "proof, not a leaderboard row. Full runs need `tasks: ''` + "
            "`confirm-full-run: true`."
        )
    else:
        lines.append(f"**Solved {solved_n}/{len(iids)} — headline pass@1 over the full official set.**")
    if unpriced:
        lines.append("")
        lines.append("⚠️ at least one instance ran an unpriced model — its cost shows `n/a` (bench/pricing.json has no entry); calls are still reported.")
    if run_url:
        lines.append("")
        lines.append(f"Run: {run_url}")

    # ── verdict ────────────────────────────────────────────────────────
    problems = []
    for iid in iids:
        if not (run_dir / iid / "submission.tar.gz").is_file():
            problems.append(f"{iid}: no submission.tar.gz (solve crashed before packing)")
        if not (run_dir / iid / f"{iid}.eval.json").is_file() and not (run_dir / iid / f"{iid}.eval.log.json").is_file():
            problems.append(f"{iid}: no eval.json (eval never ran or crashed)")
    packaged = [i for i in iids if isinstance(score.get(i), dict)]
    if expected and len(iids) != expected:
        problems.append(f"shard completeness: {len(iids)} task dirs present, expected {expected} — a shard lost work")
    if expected and len(packaged) != expected:
        problems.append(f"package completeness: {len(packaged)}/{expected} instances scored in _stats/score.json")
    if problems:
        print("\n".join(lines))
        print("\n## ❌ Verdict — structural problems\n")
        for p in problems:
            print(f"- {p}")
        return 1
    print("\n".join(lines))
    print(f"\n## ✅ Verdict — all {expected or len(iids)} attempted instances solved, evaluated, and packaged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
