#!/usr/bin/env python3
"""UT-3 for issue #1123: legacy summary cost column + totals aggregation.

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

_BENCH = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location(
    "summary_legacy", Path(__file__).resolve().parent / "summary.py"
)
summary = importlib.util.module_from_spec(spec)
sys.modules["summary_legacy"] = summary
spec.loader.exec_module(summary)


def trial(task, name, resolved, tin, tout):
    return {
        "task_id": task,
        "trial_name": name,
        "is_resolved": resolved,
        "failure_mode": None,
        "total_input_tokens": tin,
        "total_output_tokens": tout,
    }


class SummaryRenderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.runs = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def write_run(self, results, sessions=None):
        run = self.runs / "shard-1"
        run.mkdir(parents=True)
        (run / "results.json").write_text(json.dumps({"results": results}))
        for trial_name, jsonl in (sessions or {}).items():
            sessions_dir = run / "task" / trial_name / "agent-logs" / "fah-sessions"
            sessions_dir.mkdir(parents=True)
            (sessions_dir / "s.jsonl").write_text(jsonl)

    def test_ut3_cost_column_and_totals_equal_trial_sums(self):
        trial_name = "t.1-of-1.shard-1"
        self.write_run(
            [trial("task-a", trial_name, True, 310, 80),
             trial("task-b", "u.1-of-1.shard-1", False, 40, 20),
             trial("task-c", "v.1-of-1.shard-1", False, 0, 0)],
            sessions={
                trial_name: json.dumps({
                    "type": "message",
                    "message": {
                        "role": "assistant", "model": "glm-5.3-flash",
                        "usage": {"input": 310, "output": 80, "cacheRead": 0, "cacheWrite": 0},
                    },
                })
            },
        )
        lines, problems = summary.render(self.runs)
        out = "\n".join(lines)
        self.assertEqual(problems, [])
        # Cost comes from bench/pricing.json: (310*0.15 + 80*0.5) / 1e6.
        self.assertIn("$0.0001", out)
        self.assertIn("tokens in/out: 350/100", out)
        self.assertIn("est. cost: $0.0001", out)
        # Rows with tokens but no price count as unpriced; the zero-token
        # row renders n/a but is NOT unpriced spend (harbor-aligned rule).
        self.assertIn("| task-b | u.1-of-1.shard-1 | no |  | 40/20 | n/a |", out)
        self.assertIn("| task-c | v.1-of-1.shard-1 | no |  | 0/0 | n/a |", out)
        self.assertIn("1 trial(s) unpriced", out)

    def test_agent_layout_sessions_found(self):
        # Pinned alternative layout: <run>/<task>/<trial>/agent/fah-sessions.
        run = self.runs / "shard-1"
        run.mkdir(parents=True)
        (run / "results.json").write_text(json.dumps(
            {"results": [trial("task-a", "t.1-of-1.shard-1", True, 10, 5)]}))
        sessions = run / "task" / "t.1-of-1.shard-1" / "agent" / "fah-sessions"
        sessions.mkdir(parents=True)
        (sessions / "s.jsonl").write_text(json.dumps({
            "type": "message",
            "message": {
                "role": "assistant", "model": "glm-5.3-flash",
                "content": [{"type": "text", "text": "Done"}],
                "usage": {"input": 10, "output": 5, "cacheRead": 0, "cacheWrite": 0},
            },
        }))
        lines, _ = summary.render(self.runs)
        out = "\n".join(lines)
        # Model came from the session record: priced, not n/a.
        self.assertIn("$0.0000", out)
        self.assertNotIn("| n/a |", out)

    def test_missing_sessions_warn_loudly(self):
        self.write_run([trial("task-a", "t.1-of-1.shard-1", True, 10, 5)])
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            lines, _ = summary.render(self.runs)
        self.assertIn("no fa session logs found", err.getvalue())

    def test_model_override_prices_every_row(self):
        self.write_run([trial("task-b", "u.1-of-1.shard-1", False, 0, 0)])
        lines, _ = summary.render(self.runs, model_override="glm-5.3-flash")
        out = "\n".join(lines)
        self.assertIn("0/0 | $0.0000 |", out)
        self.assertNotIn("unpriced", out)

    def test_estimated_share_noted_when_present(self):
        trial_name = "t.1-of-1.shard-1"
        self.write_run(
            [trial("task-a", trial_name, True, 100, 53)],
            sessions={
                trial_name: json.dumps({
                    "type": "message",
                    "message": {
                        "role": "assistant", "model": "glm-5.3-flash",
                        "content": [{"type": "text", "text": "x" * 12}],
                        # Provider omitted usage: the record contributes a
                        # chars/4 estimate (ceil(12/4) = 3), marked as such.
                        "usage": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                    },
                })
            },
        )
        lines, _ = summary.render(self.runs)
        self.assertIn("3 estimated tokens", "\n".join(lines))

    def test_no_results_reports_problem(self):
        lines, problems = summary.render(self.runs)
        self.assertTrue(any("No results.json" in line for line in lines))
        self.assertEqual(problems, ["no results.json produced"])

    def test_expected_count_shortfall_flags(self):
        self.write_run([trial("task-a", "t.1-of-1.shard-1", True, 0, 0)])
        lines, problems = summary.render(self.runs, expected=5)
        self.assertIn("only 1/5 expected tasks attempted", problems)


class ParseArgsTest(unittest.TestCase):
    def test_flags_and_positionals(self):
        no_fail, runs, expected, model = summary._parse_args(
            ["--no-fail", "runs", "5", "--model", "glm-5.3-flash"]
        )
        self.assertTrue(no_fail)
        self.assertEqual(runs, Path("runs"))
        self.assertEqual(expected, 5)
        self.assertEqual(model, "glm-5.3-flash")

    def test_valueless_model_flag_is_loud(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            with self.assertRaises(SystemExit) as ctx:
                summary._parse_args(["runs", "--model"])
        self.assertEqual(ctx.exception.code, 2)
        self.assertIn("--model requires a model id", err.getvalue())

    def test_missing_runs_dir_is_loud(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as ctx:
                summary._parse_args([])
        self.assertEqual(ctx.exception.code, 2)

    def test_non_numeric_expected_count_is_loud(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as ctx:
                summary._parse_args(["runs", "many"])
        self.assertEqual(ctx.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
