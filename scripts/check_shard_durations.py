#!/usr/bin/env python3
"""Shard duration-budget gate with auto-filer (gh-1300).

The per-suite duration ratchet (check_test_durations.py, issue #928)
budgets each SUITE against measured spans. This gate adds the missing
half: a budget per SHARD — expected runner wall time + 15-20% headroom —
so the total leg time gets teeth too. Breach handling is the same
self-filing pattern as the flake-quarantine machine (gh-1199) and the
nightly-red filer (gh-1267 N3):

  - the gate FAILS the run (loud, exit 1), and
  - writes an `[ENH]` optimization-issue body (measured vs budget,
    slowest tests, run link) the workflow files/updates under the
    `duration-budget` label — crossing the line always produces work,
    never a silent bump of the limit.

Ratchet law (same shape as the CRAP ratchet): a budget only moves DOWN
via optimization PRs (`--update-budgets` refuses to raise; no workflow
may call it); raising one requires a hand-edited reviewed PR with a
written justification. The auto-filed issue closes when the run fits
under the budget again (workflow close-step).

Metric: shard WALL = max(testDone) - min(testStart) over the real tests
in the shard's dart-json file-reporter output (the runner's own clock;
setup like checkout/pub get/AOT download is outside it, deliberately —
the budget owns the test-run span, the thing per-test spawn overhead
moves). Torn/partial report lines are skipped, never fatal.

Budgets live in ONE place next to this gate:
scripts/test_shard_budgets.json (`warn_fraction` + per-shard seconds).
An unbudgeted shard that RAN is a failure (a new shard cannot sneak past
the ratchet); a budgeted shard with no report is a failure too (a
dropped shard must leave the ratchet through a reviewed edit, not by
disappearing).

Usage:
  check_shard_durations.py [--budgets PATH] [--issue-body PATH]
                           [--run-url URL] JSON [JSON ...]
  check_shard_durations.py --update-budgets [--budgets PATH] JSON ...

Exit 1 on any budget failure (or a refused raise in update mode).
Pure stdlib.
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone

TOP_N = 10

DEFAULT_BUDGETS = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "test_shard_budgets.json",
)


def shard_id(json_path: str) -> str:
    """Shard id from the report filename (`integration-shard-0.json` -> 0).

    A report without the shard pattern (nightly's single
    `integration.json`) maps to the stem — budgets key it as-is.
    """
    name = os.path.basename(json_path)
    m = re.search(r"shard-(\d+)", name)
    return m.group(1) if m else os.path.splitext(name)[0]


def shard_wall(json_path: str):
    """-> (wall_seconds, span_seconds, [(suite, name, dur_s)]) or None."""
    starts = {}  # testID -> (suite path, name, start ms)
    rows = []
    suites = {}
    with open(json_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue  # torn/partial line — never fatal for timing data
            kind = ev.get("type")
            if kind == "suite":
                suites[ev["suite"]["id"]] = ev["suite"].get("path", "")
            elif kind == "testStart":
                starts[ev["test"]["id"]] = (
                    suites.get(ev["test"]["suiteID"], ""),
                    ev["test"].get("name", ""),
                    ev["time"],
                )
            elif kind == "testDone":
                tid = ev.get("testID")
                if tid not in starts or ev.get("hidden", False):
                    continue
                suite, name, t0 = starts.pop(tid)
                rows.append((suite, name, t0, max(ev["time"] - t0, 0.0)))
    if not rows:
        return None
    wall = max(r[2] + r[3] for r in rows) - min(r[2] for r in rows)
    return wall / 1000.0, sum(r[3] for r in rows) / 1000.0, [
        (suite, name, ms / 1000.0) for suite, name, _t0, ms in rows
    ]


def load_budgets(path: str):
    if not os.path.exists(path):
        return {"_meta": {}, "warn_fraction": 0.9, "shards": {}}
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    return {
        "_meta": data.get("_meta", {}),
        "warn_fraction": data.get("warn_fraction", 0.9),
        "shards": data.get("shards", {}),
    }


def write_summary(lines):
    block = "\n".join(lines) + "\n"
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if target:
        with open(target, "a", encoding="utf-8") as fh:
            fh.write(block)
    print(block, end="")


def slowest_table(rows):
    lines = [
        f"Top {TOP_N} slowest tests (breaching shards):",
        "",
        "| # | time (s) | suite | test |",
        "|---|---------:|-------|------|",
    ]
    ranked = sorted(rows, key=lambda r: (-r[2], r[0], r[1]))[:TOP_N]
    for i, (suite, name, dur) in enumerate(ranked, 1):
        lines.append(f"| {i} | {dur:.1f} | `{suite}` | {name} |")
    return lines


def issue_body(breaches, warn_rows, run_url):
    """The `[ENH]` optimization-issue markdown (gh-1300 auto-filer)."""
    now = datetime.now(timezone.utc).date().isoformat()
    lines = [
        "Shard duration budget BREACHED (gh-1300 auto-filer) — the run "
        "exceeded expected shard time + headroom, so the gate failed and "
        f"this issue exists. Detected {now}.",
        "",
        "Suggested title: `[ENH] PTY/CLI shard duration budget breach "
        "(auto-filed)` — comment updates on this issue per red run; close "
        "it when a run fits under the budget again.",
        "",
        "| shard | measured wall (s) | budget (s) | over by |",
        "|-------|------------------:|-----------:|--------:|",
    ]
    for sid, wall, budget in breaches:
        lines.append(f"| {sid} | {wall:.1f} | {budget:.1f} | "
                     f"+{wall - budget:.1f} |")
    lines.append("")
    lines.extend(slowest_table(warn_rows))
    if run_url:
        lines.append("")
        lines.append(f"Run: {run_url}")
    lines += [
        "",
        "## The law",
        "",
        "- Budget = expected shard time + 15-20% headroom, pinned in "
        "`scripts/test_shard_budgets.json` (one place, next to the gate).",
        "- It only moves DOWN via optimization PRs "
        "(`check_shard_durations.py --update-budgets` refuses to raise).",
        "- Raising a budget requires a hand-edited reviewed PR with a "
        "written justification.",
        "- This issue closes only when a run fits under the budget again "
        "(the gate's green path closes it).",
        "",
        "Tighten from this run's artifacts: download "
        "`integration-json-shard-*`, run "
        "`python3 scripts/check_shard_durations.py --update-budgets "
        "integration-json-shards/*/integration-shard-*.json` locally, "
        "commit the file in the optimization PR.",
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("json", nargs="+",
                    help="dart test json file-reporter outputs (one per shard)")
    ap.add_argument("--budgets", default=DEFAULT_BUDGETS)
    ap.add_argument(
        "--issue-body",
        help="write the [ENH] issue markdown here when a shard breaches",
    )
    ap.add_argument("--run-url", default="",
                    help="run link embedded in the issue body")
    ap.add_argument(
        "--update-budgets",
        action="store_true",
        help="rewrite the budgets from measured walls. Reviewed-PR-only: "
        "lowers existing entries and adds new ones at measured x 1.2; "
        "refuses to raise. No workflow may call this.",
    )
    args = ap.parse_args()

    measured = {}
    test_rows = {}
    for json_path in args.json:
        result = shard_wall(json_path)
        if result is None:
            write_summary([
                f"RESULT: FAIL — `{json_path}` carries no real test spans "
                "(empty or env-skipped report); a shard that produced no "
                "data cannot pass the budget gate."
            ])
            return 1
        wall, span, rows = result
        measured[shard_id(json_path)] = (wall, span)
        test_rows[shard_id(json_path)] = rows

    if args.update_budgets:
        budgets = load_budgets(args.budgets)
        lowered, added, refused, skipped = [], [], [], []
        for sid in sorted(measured):
            wall = round(measured[sid][0], 1)
            if wall < 0.5:
                skipped.append(sid)
                continue
            old = budgets["shards"].get(sid)
            if old is None:
                padded = round(wall * 1.2, 1)
                budgets["shards"][sid] = padded
                added.append((sid, wall, padded))
            elif wall <= old:
                budgets["shards"][sid] = wall
                lowered.append((sid, old, wall))
            else:
                refused.append((sid, old, wall))
        for sid, old, new in lowered:
            print(f"ratchet down: shard {sid}: {old:.1f} -> {new:.1f} s")
        for sid, wall, padded in added:
            print(f"budgeted (new): shard {sid}: {wall:.1f} s -> {padded:.1f} s")
        for sid in skipped:
            print(f"skipped (sub-second wall — env-skipped shard): {sid}")
        for sid, old, new in refused:
            print(
                f"REFUSED (ratchet is down-only): shard {sid}: {old:.1f} -> "
                f"{new:.1f} s — edit by hand in a reviewed PR if a raise is "
                "truly justified"
            )
        payload = {
            "_meta": {
                **budgets["_meta"],
                "metric": "shard wall = max(testDone)-min(testStart) from the "
                          "dart-json file-reporter (runner span)",
                "law": "down-only via check_shard_durations.py "
                       "--update-budgets; raises require a hand-edited "
                       "reviewed PR; the auto-filed [ENH] issue closes when "
                       "the run fits again",
                "note": "no scheduled workflow writes this file",
            },
            "warn_fraction": budgets["warn_fraction"],
            "shards": dict(sorted(
                budgets["shards"].items(),
                key=lambda kv: (len(kv[0]), kv[0]),
            )),
        }
        with open(args.budgets, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2)
            fh.write("\n")
        print(f"budgets written: {args.budgets}")
        return 1 if refused else 0

    budgets = load_budgets(args.budgets)
    warn_fraction = budgets["warn_fraction"]
    report = [
        "## Shard duration budget (gh-1300)",
        "",
        "| shard | measured wall (s) | span sum (s) | budget (s) | status |",
        "|-------|------------------:|-------------:|-----------:|--------|",
    ]
    failures = []
    breaches = []
    for sid in sorted(measured, key=lambda s: (len(s), s)):
        wall, span = measured[sid]
        budget = budgets["shards"].get(sid)
        if budget is None:
            status = "**FAIL**"
            failures.append(
                f"FAIL: shard `{sid}` ran (wall {wall:.1f} s) but has no "
                "budget — budget it in scripts/test_shard_budgets.json in a "
                "reviewed PR; a new shard cannot sneak past the ratchet."
            )
            breaches.append((sid, wall, float("inf")))
        elif wall > budget:
            status = "**FAIL**"
            failures.append(
                f"FAIL: shard `{sid}` wall {wall:.1f} s > budget {budget:.1f} "
                "s — the leg outgrew expected time + headroom; an "
                "optimization issue is filed (raising the budget requires a "
                "hand-edited reviewed PR)."
            )
            breaches.append((sid, wall, float(budget)))
        elif wall >= budget * warn_fraction:
            status = "WARN"
            report.append(
                f"| {sid} | {wall:.1f} | {span:.1f} | {budget:.1f} | "
                f"WARN (>= {warn_fraction:.0%} of budget) |"
            )
            continue
        else:
            status = "OK"
        report.append(f"| {sid} | {wall:.1f} | {span:.1f} | {budget:.1f} | "
                      f"{status} |")
    for sid in sorted(budgets["shards"], key=lambda s: (len(s), s)):
        if sid not in measured:
            failures.append(
                f"FAIL: budgeted shard `{sid}` did not run — renamed, "
                "re-sharded or dropped from the leg? Restore it, or remove "
                "its budget in a reviewed PR."
            )

    if breaches:
        report.append("")
        all_rows = [r for sid in measured for r in test_rows[sid]]
        report.extend(slowest_table(all_rows))
    if failures:
        report.append("")
        report.extend(failures)
        report.append(
            "RESULT: FAIL (%d budget violation(s)) — a shard outgrew its "
            "budget; optimize (the FA_BIN AOT seam, boot-once+reset) or "
            "shave; the budget does not move up." % len(failures)
        )
        if args.issue_body:
            body_rows = [r for sid in measured for r in test_rows[sid]]
            with open(args.issue_body, "w", encoding="utf-8") as fh:
                fh.write(issue_body(breaches, body_rows, args.run_url))
        write_summary(report)
        return 1
    report.append("")
    report.append(
        f"RESULT: OK — all shards within budget "
        f"(warn band at {warn_fraction:.0%})"
    )
    write_summary(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
