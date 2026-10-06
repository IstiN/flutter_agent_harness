#!/usr/bin/env python3
"""gh-1308 NG2/AC3: the run summary separates zero-token provider hangs
from real cap-exhausted timeouts, and reports the zero-token-timeout
count explicitly — a regression guard for provider health across bench
runs (today an `agent_timeout` row is indistinguishable from a trial
that did real work until someone opens the agent logs).

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "summary_legacy", Path(__file__).resolve().parent / "summary.py"
)
summary = importlib.util.module_from_spec(spec)
sys.modules["summary_legacy"] = summary
spec.loader.exec_module(summary)


def trial(task, name, resolved, mode, tin, tout):
    return {
        "task_id": task,
        "trial_name": name,
        "is_resolved": resolved,
        "failure_mode": mode,
        "total_input_tokens": tin,
        "total_output_tokens": tout,
    }


class ZeroTokenTimeoutSplitTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.runs = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def write_run(self, results):
        run = self.runs / "shard-1"
        run.mkdir(parents=True)
        (run / "results.json").write_text(json.dumps({"results": results}))

    def test_ng2_zero_token_timeouts_counted_explicitly(self):
        # The gh-1308 evidence shape: agent_timeout rows with 0 tokens
        # (provider hang) next to one that burned real tokens before the
        # cap, other failure modes untouched.
        self.write_run([
            trial("t1", "x.1-of-1.shard-1", False, "agent_timeout", 0, 0),
            trial("t2", "y.1-of-1.shard-1", False, "agent_timeout", None, None),
            trial("t3", "z.1-of-1.shard-1", False, "agent_timeout", 4200, 900),
            trial("t4", "w.1-of-1.shard-1", False, "tests_failed", 800, 200),
            trial("t5", "v.1-of-1.shard-1", True, None, 120, 40),
        ])
        lines, problems = summary.render(self.runs)
        out = "\n".join(lines)
        self.assertEqual(problems, [])
        # NG2: the explicit count — the provider-health regression guard.
        self.assertIn("zero-token timeouts (provider hang): 2", out)
        self.assertIn("1 with real work (cap exhausted)", out)
        # AC3: the failure families carry the split, so the classification
        # is visible without log diving.
        self.assertIn("agent_timeout (0 tokens — provider hang) / no: 2", out)
        self.assertIn("agent_timeout (real work, cap exhausted) / no: 1", out)
        # A flat `agent_timeout` family row must NOT survive the split.
        self.assertNotIn("- agent_timeout /", out)

    def test_no_agent_timeout_rows_no_split_line(self):
        self.write_run([
            trial("t1", "x.1-of-1.shard-1", True, None, 10, 5),
            trial("t2", "y.1-of-1.shard-1", False, "tests_failed", 0, 0),
        ])
        lines, _ = summary.render(self.runs)
        out = "\n".join(lines)
        self.assertNotIn("zero-token timeouts", out)
        self.assertNotIn("provider hang", out)


if __name__ == "__main__":
    unittest.main()
