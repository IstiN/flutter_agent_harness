#!/usr/bin/env python3
"""PostMortemUsage + ExportGuard tests (issue #1392 AC4/AC7, E4/E6).

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import bench_metrics
import post_mortem_usage as pmu


def _assistant_record(rid, ts, inp, out, model="glm-5.3-flash"):
    return json.dumps(
        {
            "type": "message",
            "id": rid,
            "parentId": None,
            "timestamp": ts,
            "message": {
                "role": "assistant",
                "model": model,
                "usage": {"input": inp, "output": out, "cacheRead": 0, "cacheWrite": 0},
                "content": [{"type": "text", "text": "working"}],
            },
        }
    )


class _Run:
    """A tb run dir: <runs>/<run-id>/<task>/<trial>/ with results.json."""

    def __init__(self, trials):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "tb-runs"
        self.shard = self.root / "shard-0"
        results = []
        for trial in trials:
            trial_dir = self.shard / trial["task_id"] / trial["trial_name"]
            trial_dir.mkdir(parents=True)
            results.append(trial)
        (self.shard / "results.json").write_text(
            json.dumps({"results": results, "run_id": "shard-0"})
        )

    def add_session(self, task, trial, records, layout="agent-logs",
                    name="session-1.jsonl"):
        sessions = self.shard / task / trial / layout / "fah-sessions"
        sessions.mkdir(parents=True, exist_ok=True)
        (sessions / name).write_text("\n".join(records))

    def cleanup(self):
        self.tmp.cleanup()


KILLED_ROW = {
    "task_id": "train-fasttext",
    "trial_name": "train-fasttext-1",
    "is_resolved": False,
    "failure_mode": "agent_timeout",
    "total_input_tokens": 0,
    "total_output_tokens": 0,
}
GRACEFUL_ROW = {
    "task_id": "hello-world",
    "trial_name": "hello-world-1",
    "is_resolved": True,
    "failure_mode": None,
    "total_input_tokens": 500,
    "total_output_tokens": 120,
}


class PostMortemUsageTest(unittest.TestCase):
    def test_killed_trial_gets_session_totals(self):
        # AC4: a trial killed mid-run reports summed tokens > 0 from its
        # session JSONL — the 0/0-on-kill accounting bug dies.
        run = _Run([dict(KILLED_ROW)])
        try:
            run.add_session(
                "train-fasttext",
                "train-fasttext-1",
                [
                    _assistant_record("r1", "2026-01-01T00:00:10Z", 1000, 200),
                    _assistant_record("r2", "2026-01-01T00:01:00Z", 1200, 300),
                ],
            )
            report = pmu.post_mortem(run.root)
            data = json.loads((run.shard / "results.json").read_text())
            row = data["results"][0]
            self.assertEqual(row["total_input_tokens"], 2200)
            self.assertEqual(row["total_output_tokens"], 500)
            self.assertEqual(report["patched"][0]["trial"], "train-fasttext-1")
        finally:
            run.cleanup()

    def test_graceful_row_is_untouched(self):
        # AC4: a graceful trial keeps its live-accounting totals (the
        # post-mortem never rewrites a row that recorded spend).
        run = _Run([dict(GRACEFUL_ROW), dict(KILLED_ROW)])
        try:
            run.add_session(
                "train-fasttext",
                "train-fasttext-1",
                [_assistant_record("r1", "2026-01-01T00:00:10Z", 1000, 200)],
            )
            pmu.post_mortem(run.root)
            row = json.loads((run.shard / "results.json").read_text())["results"][0]
            self.assertEqual(row["total_input_tokens"], 500)
            self.assertEqual(row["total_output_tokens"], 120)
        finally:
            run.cleanup()

    def test_takeover_both_files_summed_without_double_count(self):
        # E6: pre-kill + takeover sessions share record ids (the takeover
        # re-recorded overlapping turns); dedup by record id.
        run = _Run([dict(KILLED_ROW)])
        try:
            run.add_session(
                "train-fasttext",
                "train-fasttext-1",
                [
                    _assistant_record("r1", "2026-01-01T00:00:10Z", 1000, 200),
                    _assistant_record("r2", "2026-01-01T00:01:00Z", 1200, 300),
                ],
                layout="agent-logs",
            )
            run.add_session(
                "train-fasttext",
                "train-fasttext-1",
                [
                    # r1 replayed verbatim (same id) — must not double-count.
                    _assistant_record("r1", "2026-01-01T00:03:00Z", 1000, 200),
                    _assistant_record("r3", "2026-01-01T00:04:00Z", 50, 10),
                ],
                layout="agent-logs",
                name="session-2.jsonl",
            )
            pmu.post_mortem(run.root)
            row = json.loads((run.shard / "results.json").read_text())["results"][0]
            self.assertEqual(row["total_input_tokens"], 2250)
            self.assertEqual(row["total_output_tokens"], 510)
        finally:
            run.cleanup()

    def test_corrupt_session_degrades_to_null_tokens_with_warning(self):
        # E4: missing/corrupt JSONL -> tokens: null + warning, never a crash.
        run = _Run([dict(KILLED_ROW)])
        try:
            sessions = (
                run.shard / "train-fasttext" / "train-fasttext-1"
                / "agent-logs" / "fah-sessions"
            )
            sessions.mkdir(parents=True)
            (sessions / "session-1.jsonl").write_text("{corrupt json\n")
            report = pmu.post_mortem(run.root)
            row = json.loads((run.shard / "results.json").read_text())["results"][0]
            self.assertIsNone(row["total_input_tokens"])
            self.assertIsNone(row["total_output_tokens"])
            self.assertTrue(report["warnings"])
        finally:
            run.cleanup()

    def test_never_started_modes_are_skipped(self):
        run = _Run(
            [
                {
                    "task_id": "x",
                    "trial_name": "x-1",
                    "is_resolved": False,
                    "failure_mode": "unknown_agent_error",
                    "total_input_tokens": 0,
                    "total_output_tokens": 0,
                }
            ]
        )
        try:
            report = pmu.post_mortem(run.root)
            self.assertEqual(report["patched"], [])
            self.assertEqual(report["warnings"], [])
        finally:
            run.cleanup()

    def test_audit_justified_kill_is_no_honesty_violation(self):
        # Round-3 review: the post-mortem AC8 scan must honor the same
        # audit contract as summary.py — an fa-agent-timeout.json whose
        # outcome is a watch-decided kill (stall / hard-ceiling /
        # abs_ceiling) is a legitimate long-gap kill, not a score
        # honesty violation.
        spent = dict(KILLED_ROW, total_input_tokens=400, total_output_tokens=50)
        run = _Run([spent])
        trial_dir = run.shard / "train-fasttext" / "train-fasttext-1"
        (trial_dir / "fa-agent-timeout.json").write_text(
            json.dumps({"outcome": "abs_ceiling", "policy": "progress-watch"})
        )
        try:
            run.add_session(
                "train-fasttext",
                "train-fasttext-1",
                [
                    _assistant_record("r1", "2026-01-01T00:00:10Z", 1000, 200),
                    # 50s gap: SUB-threshold — exactly the legitimate
                    # abs-ceiling kill shape (E2: killed while
                    # progressing) that must NOT read as a violation.
                    _assistant_record("r2", "2026-01-01T00:01:00Z", 1200, 300),
                ],
            )
            report = pmu.post_mortem(run.root)
            self.assertEqual(report["honesty_violations"], [])
        finally:
            run.cleanup()

    def test_unaudited_or_unjustified_subthreshold_still_violates(self):
        # The control (summary.py parity): an agent_timeout row whose
        # session shows only SUB-threshold gaps is the round-2
        # contradiction — with no audit, and with an audit that does NOT
        # name a watch kill, the scan must still fire.
        for audit_outcome in (None, "completed"):
            run = _Run([dict(KILLED_ROW,
                             total_input_tokens=400, total_output_tokens=50)])
            trial_dir = run.shard / "train-fasttext" / "train-fasttext-1"
            if audit_outcome is not None:
                (trial_dir / "fa-agent-timeout.json").write_text(
                    json.dumps({"outcome": audit_outcome})
                )
            try:
                run.add_session(
                    "train-fasttext",
                    "train-fasttext-1",
                    [
                        _assistant_record("r1", "2026-01-01T00:00:10Z", 1000, 200),
                        # 50s gap: sub-threshold (240s) contradiction.
                        _assistant_record("r2", "2026-01-01T00:01:00Z", 1200, 300),
                    ],
                )
                report = pmu.post_mortem(run.root)
                self.assertEqual(len(report["honesty_violations"]), 1,
                                 audit_outcome)
                self.assertEqual(
                    report["honesty_violations"][0]["trial"], "train-fasttext-1"
                )
            finally:
                run.cleanup()



class ExportGuardTest(unittest.TestCase):
    def test_sabotaged_export_names_the_trial(self):
        # AC7: a trial with a session but an empty export produces a loud
        # warning row naming the trial.
        run = _Run([dict(KILLED_ROW)])
        try:
            # The adapter's export-guard record: 3 session records existed,
            # the export produced 0 files.
            guard_dir = run.shard / "train-fasttext" / "train-fasttext-1"
            (guard_dir / "export-guard.json").write_text(
                json.dumps({"trial": "train-fasttext-1", "session_records": 3,
                            "export_files": 0, "ok": False})
            )
            report = pmu.post_mortem(run.root)
            self.assertEqual(
                report["export_gaps"],
                [{"trial": "train-fasttext-1", "session_records": 3,
                  "export_files": 0}],
            )
        finally:
            run.cleanup()

    def test_healthy_guard_produces_no_gap(self):
        run = _Run([dict(GRACEFUL_ROW)])
        try:
            guard_dir = run.shard / "hello-world" / "hello-world-1"
            (guard_dir / "export-guard.json").write_text(
                json.dumps({"trial": "hello-world-1", "session_records": 12,
                            "export_files": 12, "ok": True})
            )
            report = pmu.post_mortem(run.root)
            self.assertEqual(report["export_gaps"], [])
        finally:
            run.cleanup()


class LatencyAggregationTest(unittest.TestCase):
    def test_run_report_latency_per_run_id(self):
        # AC2: the run report aggregates p50/p95 per shard (one concurrency
        # level per run; the report tags the level).
        run = _Run([dict(GRACEFUL_ROW), dict(KILLED_ROW)])
        try:
            bench_metrics.write_bench_metrics(
                run.shard / "hello-world" / "hello-world-1" / "bench_metrics.json",
                {
                    "trial": "hello-world-1",
                    "concurrency_level": 2,
                    "requests": [],
                    "latency": {"first_byte": {"p50": 10.0, "p95": 20.0,
                                               "max": 20.0, "n": 4}},
                    "watchdog_events": [],
                },
            )
            bench_metrics.write_bench_metrics(
                run.shard / "train-fasttext" / "train-fasttext-1"
                / "bench_metrics.json",
                {
                    "trial": "train-fasttext-1",
                    "concurrency_level": 2,
                    "requests": [],
                    "latency": {"first_byte": {"p50": 30.0, "p95": 60.0,
                                               "max": 60.0, "n": 2}},
                    "watchdog_events": [{"event": "idle_watchdog_fired"}],
                },
            )
            report = pmu.aggregate_latency(run.root)
            self.assertEqual(len(report), 1)
            shard = report[0]
            self.assertEqual(shard["run_id"], "shard-0")
            self.assertEqual(shard["concurrency_level"], 2)
            # Pooled across the shard's two trials: percentile over the
            # per-trial figures ([10, 30] -> 10; [20, 60] -> 60 at p95).
            self.assertEqual(shard["latency"]["first_byte"]["p50"], 10.0)
            self.assertEqual(shard["latency"]["first_byte"]["p95"], 60.0)
            self.assertEqual(shard["latency"]["first_byte"]["n"], 6)
            self.assertEqual(shard["watchdog_events"], 1)
        finally:
            run.cleanup()


if __name__ == "__main__":
    unittest.main()
