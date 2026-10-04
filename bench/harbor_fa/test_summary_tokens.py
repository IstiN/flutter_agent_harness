#!/usr/bin/env python3
"""UT-3 for issue #1123: harbor summary cost column + per-split aggregation.

Run: python3 -m unittest discover -s bench/harbor_fa
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("summary_harbor", _HERE / "summary.py")
summary = importlib.util.module_from_spec(spec)
sys.modules["summary_harbor"] = summary
spec.loader.exec_module(summary)


def write_trial(job_dir, name, resolved, tokens_in, tokens_out, cost, estimated=0, exception=""):
    trial_dir = job_dir / name
    trial_dir.mkdir(parents=True)
    rewards = {"verifier": 1.0} if resolved else {"verifier": 0.0}
    data = {
        "verifier_result": {"rewards": rewards},
        "exception_info": {"exception_type": exception} if exception else {},
        "agent_result": {
            "n_input_tokens": tokens_in,
            "n_output_tokens": tokens_out,
            "cost_usd": cost,
            "metadata": {"estimated_tokens": estimated} if estimated else {},
        },
    }
    (trial_dir / "result.json").write_text(json.dumps(data))


class HarborSummaryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.jobs = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def _build(self):
        cpu = self.jobs / "fa-4.0-modal-cpu-1"
        write_trial(cpu, "trial-1", True, 310, 80, 8.74e-05, estimated=3)
        # Tokens but no price → still counted, cost stays honest n/a.
        write_trial(cpu, "trial-2", False, 50, 10, None)
        # Errored before scoring: excluded from token/cost totals.
        write_trial(cpu, "trial-3", False, 999, 999, 9.99, exception="TimeoutError")
        return {
            "cpu": summary._trial_rows(cpu),
            "gpu": [],
        }

    def test_ut3_split_totals_and_overall_spend(self):
        # Errored trial + shortfall are the pre-existing completeness
        # verdict; this test pins the token/cost columns next to them.
        lines, problems = summary.render(self._build(), expected=3)
        out = "\n".join(lines)
        self.assertEqual(
            problems,
            [
                "1 trial(s) errored before producing a verdict",
                "only 2/3 expected trials attempted",
            ],
        )
        self.assertIn("Resolution: 1/2 scored trials", out)
        # Only scored, priced trials sum: 310+50 in / 80+10 out; $0.0001 total.
        self.assertIn("Spend: $0.0001 — tokens in/out: 360/90", out)
        self.assertIn("1 trial(s) unpriced", out)
        self.assertIn("3 estimated tokens", out)
        self.assertIn("| CPU shards | 1/2 | 1 errored | 360/90 | $0.0001 |", out)
        self.assertIn("| GPU shards | 0/0 | no trials | — | n/a |", out)

    def test_errored_trials_reported_and_fail_step(self):
        rows = self._build()
        lines, problems = summary.render(rows)
        self.assertEqual(problems, ["1 trial(s) errored before producing a verdict"])
        self.assertIn("TimeoutError ×1", "\n".join(lines))

    def test_no_jobs_reports_problem(self):
        lines, problems = summary.render({"cpu": [], "gpu": []})
        self.assertTrue(any("No harbor jobs found" in line for line in lines))
        self.assertEqual(problems, ["no harbor jobs found"])

    def test_trial_rows_read_agent_context(self):
        cpu = self.jobs / "fa-4.0-modal-cpu-1"
        write_trial(cpu, "trial-1", True, 310, 80, 8.74e-05, estimated=3)
        rows = summary._trial_rows(cpu)
        self.assertEqual(rows[0]["tokens_in"], 310)
        self.assertEqual(rows[0]["tokens_out"], 80)
        self.assertAlmostEqual(rows[0]["cost"], 8.74e-05, places=11)
        self.assertEqual(rows[0]["estimated"], 3)
        self.assertTrue(rows[0]["resolved"])

    def test_old_runs_without_agent_context_stay_zero(self):
        cpu = self.jobs / "fa-4.0-modal-cpu-1"
        (cpu / "trial-1").mkdir(parents=True)
        (cpu / "trial-1" / "result.json").write_text(json.dumps({"verifier_result": {"rewards": {}}}))
        rows = summary._trial_rows(cpu)
        self.assertEqual((rows[0]["tokens_in"], rows[0]["tokens_out"], rows[0]["cost"]), (0, 0, None))


if __name__ == "__main__":
    unittest.main()
