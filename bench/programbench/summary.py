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

Verdict wording (gh-1838 AC1): the ✅ structural verdict states the
structural facts only — "ran, were evaluated, and packaged". "Solved" has
a strict meaning here (solved_fraction: 100% of scored tests); the word
sits next to ✅ ONLY when every attempted instance is strictly solved.
When solved_n < attempted, an adjacent line carries the strict outcome
("Strictly solved 0/2 — solved requires 100% of scored tests"). The ❌
structural-problem path is unchanged.

Pricing resolution (gh-1838 AC5/AC6/AC7/AC8): bench/pricing.json loads
through fa_usage.load_pricing_resolved — every load/parse failure prints
a loud ⚠️ naming the path + error (an entry that exists must never
degrade to a silent n/a), the FA_BENCH_PRICING env channel (inline JSON
or a file path, same usd_per_mtok shape) merges OVER the repo default
per model key, the effective source is logged in the summary, optional
pricing aliases price a subscription-plan model as a LABELLED estimate
at an API model's rates (never mixed into _stats/cost.json), and the
cost split keeps the cache_read component visible.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import NamedTuple

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import fa_usage  # noqa: E402

BENCH_ROOT = Path(__file__).resolve().parent.parent  # bench/ (this file: bench/programbench/)
# gh-1838 root cause of the run's n/a: the old code named this REPO_ROOT
# and appended "bench/" again — bench/bench/pricing.json never existed,
# load_pricing swallowed the miss and every model silently rendered n/a.
DEFAULT_PRICING_PATH = BENCH_ROOT / "pricing.json"


def solved_fraction(score_map: dict) -> tuple[int, int, bool]:
    """(passed, total, solved) for one instance's {branch/test: bool} map."""
    total = len(score_map)
    passed = sum(1 for v in score_map.values() if v is True)
    return passed, total, total > 0 and passed == total


def instance_usage(tdir: Path, table: dict, aliases: dict) -> dict:
    """One instance's usage facts from its copied fa session logs.

    {calls, cost, alias, components} — calls None when the shard uploaded
    no sessions; cost None when unpriced; alias the model id an alias
    mapped to (the cost is then a LABELLED estimate at that model's
    rates, gh-1838 AC7 — callers keep it out of real-billing wires);
    components the per-component USD split (AC8), None when unpriced.
    """
    result: dict = {"calls": None, "cost": None, "alias": None, "components": None}
    sessions = tdir / "fa-artifacts" / "sessions"
    if not sessions.is_dir():
        return result
    usage = fa_usage.extract_from_dir(str(sessions))
    calls = 0
    for f in sessions.rglob("*.jsonl"):
        for line in f.read_text(errors="replace").splitlines():
            if '"role": "assistant"' not in line and '"role":"assistant"' not in line:
                continue
            if '"usage"' in line or '"inputTokens"' in line:
                calls += 1
    result["calls"] = calls
    model = usage.last_model
    entry, alias = fa_usage.resolve_entry(table, aliases, model)
    result["alias"] = alias
    if entry is None:
        return result
    result["cost"] = fa_usage.cost_usd(
        entry,
        usage.input_tokens,
        usage.output_tokens,
        usage.cache_read_tokens,
        usage.cache_write_tokens,
    )
    result["components"] = fa_usage.cost_components(
        entry,
        usage.input_tokens,
        usage.output_tokens,
        usage.cache_read_tokens,
        usage.cache_write_tokens,
    )
    return result


class SummaryResult(NamedTuple):
    """(text, exit_code, costs, calls) — text is the full summary output;
    costs/calls mirror the _stats wire (tests pin the no-estimate rule)."""

    text: str
    exit_code: int
    costs: dict
    calls: dict


