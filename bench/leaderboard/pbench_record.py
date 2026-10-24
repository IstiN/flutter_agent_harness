#!/usr/bin/env python3
"""ProgramBench results ledger upsert (gh-182).

`bench/leaderboard/pbench_results.json` is the committed ledger of fa's
OWN ProgramBench results — per-instance score/tests, cost, calls,
provider/model, run id + artifact links, and the smoke|lite|full mode —
the `fa_results.json` pattern applied to bench-programbench.yml. It is
written by the bench-programbench.yml aggregate step on every GREEN run
(summary verdict + Tier-0 `submit verify` passed) and by hand for
backfills — always through this tool: a hand-written JSON row is how the
first seed went wrong (gh-182 review), publishing numbers the tool cannot
produce from any packaged `_stats/`.

Usage:

    pbench_record.py --stats-dir pbench-run/<RUN_ID>/_stats \
        --taskset-ref 895f65916bc5 --pbench-version 1.2.5 \
        --model kimi-for-coding --mode smoke --total 201 \
        [--fa-version 2fd100169e] [--date 2026-10-24] \
        [--run-url https://github.com/.../actions/runs/40072410719]... \
        [--artifact "programbench-submission=<url>"]...

`--stats-dir` is the merged run dir's `_stats/` written by `programbench
submit package` + summary.py: score.json (the per-instance
{branch/test: bool} map), cost.json + calls.json (self-reported, from
the fa session logs). Score pct = share of that instance's scored tests
that passed; solved = every scored test true (summary.py's ✅
convention).

Idempotency contract: rows are keyed by (taskset_ref, model, mode) —
one row per task-set pin x model x mode. Re-recording the same job
updates numbers/dates in place and unions run_urls / artifact_urls
(same label -> URL updated); it never appends a duplicate row. A mode
change (smoke -> full) is a NEW row: the smoke proof (attempted << the
official total) must survive next to the headline run, never be
overwritten by it. Renders (pbench_render.py) sort full runs first and
label smoke rows as pipeline proofs — a smoke result is never presented
as a leaderboard headline.

Every row is self-reported evidence: `self_reported: true` is set by
this tool. Nothing here writes the official ProgramBench registry —
submission stays a manual self-serve PR decision by the owner
(docs/bench.md).

Stdlib only.
"""
import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

LEDGER_PATH = Path(__file__).with_name("pbench_results.json")

# The closed dispatch-mode set — tasks.py's `_select` outputs (the
# workflow's setup `mode` output). Unknown modes fail here instead of
# rendering as an unlabeled row.
MODES = ("smoke", "lite", "globs", "full")


def load_ledger(path: Path = LEDGER_PATH) -> dict:
    if not path.exists():
        return {"schema": 1, "results": []}
    doc = json.loads(path.read_text())
    doc.setdefault("results", [])
    return doc


def save_ledger(doc: dict, path: Path = LEDGER_PATH) -> None:
    path.write_text(json.dumps(doc, indent=2) + "\n")


def _key(row: dict) -> "tuple[str, str, str]":
    return (row.get("taskset_ref", ""), row.get("model", ""),
            row.get("mode", ""))


def read_stats(stats_dir: Path) -> dict:
    """Per-instance entries from the packaged `_stats/` maps.

    score.json is the required input (a green aggregate always has it —
    the verdict gate fails the run before record is reached otherwise);
    cost.json/calls.json entries ride along when present. An instance
    known only from cost/calls still lands with no score fields — a gap
    must render as "no score", never silently disappear.
    """
    score_path = stats_dir / "score.json"
    score = json.loads(score_path.read_text()) if score_path.is_file() else None
    if score is None:
        raise FileNotFoundError(f"no score.json under {stats_dir} — "
                                "record runs only after `programbench "
                                "submit package`")
    # gh-182 review round 2: a JSON list passes the `is None` check —
    # `[]` would silently record an empty "result" row, a non-empty
    # list would die on .get outside main's (OSError, ValueError)
    # catch. Same robustness class as the cost/calls guards below.
    if not isinstance(score, dict):
        raise ValueError(f"score.json must be an object — got "
                         f"{type(score).__name__}")
    costs = json.loads((stats_dir / "cost.json").read_text()) \
        if (stats_dir / "cost.json").is_file() else {}
    calls = json.loads((stats_dir / "calls.json").read_text()) \
        if (stats_dir / "calls.json").is_file() else {}

    instances: dict = {}
    for iid in sorted(set(score) | set(costs) | set(calls)):
        entry: dict = {}
        tests = score.get(iid)
        if isinstance(tests, dict) and tests:
            passed = sum(1 for v in tests.values() if v is True)
            entry["score_pct"] = round(100.0 * passed / len(tests), 1)
            entry["tests"] = len(tests)
            entry["solved"] = passed == len(tests)
        # gh-182 review: hand-backfilled maps can carry nulls/strings —
        # a malformed entry degrades to "no field" (rendered n/a), the
        # tool must not die on a TypeError mid-record.
        if iid in costs and isinstance(costs[iid], (int, float)):
            entry["cost_usd"] = round(float(costs[iid]), 4)
        if iid in calls and isinstance(calls[iid], int):
            entry["calls"] = int(calls[iid])
        instances[iid] = entry
    return instances


