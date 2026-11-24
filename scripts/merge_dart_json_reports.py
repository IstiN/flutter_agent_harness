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
  - each attempt keeps its internal relative clock and is offset by the
    accumulated wall of attempts 1..k-1: the merged stream's wall
    (max testDone - min testStart — what check_shard_durations.py's
    gh-1300 shard budget measures) is the SUM of the attempt walls, never
    the span sum the synthetic sequential clock of the first draft
    produced;
  - hidden pseudo-tests (the `loading <path>` loader events) are dropped —
    the shared walk junit_from_dart_json.iter_test_events applies the
    same filter (one parser for junit, the #928 budgets and this fold —
    no drift);
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

from junit_from_dart_json import iter_test_events


def spans_from_log(path):
    """([(suite_path, name, start_ms, end_ms, failed)], wall_ms) per log.

    Parsing comes from the SHARED dart-json walk
    (junit_from_dart_json.iter_test_events) — paired testStart/testDone,
    hidden pseudo-tests excluded, torn/unparsable lines skipped, never
    fatal for timing data; a missing log folds as empty.

    Times are normalized to the log's OWN relative clock (its earliest
    real testStart becomes 0), so wall_ms = max(end) - min(start) is
    exactly the quantity scripts/check_shard_durations.py measures over
    the artifact.
    """
    if not os.path.exists(path):
        return [], 0
    spans = []
    t_min = None
    t_max = 0
    for suite_path, name, t0, t1, failed in iter_test_events(path):
        if t_min is None or t0 < t_min:
            t_min = t0
        if t1 > t_max:
            t_max = t1
        spans.append((suite_path, name, t0, t1, failed))
    if not spans:
        return [], 0
    spans = [(p, n, t0 - t_min, t1 - t_min, f) for p, n, t0, t1, f in spans]
    return spans, t_max - t_min


def _compact(obj) -> str:
    """One reporter line — compact separators, byte-faithful to the dart
    file-reporter (`{"suite":{"id":0,...}}`, no spaces)."""
    return json.dumps(obj, separators=(",", ":"))


def write_stream(out_path, folded):
    """Emit the folded spans as one valid dart-json stream (atomic replace).

    Each span carries its absolute merged-clock time assigned in main()
    (its attempt's relative clock offset by the accumulated wall of the
    preceding attempts) — so the merged stream's wall (max testDone minus
    min testStart, the metric check_shard_durations.py reads) equals the
    SUM of the attempt walls, never the span sum.
    """
    tmp = out_path + ".tmp"
    suite_paths = sorted({k[0] for k in folded})
    suite_ids = {p: i for i, p in enumerate(suite_paths)}
    any_failed = any(f for (_, _, f) in folded.values())
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
        for (p, name), (t0, t1, failed) in folded.items():
            test_id += 1
            clock = max(clock, t1)
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
                "hidden": False, "skipped": False, "time": t1,
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
    offset = 0  # accumulated wall of the attempts folded so far (ms)
    for path in inputs:
        # Latest log wins per (suite path, name): a rerun span supersedes
        # attempt-1's partial/failed record of the same test. Each attempt
        # keeps its internal relative clock and is offset by the
        # accumulated wall of attempts 1..k-1 — the merged wall is the SUM
        # of the attempt walls (what the gh-1300 shard gate and the PR
        # description promise), never the span sum.
        spans, wall = spans_from_log(path)
        for suite_path, name, t0, t1, failed in spans:
            folded[(suite_path, name)] = (offset + t0, offset + t1, failed)
        offset += wall
    write_stream(out_path, folded)
    print(
        f"merged {len(folded)} test span(s) from "
        f"{len(inputs)} reporter log(s) -> {out_path}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