def render(
    run_dir: Path,
    expected: int = 0,
    total: int = 0,
    mode: str = "full",
    run_label: str = "",
    fa_ref: str = "",
    run_url: str = "",
    resolved: fa_usage.ResolvedPricing | None = None,
) -> SummaryResult:
    """Build the whole summary. Returns SummaryResult(text, exit_code,
    costs, calls) — costs/calls are exactly what lands in _stats (the
    wire), so tests can pin the wire contract (gh-1838: alias estimates
    never ride it)."""
    if resolved is None:
        resolved = fa_usage.load_pricing_resolved(
            DEFAULT_PRICING_PATH,
            override=os.environ.get(fa_usage.PRICING_OVERRIDE_ENV),
        )
    table, aliases = resolved.table, resolved.aliases

    iids = sorted(p.name for p in run_dir.iterdir() if p.is_dir() and not p.name.startswith("_"))
    stats = run_dir / "_stats"
    score_path = stats / "score.json"
    score = json.loads(score_path.read_text()) if score_path.is_file() else {}

    # ── cost/calls: self-reported, from OUR trajectories (guide §3) ────
    costs: dict = {}
    calls: dict = {}
    estimates: dict = {}  # iid -> (estimated cost, alias target model)
    split = {"input": 0.0, "output": 0.0, "cache_read": 0.0, "cache_write": 0.0}
    est_split = {"input": 0.0, "output": 0.0, "cache_read": 0.0, "cache_write": 0.0}
    est_n = 0
    priced_n = 0
    unpriced = False
    for iid in iids:
        u = instance_usage(run_dir / iid, table, aliases)
        if u["calls"] is not None:
            calls[iid] = u["calls"]
        if u["cost"] is not None and u["alias"] is None:
            costs[iid] = round(u["cost"], 4)
            priced_n += 1
            for key in split:
                split[key] += u["components"][key]
        elif u["cost"] is not None and u["alias"] is not None:
            estimates[iid] = (u["cost"], u["alias"])
            est_n += 1
            for key in est_split:
                est_split[key] += u["components"][key]
        elif u["calls"] is not None:
            unpriced = True

    # ── the table ──────────────────────────────────────────────────────
    lines: list[str] = []
    lines.append("## ProgramBench run — fa")
    lines.append("")
    lines.append(f"| | |")
    lines.append(f"|---|---|")
    lines.append(f"| Run | {run_label} |")
    lines.append(f"| fa ref | `{fa_ref[:12]}` |")
    lines.append(f"| Mode | {mode} — {len(iids)} of {total} official instances |")
    lines.append(f"| Pricing | {resolved.source} |")
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
        if iid in costs:
            c_s = f"{costs[iid]:.4f}"
        elif iid in estimates:
            c_s = f"{estimates[iid][0]:.4f}*"
        elif iid in calls:
            c_s = "n/a"
        else:
            c_s = "-"
        lines.append(
            f"| {iid} | {passed_s} | {tests_s} | {solved} | {c_s} | {calls.get(iid, '-')} |"
        )
    solved_n = sum(1 for iid in iids if isinstance(score.get(iid), dict) and solved_fraction(score[iid])[2])
    lines.append("")

    # ── pricing notes: loud resolution, split, labelled estimates ──────
    for w in resolved.warnings:
        lines.append(f"⚠️ pricing: {w}")
    if unpriced:
        lines.append("")
        lines.append(
            "⚠️ at least one instance ran an unpriced model — its cost shows `n/a` "
            "(no entry in the loaded pricing table; supply one via FA_BENCH_PRICING, "
            "never an invented rate); calls are still reported."
        )
    if priced_n:
        total_cost = sum(split.values())
        if total_cost > 0:
            lines.append("")
            lines.append(
                f"Cost split over {priced_n} priced instance(s): "
                f"input ${split['input']:.4f} + output ${split['output']:.4f} "
                f"+ cache-read ${split['cache_read']:.4f} + cache-write ${split['cache_write']:.4f} "
                f"= ${total_cost:.4f} — cached reads dominate API-style cost; keep them in view."
            )
    targets = sorted({target for _, target in estimates.values()})
    est_total = sum(est_split.values())
    if est_n and est_total > 0:
        lines.append("")
        lines.append(
            f"Estimate split over {est_n} aliased instance(s) @ {'/'.join(targets)} rates: "
            f"input ${est_split['input']:.4f} + output ${est_split['output']:.4f} "
            f"+ cache-read ${est_split['cache_read']:.4f} + cache-write ${est_split['cache_write']:.4f} "
            f"= ${est_total:.4f} — cached reads dominate API-style cost; keep them in view."
        )
    for iid in sorted(estimates):
        est, target = estimates[iid]
        lines.append("")
        lines.append(
            f"* {iid}: cost shown is an estimate @ {target} rates (pricing alias — "
            "the plan is subscription-billed, not API metered). Never mixed with "
            "real billing: excluded from _stats/cost.json."
        )
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
    text = "\n".join(lines)
    exit_code = 0
    if problems:
        text += "\n\n## ❌ Verdict — structural problems\n\n"
        text += "\n".join(f"- {p}" for p in problems)
        exit_code = 1
        return SummaryResult(text, exit_code, costs, calls)
    attempted = expected or len(iids)
    if attempted and solved_n >= attempted:
        # Every attempted instance strictly solved: ✅ may say "solved".
        text += (
            f"\n\n## ✅ Verdict — all {attempted} attempted instances solved "
            "(100% of scored tests each), evaluated, and packaged"
        )
    else:
        # Structural success only — "solved" is stated strictly, adjacent.
        text += f"\n\n## ✅ Verdict — all {attempted} attempted instances ran, were evaluated, and packaged"
        if attempted:
            text += (
                f"\nStrictly solved {solved_n}/{attempted} — solved requires "
                "100% of scored tests."
            )
    return SummaryResult(text, exit_code, costs, calls)


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
    resolved = fa_usage.load_pricing_resolved(
        DEFAULT_PRICING_PATH,
        override=os.environ.get(fa_usage.PRICING_OVERRIDE_ENV),
    )
    result = render(
        run_dir,
        expected=expected,
        total=total,
        mode=mode,
        run_label=run_label,
        fa_ref=fa_ref,
        run_url=run_url,
        resolved=resolved,
    )

    # ── _stats: the registry wire — real billing only (gh-1838 AC7) ────
    stats = run_dir / "_stats"
    stats.mkdir(exist_ok=True)
    (stats / "cost.json").write_text(json.dumps(result.costs, indent=2, sort_keys=True))
    (stats / "calls.json").write_text(json.dumps(result.calls, indent=2, sort_keys=True))

    for w in resolved.warnings:
        print(f"[pricing] {w}", file=sys.stderr)
    print(result.text)
    return result.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
