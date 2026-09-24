#!/usr/bin/env python3
"""Test-duration budget gate for the CI integration legs (issue #928).

Mirror of the coverage ratchet (check_cli_coverage.py), but time may only
go DOWN. Consumes the dart test JSON file-reporter output the CI legs
already emit (`--file-reporter="json:..."`, one file per shard) and checks
two budgets against the committed baseline (test_duration_baseline.json):

  1. per-test:  a single test exceeds its named budget;
  2. per-suite: a suite's TOTAL (sum of its tests' spans — parallelism
     independent, so sharding/concurrency changes don't move it) regresses
     more than TOLERANCE above the baseline.

Suites that ran but have no baseline entry are UNBUDGETED: reported into
the summary (visibility first), never failing — the first keyed CI run is
what gives live-provider (llm) suites real numbers, and a reviewed PR
budgets them afterwards.

Baseline shape (scripts/test_duration_baseline.json):

    {
      "_meta":    {"...": "..."},
      "suites":   {"test/integration/foo_test.dart": 152.3},
      "per_test": {"test/integration/foo_test.dart": {"slow case": 60.0}}
    }

The ratchet is structural: budgets change ONLY through reviewed PRs, and
--update-baseline refuses to RAISE an existing suite entry (it can add new
suites and lower existing ones). NO workflow — scheduled or otherwise —
may invoke --update-baseline; the weekly shard-rebalance and coverage
gardener never touch this file. `junit-shard` artifacts are the measured
data a tightening PR consumes.

Usage:
  check_test_durations.py [--baseline PATH] [--update-baseline] JSON [JSON ...]
  # JSON: one or more dart test json file-reporter outputs (all shards).

Exit 1 on any budget failure; the GitHub job summary gets the top-10
slowest tests on every run. Pure stdlib.
"""

import argparse
import json
import os
import sys

TOLERANCE = 0.10  # suite total may regress up to 10% vs baseline before failing
TOP_N = 10


