#!/usr/bin/env python3
"""UT-3 for issue #1123: legacy summary cost column + totals aggregation.

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import importlib.util
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
             trial("task-b", "u.1-of-1.shard-1", False, 0, 0)],
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
        self.assertIn("tokens in/out: 310/80", out)
        self.assertIn("est. cost: $0.0001", out)
        # The zero-token trial stays 0 with no fake cost (model unknown → n/a).
        self.assertIn("| task-b | u.1-of-1.shard-1 | no |  | 0/0 | n/a |", out)
        self.assertIn("1 trial(s) unpriced", out)

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


if __name__ == "__main__":
    unittest.main()