def upsert(doc: dict, *, taskset_ref: str, model: str, mode: str, total: int,
           instances: dict = None, date: str = None,
           pbench_version: str = None, fa_version: str = None,
           run_urls: "list[str]" = (),
           artifacts: "list[dict]" = ()) -> dict:
    """Insert or update the (taskset_ref, model, mode) row.

    Existing run_urls are unioned (sorted, deduped) and artifact_urls
    merged by label so a job re-run updates instead of duplicating;
    numbers/date reflect the latest record call. `instances=None`
    keeps the row's existing per-instance data (a URL-only touch-up).
    """
    if mode not in MODES:
        raise ValueError(f"unknown mode {mode!r} — expected one of "
                         f"{', '.join(MODES)} (tasks.py's output set)")
    row = None
    for existing in doc["results"]:
        if _key(existing) == (taskset_ref, model, mode):
            row = existing
            break
    if row is None:
        row = {"taskset_ref": taskset_ref, "model": model, "mode": mode}
        doc["results"].append(row)
    if instances is None:
        instances = row.get("instances") or {}

    urls = set(row.get("run_urls") or [])
    urls.update(u for u in run_urls if u)
    by_label = {a["label"]: a["url"] for a in row.get("artifact_urls") or []}
    for a in artifacts or ():
        if a.get("label") and a.get("url"):
            by_label[a["label"]] = a["url"]

    scores = [e["score_pct"] for e in instances.values()
              if isinstance(e.get("score_pct"), (int, float))]
    costs = [e["cost_usd"] for e in instances.values()
             if isinstance(e.get("cost_usd"), (int, float))]
    calls = [e["calls"] for e in instances.values()
             if isinstance(e.get("calls"), int)]

    row.update(
        {
            "date": date or datetime.now(timezone.utc).date().isoformat(),
            "total": int(total),
            "attempted": len(instances),
            "solved": sum(1 for e in instances.values()
                          if e.get("solved") is True),
            "instances": dict(sorted(instances.items())),
            "run_urls": sorted(urls),
            "artifact_urls": [{"label": k, "url": by_label[k]}
                              for k in sorted(by_label)],
            # fa rows are self-reported, never official (gh-182 R4).
            "self_reported": True,
        }
    )
    row["score_pct"] = round(sum(scores) / len(scores), 1) if scores else None
    row["cost_usd"] = round(sum(costs), 4) if costs else None
    row["calls"] = sum(calls) if calls else None
    if pbench_version:
        row["pbench_version"] = pbench_version
    if fa_version:
        row["fa_version"] = fa_version
    # Stable order: task-set pin, then model, then mode — deterministic
    # for merges; the renderer applies its own presentation order.
    doc["results"].sort(key=_key)
    return row


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", type=Path, default=LEDGER_PATH)
    parser.add_argument("--stats-dir", type=Path, required=True,
                        help="merged run dir's _stats/ (score/cost/calls)")
    parser.add_argument("--taskset-ref", dest="taskset_ref", required=True,
                        help="facebookresearch/ProgramBench pin (short sha)")
    parser.add_argument("--pbench-version", dest="pbench_version",
                        help="PyPI programbench pin the run evaluated with")
    parser.add_argument("--model", required=True,
                        help="provider model id (the resolved bench_model)")
    parser.add_argument("--mode", required=True,
                        help="dispatch mode from tasks.py (smoke/lite/"
                             "globs/full)")
    parser.add_argument("--total", type=int, required=True,
                        help="FULL official instance count (the dilution "
                             "denominator; tasks.py's `total` output)")
    parser.add_argument("--date",
                        help="run date YYYY-MM-DD (default: today UTC)")
    parser.add_argument("--fa-version", dest="fa_version",
                        help="fa ref the run executed")
    parser.add_argument("--run-url", dest="run_urls", action="append",
                        default=[])
    parser.add_argument("--artifact", dest="artifacts", action="append",
                        default=[], metavar="LABEL=URL",
                        help="analysis-artifact link (repeatable)")
    args = parser.parse_args(argv)

    if args.mode not in MODES:
        print(f"error: --mode must be one of {', '.join(MODES)} — "
              f"got: {args.mode!r}", file=sys.stderr)
        return 2
    artifacts = []
    for spec in args.artifacts:
        label, sep, url = spec.partition("=")
        if not sep or not label.strip() or not url.strip():
            print("error: --artifact must be LABEL=URL — got: "
                  f"{spec!r}", file=sys.stderr)
            return 2
        artifacts.append({"label": label.strip(), "url": url.strip()})
    if args.total < 0:
        print("error: --total must be >= 0", file=sys.stderr)
        return 2

    try:
        instances = read_stats(args.stats_dir)
    except (OSError, ValueError) as exc:
        print(f"error: --stats-dir {args.stats_dir}: {exc}",
              file=sys.stderr)
        return 2

    doc = load_ledger(args.ledger)
    row = upsert(doc, taskset_ref=args.taskset_ref, model=args.model,
                 mode=args.mode, total=args.total, instances=instances,
                 date=args.date, pbench_version=args.pbench_version,
                 fa_version=args.fa_version, run_urls=args.run_urls,
                 artifacts=artifacts)
    save_ledger(doc, args.ledger)
    print(json.dumps(row, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
