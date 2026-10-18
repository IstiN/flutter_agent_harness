#!/usr/bin/env python3
"""fa results ledger upsert (gh-1682).

`bench/leaderboard/fa_results.json` is the committed ledger of fa's OWN
Terminal-Bench results — the auto-update hook the leaderboard table
overlays on the official rows. It is written by the bench-harbor.yml
aggregate step on every completed run and by hand for backfills.

Usage (explicit fields):

    record.py --dataset-version 2.1 --model kimi-for-coding \
        --resolved 300 --total 445 --date 2026-10-18 \
        --fa-version 2fd100169e \
        --run-url https://github.com/.../actions/runs/3902812716 \
        [--run-url ...]

Usage (machine summary from summary.py --json-summary):

    record.py --summary /tmp/bench-summary.json

Idempotency contract: rows are keyed by (dataset_version, model) — one
aggregate row per dataset x model. Re-recording the same job (same
run_url) updates numbers/dates in place and unions run_urls; it never
appends a duplicate row. The 2.1 kimi row aggregates three workflow
runs (300/445 over runs 3902812716+39052822079+3909896789) exactly this
way.

Every row is self-reported evidence: `self_reported: true` is set by
this tool and the renderer leans on it for the honesty marker — never
blend fa rows into official leaderboard rows (gh-1682 AC2).

Stdlib only.
"""
import argparse
import json
import sys
from pathlib import Path

LEDGER_PATH = Path(__file__).with_name("fa_results.json")


def load_ledger(path: Path = LEDGER_PATH) -> dict:
    if not path.exists():
        return {"schema": 1, "results": []}
    doc = json.loads(path.read_text())
    doc.setdefault("results", [])
    return doc


def save_ledger(doc: dict, path: Path = LEDGER_PATH) -> None:
    path.write_text(json.dumps(doc, indent=2) + "\n")


def _key(row: dict) -> "tuple[str, str]":
    return (row.get("dataset_version", ""), row.get("model", ""))


def upsert(doc: dict, *, dataset_version: str, model: str, resolved: int,
           total: int, date: str, fa_version: str = None,
           run_urls: "list[str]" = ()) -> dict:
    """Insert or update the (dataset_version, model) row. Existing
    run_urls are unioned (sorted, deduped) so a job re-run updates
    instead of duplicating; numbers/date/fa_version reflect the latest
    record call."""
    row = None
    for existing in doc["results"]:
        if _key(existing) == (dataset_version, model):
            row = existing
            break
    if row is None:
        row = {"dataset_version": dataset_version, "model": model}
        doc["results"].append(row)
    urls = set(row.get("run_urls") or [])
    urls.update(u for u in run_urls if u)
    row.update(
        {
            "resolved": int(resolved),
            "total": int(total),
            "date": date,
            "run_urls": sorted(urls),
            # fa rows are self-reported, never official (gh-1682).
            "self_reported": True,
        }
    )
    if fa_version:
        row["fa_version"] = fa_version
    # Stable order: dataset version desc, then accuracy desc (two
    # stable passes — one tuple with reverse=True would flip both keys).
    doc["results"].sort(
        key=lambda r: -(r.get("resolved", 0) / r.get("total", 1) or 0)
    )
    doc["results"].sort(key=lambda r: r.get("dataset_version", ""), reverse=True)
    return row


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", type=Path, default=LEDGER_PATH)
    parser.add_argument("--summary", type=Path, default=None,
                        help="JSON totals from summary.py --json-summary")
    parser.add_argument("--dataset-version", dest="dataset_version")
    parser.add_argument("--model")
    parser.add_argument("--resolved", type=int)
    parser.add_argument("--total", type=int)
    parser.add_argument("--date")
    parser.add_argument("--fa-version", dest="fa_version")
    parser.add_argument("--run-url", dest="run_urls", action="append",
                        default=[])
    args = parser.parse_args(argv)

    if args.summary:
        summary = json.loads(args.summary.read_text())
        fields = {
            "dataset_version": summary.get("family"),
            "model": summary.get("model"),
            "resolved": summary.get("resolved"),
            "total": summary.get("total"),
            "date": summary.get("date"),
            "fa_version": summary.get("fa_ref"),
            "run_urls": [summary.get("run_url")] if summary.get("run_url") else [],
        }
        missing = [k for k, v in fields.items()
                   if v is None and k != "fa_version"]
        if missing:
            print(
                "::error::summary JSON is missing required field(s): "
                + ", ".join(missing),
                file=sys.stderr,
            )
            return 2
    else:
        fields = {
            "dataset_version": args.dataset_version,
            "model": args.model,
            "resolved": args.resolved,
            "total": args.total,
            "date": args.date,
            "fa_version": args.fa_version,
            "run_urls": args.run_urls,
        }
        missing = [k for k in ("dataset_version", "model", "resolved",
                               "total", "date")
                   if fields[k] is None]
        if missing:
            print(
                "error: missing required argument(s): "
                + ", ".join("--" + m.replace("_", "-") for m in missing),
                file=sys.stderr,
            )
            return 2

    doc = load_ledger(args.ledger)
    row = upsert(doc, **fields)
    save_ledger(doc, args.ledger)
    print(json.dumps(row, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