def parse_tests(json_paths):
    """Yield (suite_path, test_name, duration_seconds) from dart json events.

    Same span logic as junit_from_dart_json.py: paired testStart/testDone,
    hidden pseudo-tests (e.g. "loading <file>") excluded, torn lines skipped.
    """
    for json_path in json_paths:
        suites = {}  # suiteID -> path
        starts = {}  # testID -> (name, suite path, start ms)
        with open(json_path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue  # torn/partial line — never fatal for timing
                kind = ev.get("type")
                if kind == "suite":
                    suites[ev["suite"]["id"]] = ev["suite"].get("path", "")
                elif kind == "testStart":
                    starts[ev["test"]["id"]] = (
                        ev["test"].get("name", ""),
                        suites.get(ev["test"]["suiteID"], ""),
                        ev["time"],
                    )
                elif kind == "testDone":
                    tid = ev["testID"]
                    if tid in starts and not ev.get("hidden", False):
                        name, path, t0 = starts.pop(tid)
                        yield path, name, max((ev["time"] - t0) / 1000.0, 0.0)


def summarize(json_paths):
    """-> (suite_totals {path: s}, test_rows [(suite, name, s)])."""
    suite_totals = {}
    test_rows = []
    for path, name, dur in parse_tests(json_paths):
        suite_totals[path] = suite_totals.get(path, 0.0) + dur
        test_rows.append((path, name, dur))
    return suite_totals, test_rows


def load_baseline(path):
    if not os.path.exists(path):
        return {"suites": {}, "per_test": {}}
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    return {
        "suites": data.get("suites", {}),
        "per_test": data.get("per_test", {}),
    }


def top10_markdown(test_rows):
    lines = [
        "## Test duration budget (issue #928)",
        "",
        f"Top {TOP_N} slowest tests:",
        "",
        "| # | time (s) | suite | test |",
        "|---|---------:|-------|------|",
    ]
    ranked = sorted(test_rows, key=lambda r: (-r[2], r[0], r[1]))[:TOP_N]
    for i, (path, name, dur) in enumerate(ranked, 1):
        lines.append(f"| {i} | {dur:.1f} | `{path}` | {name} |")
    return lines


def write_summary(lines):
    block = "\n".join(lines) + "\n"
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if target:
        with open(target, "a", encoding="utf-8") as fh:
            fh.write(block)
    print(block, end="")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("json", nargs="+", help="dart test json file-reporter outputs")
    ap.add_argument("--baseline",
                    default=os.path.join(os.path.dirname(__file__),
                                         "test_duration_baseline.json"))
    ap.add_argument(
        "--update-baseline",
        action="store_true",
        help="rewrite the baseline from measured data. Reviewed-PR-only: "
        "refuses to raise existing suite entries (down-only ratchet); "
        "no workflow may call this.",
    )
    ap.add_argument(
        "--headroom",
        type=float,
        default=0.0,
        help="with --update-baseline: pad NEWLY budgeted suites by this "
        "fraction (0.2 = +20%% headroom, the issue #928 seed policy); "
        "lowered entries use the exact measured value",
    )
    args = ap.parse_args()

    suite_totals, test_rows = summarize(args.json)
    report = top10_markdown(test_rows)
    report.append("")
    report.append(
        f"Suites measured: {len(suite_totals)} "
        f"(total {sum(suite_totals.values()):.1f} s across "
        f"{len(test_rows)} tests)"
    )

    failures = []
    unbudgeted = []
    if args.update_baseline:
        baseline = load_baseline(args.baseline)
        lowered, added, refused, skipped_env = [], [], [], []
        for path in sorted(suite_totals):
            measured = round(suite_totals[path], 1)
            # A sub-second suite total is a silent env-skip (tests that
            # early-return without the skipped flag on a no-key/no-display
            # box), not a measurement — budgeting it would poison the
            # down-only ratchet with a 0.0s floor. Leave unbudgeted.
            if measured < 0.5:
                skipped_env.append(path)
                continue
            if path in baseline["suites"]:
                if measured <= baseline["suites"][path]:
                    lowered.append((path, baseline["suites"][path], measured))
                    baseline["suites"][path] = measured
                else:
                    refused.append(
                        (path, baseline["suites"][path], measured)
                    )
            else:
                padded = round(measured * (1 + args.headroom), 1)
                added.append((path, padded))
                baseline["suites"][path] = padded
        for path, old, new in lowered:
            report.append(f"ratchet down: {path}: {old:.1f} -> {new:.1f} s")
        for path, secs in added:
            report.append(f"budgeted (new): {path}: {secs:.1f} s")
        for path in skipped_env:
            report.append(
                f"skipped (sub-second run — env-skipped locally, left "
                f"unbudgeted): {path}"
            )
        for path, old, new in refused:
            report.append(
                f"REFUSED (ratchet is down-only): {path}: "
                f"{old:.1f} -> {new:.1f} s — edit by hand in a reviewed PR "
                "if a raise is truly justified"
            )
        meta = {
            "metric": "suite total = sum of per-test spans (dart test json reporter)",
            "ratchet": "down-only via check_test_durations.py --update-baseline; "
            "raises require a hand-edited reviewed PR",
            "note": "no scheduled workflow writes this file",
        }
        existing_meta = {}
        if os.path.exists(args.baseline):
            with open(args.baseline, encoding="utf-8") as fh:
                existing_meta = json.load(fh).get("_meta", {})
        payload = {
            "_meta": {**existing_meta, **meta},
            "suites": dict(sorted(baseline["suites"].items())),
            "per_test": dict(
                sorted(
                    (p, dict(sorted(t.items())))
                    for p, t in baseline["per_test"].items()
                )
            ),
        }
        with open(args.baseline, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2)
            fh.write("\n")
        report.append(f"baseline written: {args.baseline}")
        write_summary(report)
        return 1 if refused else 0

    baseline = load_baseline(args.baseline)
    for path, name, dur in test_rows:
        budget = baseline["per_test"].get(path, {}).get(name)
        if budget is not None and dur > budget + 1e-9:
            failures.append(
                f"FAIL: per-test budget: `{name}` ({path}) took {dur:.1f} s, "
                f"budget {budget:.1f} s"
            )
    for path in sorted(suite_totals):
        measured = suite_totals[path]
        budget = baseline["suites"].get(path)
        if budget is None:
            unbudgeted.append(f"  `{path}` ({measured:.1f} s)")
        elif measured > budget * (1 + TOLERANCE) + 1e-9:
            failures.append(
                f"FAIL: suite total: `{path}` took {measured:.1f} s, "
                f"budget {budget:.1f} s (+{TOLERANCE:.0%} tolerance) — "
                "shave or re-shard the suite; the baseline only tightens "
                "via a reviewed PR"
            )
    if unbudgeted:
        report.append(
            f"Unbudgeted suites ({len(unbudgeted)} — measured, not gated "
            "yet; budget them from this run's junit artifact in a reviewed PR):"
        )
        report.extend(unbudgeted)
    report.append("")
    report.extend(failures)
    if failures:
        report.append(
            f"RESULT: FAIL ({len(failures)} budget violation(s)) — "
            "a slow test landed; fix it, the budget does not move up."
        )
        write_summary(report)
        return 1
    report.append(
        f"RESULT: OK — all budgeted suites within {TOLERANCE:.0%} of baseline"
    )
    write_summary(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
