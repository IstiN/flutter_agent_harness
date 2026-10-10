#!/usr/bin/env python3
"""Issue #1392 round-3 summary contract: coverage-not-red (AC6), latency
p50/p95 per concurrency level (AC2), concurrency tag, and the AC8
score-honesty scan (an agent_timeout whose session shows steady <240s
gaps is a contradiction, never silent).

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "summary_r3", Path(__file__).resolve().parent / "summary.py"
)
summary = importlib.util.module_from_spec(spec)
sys.modules["summary_r3"] = summary
spec.loader.exec_module(summary)

import bench_metrics
from bench_metrics import summarize_trial


def _results(run_dir, rows):
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "results.json").write_text(json.dumps({"results": rows}))


def _row(task, name, resolved=None, mode="agent_timeout"):
    return {
        "task_id": task,
        "trial_name": name,
        "is_resolved": resolved,
        "failure_mode": mode,
        "total_input_tokens": 0,
        "total_output_tokens": 0,
    }


def _session(run_dir, task, trial, gaps):
    """Write one assistant session whose inter-record gaps are `gaps`."""
    sessions = run_dir / "shard-0" / task / trial / "agent-logs" / "fah-sessions"
    sessions.mkdir(parents=True)
    lines = []
    t = 0
    for gap in gaps:
        t += gap
        stamp = f"2026-02-13T12:{t // 60:02d}:{t % 60:02d}Z"
        lines.append(
            json.dumps(
                {"message": {"role": "assistant"}, "timestamp": stamp}
            )
        )
    (sessions / "session.jsonl").write_text("\n".join(lines) + "\n")


class CoverageNotRedTest(unittest.TestCase):
    """AC6: a cancelled shard degrades to a coverage note, not a failure."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.runs = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_missing_tasks_are_a_coverage_line_not_a_problem(self):
        _results(self.runs / "shard-0", [_row("t1", "t1__trial")])
        lines, problems = summary.render(self.runs, expected=8)
        self.assertTrue(
            any("coverage: 1/8" in line for line in lines), lines
        )
        self.assertFalse(
            any("expected tasks" in p for p in problems), problems
        )

    def test_full_coverage_has_no_coverage_note(self):
        _results(self.runs / "shard-0", [_row("t1", "t1__trial")])
        lines, problems = summary.render(self.runs, expected=1)
        self.assertFalse(any("coverage:" in line for line in lines), lines)
        self.assertEqual(problems, [])

    def test_zero_results_still_a_problem(self):
        lines, problems = summary.render(self.runs, expected=8)
        self.assertTrue(problems)


class LatencyReportTest(unittest.TestCase):
    """AC2: the run report carries p50/p95 per concurrency level."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.runs = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def _trial_metrics(self, task, trial, level, first_bytes):
        trial_dir = self.runs / "shard-0" / task / trial
        trial_dir.mkdir(parents=True)
        # The EXACT shape bench_metrics.summarize_trial writes (the writer
        # the adapter calls); a fixture that invents keys would pass while
        # the real report stays empty.
        (trial_dir / "bench_metrics.json").write_text(
            json.dumps(
                summarize_trial(
                    trial,
                    [
                        {
                            "event": "first_byte",
                            "seq": i + 1,
                            "wallSec": fb,
                            "fresh": i % 2 == 0,
                            "localPort": 40000 + i,
                            "poolSize": 2,
                        }
                        for i, fb in enumerate(first_bytes)
                    ],
                    concurrency_level=level,
                )
            )
        )

    def test_p50_p95_per_concurrency_level(self):
        _results(self.runs / "shard-0", [_row("t1", "t1__t", mode="unset")])
        _results(self.runs / "shard-1", [_row("t2", "t2__t", mode="unset")])
        self._trial_metrics("t1", "t1__t", 2, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        self._trial_metrics("t2", "t2__t", 1, [100, 200, 300, 400])
        lines, _ = summary.render(self.runs)
        block = "\n".join(lines)
        self.assertIn("Request latency by concurrency level", block)
        self.assertIn("concurrency 2", block)
        self.assertIn("concurrency 1", block)
        # Nearest-rank percentiles (bench_metrics.percentile — the same
        # implementation the writer uses): p50 of 1..10 = 5.0, p95 = 10.0;
        # p50 of 100..400 = 200.0, p95 = 400.0.
        self.assertIn("first-byte p50=5.0s", block)
        self.assertIn("p95=10.0s", block)
        self.assertIn("first-byte p50=200.0s", block)

    def test_no_metrics_no_block(self):
        _results(self.runs / "shard-0", [_row("t1", "t1__t", mode="unset")])
        lines, _ = summary.render(self.runs)
        self.assertFalse(
            any("latency by concurrency" in line for line in lines), lines
        )


class ConcurrencyTagTest(unittest.TestCase):
    """AC5/AC2: the report tags the run's concurrency level."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.runs = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        _results(self.runs / "shard-0", [_row("t1", "t1__t", mode="unset")])

    def test_render_tags_concurrency(self):
        lines, _ = summary.render(self.runs, concurrency=2)
        self.assertTrue(any("concurrency 2" in line for line in lines[:3]))

    def test_main_reads_env_tag(self):
        import os
        from unittest import mock

        with mock.patch.dict(
            os.environ, {"BENCH_CONCURRENCY": "1"}
        ), mock.patch.object(
            summary.sys, "argv", ["summary.py", "--no-fail", str(self.runs)]
        ):
            code = None
            try:
                summary.main()
            except SystemExit as exc:
                code = exc.code
            self.assertEqual(code, 0)


