#!/usr/bin/env python3
"""Fold a healed shard's dart test reporter logs into ONE complete report.

gh-2399 (run 45389186796, tag v1.0.772): the load-drop retry wrapper
(#2331/gh-2381) heals a sharded dart test leg by SIGKILLing the wedged
attempt and re-running the abandoned inventory. The rerun writes its
reporter log to `<retry-log>.rerunK` — "rerun evidence only" — while the
main `<main-log>` stays attempt-1's TRUNCATED stream. The #928
duration-budget gate (pty-coverage-gate) reads the main shard json only,
so suites the rerun ran GREEN phantom-fail "budgeted suite did not run":
the trajectory suites were never absent, their spans were in a log no
consumer read.

This script folds attempt-1 + every surviving rerun log into ONE valid
dart-json stream:

  - spans dedup per (suite path, test name); the LATEST log that recorded
    a span wins, so a re-run file contributes its rerun spans only and
    nothing is double-counted (a partial attempt-1 suite total can never
    inflate the merged one);
  - hidden pseudo-tests (the `loading <path>` loader events) are dropped —
    the same filter junit_from_dart_json.iter_test_spans applies;
  - torn/partial lines (a SIGKILLed stream ends mid-line), missing logs
    and empty logs are tolerated: the fold uses whatever spans survived;
  - a span that FAILED and never reran stays failed in the merged stream —
    a healed shard verdict plus a loud junit record agree.

Output events (start / suite / testStart / testDone / allSuites / done)
carry fresh ids and per-span absolute times, byte-shape-compatible with
every consumer of the original logs (junit_from_dart_json.py,
check_test_durations.py, check_shard_durations.py) — none of them change.
The caller (scripts/load_drop_retry.sh) preserves the raw attempt-1 bytes
beside the merged main log; rerun logs stay untouched.

Usage:
    merge_dart_json_reports.py <merged-out> <primary.json> [rerun.json ...]

Pure stdlib. Exit 0 on success (empty fold included); 2 on usage error.
"""

import json
import os
import sys


def spans_from_log(path):
    """[(suite_path, name, duration_ms, failed)] from one reporter log.

    The canonical dart-json span walk (same parsing rules as
    scripts/junit_from_dart_json.py): paired testStart/testDone, hidden
    pseudo-tests excluded, torn/unparsable lines skipped — never fatal for
    timing data. A missing log folds as empty.
    """
    out = []
    if not os.path.exists(path):
        return out
    suites = {}  # suiteID -> test file path
    starts = {}  # testID -> (name, suite path, start ms)
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            kind = ev.get("type")
            if kind == "suite":
                suites[ev["suite"]["id"]] = ev["suite"].get("path", "")
            elif kind == "testStart":
                starts[ev["test"]["id"]] = (
                    ev["test"].get("name", ""),
                    suites.get(ev["test"].get("suiteID"), ""),
                    ev["time"],
                )
            elif kind == "testDone":
                tid = ev["testID"]
                if tid in starts and not ev.get("hidden", False):
                    name, suite_path, t0 = starts.pop(tid)
                    dur = max(ev["time"] - t0, 0)
                    failed = ev.get("result") in ("failure", "error")
                    out.append((suite_path, name, dur, failed))
    return out


def _compact(obj) -> str:
    """One reporter line — compact separators, byte-faithful to the dart
    file-reporter (`{"suite":{"id":0,...}}`, no spaces)."""
    return json.dumps(obj, separators=(",", ":"))


def write_stream(out_path, folded):
    """Emit the folded spans as one valid dart-json stream (atomic replace)."""
    tmp = out_path + ".tmp"
    suite_paths = sorted({k[0] for k in folded})
    suite_ids = {p: i for i, p in enumerate(suite_paths)}
    any_failed = any(f for (_, f) in folded.values())
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(_compact({
            "protocolVersion": "0.1.1", "type": "start",
            "pid": os.getpid(), "time": 0,
        }) + "\n")
        for p in suite_paths:
            fh.write(_compact({
                "type": "suite",
                "suite": {"id": suite_ids[p], "platform": "vm", "path": p},
                "time": 0,
            }) + "\n")
        test_id = 0
        clock = 0
        for (p, name), (dur, failed) in folded.items():
            test_id += 1
            t0, clock = clock, clock + dur
            fh.write(_compact({
                "type": "testStart",
                "test": {"id": test_id, "name": name,
                         "suiteID": suite_ids[p], "groupIDs": [],
                         "metadata": {"skip": False}},
                "time": t0,
            }) + "\n")
            fh.write(_compact({
                "type": "testDone", "testID": test_id,
                "result": "failure" if failed else "success",
                "hidden": False, "skipped": False, "time": clock,
            }) + "\n")
        fh.write(_compact({
            "type": "allSuites", "count": test_id,
            "success": not any_failed, "time": clock,
        }) + "\n")
        fh.write(_compact({
            "type": "done", "success": not any_failed, "time": clock,
        }) + "\n")
    os.replace(tmp, out_path)


def main() -> int:
    argv = sys.argv[1:]
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out_path, inputs = argv[0], argv[1:]
    folded = {}
    for path in inputs:
        # Latest log wins per (suite path, name): a rerun span supersedes
        # attempt-1's partial/failed record of the same test.
        for suite_path, name, dur, failed in spans_from_log(path):
            folded[(suite_path, name)] = (dur, failed)
    write_stream(out_path, folded)
    print(
        f"merged {len(folded)} test span(s) from "
        f"{len(inputs)} reporter log(s) -> {out_path}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