class ScoreHonestyTest(unittest.TestCase):
    """AC8: an agent_timeout whose gaps are all <240s is a contradiction."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.runs = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_steady_gap_kill_is_a_contradiction(self):
        _results(
            self.runs / "shard-0",
            [_row("t1", "t1__trial", mode="agent_timeout")],
        )
        _session(self.runs, "t1", "t1__trial", [60, 120, 90])
        lines, problems = summary.render(self.runs)
        self.assertTrue(
            any("score honesty" in line and "1" in line for line in lines),
            lines,
        )
        self.assertTrue(
            any("t1__trial" in p for p in problems), problems
        )

    def test_stalled_kill_is_justified(self):
        # gh-1430: the shipped stall gap is 360s, so a kill whose session
        # gap reached it (400s) is the watch's own justified verdict —
        # never a contradiction. (fa's own watchdog errors a dead stream
        # at 300s, so post-fix kills land at 360s+ gaps or with an audit.)
        _results(
            self.runs / "shard-0",
            [_row("t1", "t1__trial", mode="agent_timeout")],
        )
        _session(self.runs, "t1", "t1__trial", [60, 400, 60])
        lines, problems = summary.render(self.runs)
        self.assertFalse(
            any("contradiction" in line and "1" in line for line in lines),
            lines,
        )
        self.assertEqual(problems, [])

    def test_audit_outcome_justifies_the_kill(self):
        # Round-3 audits: a stall/ceiling kill carries its reason; only a
        # missing or contradicting audit trips the honesty scan.
        _results(
            self.runs / "shard-0",
            [_row("t1", "t1__trial", mode="agent_timeout")],
        )
        _session(self.runs, "t1", "t1__trial", [60, 90])
        trial_dir = self.runs / "shard-0" / "t1" / "t1__trial"
        (trial_dir / "fa-agent-timeout.json").write_text(
            json.dumps({"outcome": "abs_ceiling"})
        )
        _, problems = summary.render(self.runs)
        self.assertEqual(problems, [])

    def test_missing_session_data_degrades_silently(self):
        # E4: no session logs at all -> no crash, no contradiction claim.
        _results(
            self.runs / "shard-0",
            [_row("t1", "t1__trial", mode="agent_timeout")],
        )
        lines, problems = summary.render(self.runs)
        self.assertEqual(problems, [])
        self.assertTrue(any("score honesty" in line for line in lines))


class ProviderLabelTest(unittest.TestCase):
    """gh-1471 D5: the report header names the provider+model (the
    BENCH_RUN_LABEL env from bench.yml's resolve step) so glm and kimi
    runs never blend in the ledger/cost views."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.runs = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        _results(self.runs / "shard-0", [_row("t1", "t1__t", mode="unset")])

    def test_render_tags_the_provider_label(self):
        lines, _ = summary.render(
            self.runs, run_label="kimi-for-coding (k3-256k)"
        )
        self.assertEqual(
            lines[2], "Provider: kimi-for-coding (k3-256k) (gh-1471)."
        )

    def test_no_label_keeps_the_header_stock(self):
        # Legacy callers/replays (and every existing golden) see the
        # byte-identical header when the tag is absent.
        lines, _ = summary.render(self.runs)
        self.assertEqual(lines[0], "### fa on terminal-bench")
        self.assertFalse(any("Provider:" in line for line in lines))

    def test_main_reads_env_label(self):
        import os
        from unittest import mock

        with mock.patch.dict(
            os.environ, {"BENCH_RUN_LABEL": "zai glm (glm-5.3-flash)"}
        ), mock.patch.object(
            summary.sys, "argv", ["summary.py", "--no-fail", str(self.runs)]
        ):
            code = None
            try:
                summary.main()
            except SystemExit as exc:
                code = exc.code
            self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
