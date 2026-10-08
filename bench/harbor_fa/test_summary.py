#!/usr/bin/env python3
"""Unit tests for summary.py (issue #1124). Run: python3 -m unittest discover -s bench/harbor_fa"""
import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

from summary import main


def make_jobs(root: Path, name: str, trials: list[dict]) -> None:
    """trials: [{'resolved': bool} | {'exception': 'TimeoutError'}, ...]"""
    job = root / name
    for i, trial in enumerate(trials):
        d = job / f"trial-{i}"
        d.mkdir(parents=True)
        if "exception" in trial:
            data = {"exception_info": {"exception_type": trial["exception"]}}
        else:
            score = 1.0 if trial["resolved"] else 0.0
            data = {"verifier_result": {"rewards": {"r": score}}}
        (d / "result.json").write_text(json.dumps(data))


class SummaryTest(unittest.TestCase):
    def setUp(self):
        # Hermetic: CI exports GITHUB_STEP_SUMMARY for EVERY step, and
        # summary.py prefers that sink over stdout when set — the first
        # revision of these tests failed on real Actions runners. Pop it
        # by default; the sink test below re-points it at a temp file.
        self._summary_bak = os.environ.pop("GITHUB_STEP_SUMMARY", None)
        self.addCleanup(self._restore_summary)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.jobs = Path(tmp.name)

    def _restore_summary(self):
        if self._summary_bak is not None:
            os.environ["GITHUB_STEP_SUMMARY"] = self._summary_bak

    def _run(self, *argv) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = main(list(argv))
        return rc, out.getvalue()

    def test_step_summary_sink(self):
        # The sink CI actually uses: with GITHUB_STEP_SUMMARY set, the
        # report must land in the file (stdout stays quiet).
        sink = self.jobs / "step-summary.md"
        make_jobs(self.jobs, "fa-3.0-modal-cpu-0", [{"resolved": True}])
        os.environ["GITHUB_STEP_SUMMARY"] = str(sink)
        rc, out = self._run(
            str(self.jobs), "--family", "3.0", "--model", "glm-5.3-flash",
            "--fa-ref", "abc1234", "--run-url", "https://ci/run/1",
        )
        self.assertEqual(rc, 0)
        self.assertEqual(out, "")
        report = sink.read_text()
        self.assertIn("### fa on Terminal-Bench 3.0", report)
        self.assertIn("Ledger row", report)

    def test_ledger_separation_across_versions(self):
        # A merged jobs dir carrying two dataset versions: the 2.1 report
        # must count ONLY the fa-2.1-* jobs (no cross-contamination).
        make_jobs(self.jobs, "fa-2.1-modal-cpu-0", [{"resolved": True}, {"resolved": False}])
        make_jobs(self.jobs, "fa-2.1-modal-gpu-0", [{"resolved": True}])
        make_jobs(self.jobs, "fa-4.0-modal-cpu-0", [{"resolved": True}, {"resolved": True}])
        rc, out = self._run(
            str(self.jobs), "--family", "2.1", "--model", "glm-5.3-flash",
            "--fa-ref", "abc1234", "--run-url", "https://ci/run/1",
        )
        self.assertEqual(rc, 0)
        self.assertIn("### fa on Terminal-Bench 2.1 (terminal-bench/terminal-bench-2-1@latest)", out)
        self.assertIn("**Resolution: 2/3 scored trials**", out)
        self.assertIn("| CPU shards | 1/2 | 50.0% |", out)
        self.assertIn("| GPU shards | 1/1 | 100.0% |", out)
        # The foreign 4.0 trials are filtered out, not merged in (4/5).
        self.assertNotIn("4/5", out)
        # Paste-ready ledger row, keyed per version. Trials here carry no
        # token usage → the #1123 accounting renders the cost n/a, never
        # a made-up price.
        self.assertIn("| terminal-bench/terminal-bench-2-1@latest | glm-5.3-flash | abc1234 |", out)
        self.assertIn("| 2/3 trials (66.7%) |", out)
        self.assertIn("| n/a | https://ci/run/1 |", out)

    def test_ledger_row_carries_real_cost(self):
        # Composition #1123 + #1124: priced trials flow their cost total
        # into the ledger row's cost cell.
        job = self.jobs / "fa-2.1-modal-cpu-0"
        for i, (resolved, tin, tout, cost) in enumerate([
            (True, 310, 80, 8.74e-05),
            (False, 50, 10, None),
        ]):
            d = job / f"trial-{i}"
            d.mkdir(parents=True)
            data = {
                "verifier_result": {"rewards": {"r": 1.0 if resolved else 0.0}},
                "agent_result": {
                    "n_input_tokens": tin,
                    "n_output_tokens": tout,
                    "cost_usd": cost,
                    "metadata": {},
                },
            }
            (d / "result.json").write_text(json.dumps(data))
        rc, out = self._run(
            str(self.jobs), "--family", "2.1", "--model", "glm-5.3-flash",
            "--fa-ref", "abc1234", "--run-url", "https://ci/run/1",
        )
        self.assertEqual(rc, 0)
        self.assertIn("**Spend: $0.0001 — tokens in/out: 360/90", out)
        self.assertIn("| 1/2 trials (50.0%) | $0.0001 | https://ci/run/1 |", out)

    def test_errored_trials_excluded_from_ledger_counts(self):
        make_jobs(self.jobs, "fa-3.0-docker-cpu-0", [{"resolved": True}, {"exception": "TimeoutError"}])
        rc, out = self._run(str(self.jobs), "--family", "3.0")
        self.assertIn("**Resolution: 1/1 scored trials**", out)
        self.assertIn("TimeoutError ×1", out)

    def test_incomplete_run_fails(self):
        make_jobs(self.jobs, "fa-2.0-docker-cpu-0", [{"resolved": True}])
        rc, out = self._run(str(self.jobs), "--family", "2.0", "--expected-trials", "10")
        self.assertEqual(rc, 1)
        self.assertIn("1/10 expected trials", out)

    def test_no_jobs_for_family_fails(self):
        make_jobs(self.jobs, "fa-4.0-docker-cpu-0", [{"resolved": True}])
        rc, out = self._run(str(self.jobs), "--family", "2.1")
        self.assertEqual(rc, 1)
        self.assertIn("No harbor jobs found", out)

    def test_unknown_family_rejected(self):
        # Direct summary calls reject unknown families loudly (rc 2 +
        # stderr annotation) instead of rendering a mis-keyed report.
        import contextlib, io
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc, out = self._run(str(self.jobs), "--family", "9.9")
        self.assertEqual(rc, 2)
        self.assertEqual(out, "")
        self.assertIn("unknown Terminal-Bench family '9.9'", err.getvalue())

    def test_legacy_invocation_unchanged(self):
        # No --family: pre-#1124 behaviour (all job dirs, 4.0 title).
        make_jobs(self.jobs, "fa-4.0-docker-cpu-0", [{"resolved": True}])
        rc, out = self._run(str(self.jobs))
        self.assertEqual(rc, 0)
        self.assertIn("### fa on Terminal-Bench 4.0", out)
        self.assertIn("**Resolution: 1/1 scored trials**", out)
        self.assertNotIn("Ledger row", out)


def _write_ledger(trial_dir: Path, items: list[dict]) -> None:
    """The hidden `task_ledger` session record exactly as the Dart side
    persists it (gh-1412): a `custom` record, customType task_ledger."""
    sessions = trial_dir / "agent" / "fah-sessions"
    sessions.mkdir(parents=True)
    record = {"type": "custom", "customType": "task_ledger", "data": {"items": items}}
    (sessions / "session.jsonl").write_text(json.dumps(record) + "\n")


_ITEM = {
    "requirement": "index page content",
    "command": "curl -s localhost:80",
    "expected": "welcome",
    "actual": "welcome",
    "status": "pass",
}


class ChecklistCoverageTest(unittest.TestCase):
    """gh-1412: the near-miss proximity block from hidden task ledgers."""

    def setUp(self):
        # Same hermetic setup as SummaryTest (no inheritance — the base
        # suite must not double-run through a subclass).
        self._summary_bak = os.environ.pop("GITHUB_STEP_SUMMARY", None)
        self.addCleanup(self._restore_summary)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.jobs = Path(tmp.name)

    def _restore_summary(self):
        if self._summary_bak is not None:
            os.environ["GITHUB_STEP_SUMMARY"] = self._summary_bak

    def _run(self, *argv) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = main(list(argv))
        return rc, out.getvalue()

    def _run_default(self) -> tuple[int, str]:
        return self._run(str(self.jobs))

    def test_no_ledgers_stay_silent(self):
        make_jobs(self.jobs, "fa-4.0-docker-cpu-0", [{"resolved": True}])
        rc, out = self._run_default()
        self.assertEqual(rc, 0)
        self.assertNotIn("Checklist coverage", out)

    def test_proximity_block_lists_incomplete_trials(self):
        make_jobs(
            self.jobs,
            "fa-4.0-docker-cpu-0",
            [{"resolved": False}, {"resolved": True}],
        )
        job = self.jobs / "fa-4.0-docker-cpu-0"
        _write_ledger(
            job / "trial-0",
            [dict(_ITEM) for _ in range(6)] + [dict(_ITEM, status="fail")],
        )
        _write_ledger(job / "trial-1", [dict(_ITEM)])
        rc, out = self._run_default()
        self.assertEqual(rc, 0)
        self.assertIn(
            "Checklist coverage (gh-1412): 1/2 ledgered trials fully verified",
            out,
        )
        self.assertIn("- fa-4.0-docker-cpu-0/trial-0: checklist: 6/7 (1 unmet)", out)
        # The fully-verified trial is counted, not listed.
        self.assertNotIn("trial-1: checklist", out)

    def test_corrupt_ledger_payload_never_crashes(self):
        # gh-1412 review (empirically reproduced in round 2): a non-dict
        # `data` must degrade to `checklist: none`, never kill the render
        # (the Dart fold tolerates the same shapes).
        make_jobs(
            self.jobs,
            "fa-4.0-docker-cpu-0",
            [{"resolved": True}, {"resolved": True}, {"resolved": True},
             {"resolved": True}],
        )
        job = self.jobs / "fa-4.0-docker-cpu-0"
        for index, garbage in enumerate((3, "garbage", [1, 2], {"items": "nope"})):
            trial = job / f"trial-{index}"
            sessions = trial / "agent" / "fah-sessions"
            sessions.mkdir(parents=True, exist_ok=True)
            (sessions / "session.jsonl").write_text(
                json.dumps({
                    "type": "custom",
                    "customType": "task_ledger",
                    "data": garbage,
                })
                + "\n"
            )
        rc, out = self._run_default()
        self.assertEqual(rc, 0)
        self.assertNotIn("Checklist coverage", out)

    def test_empty_ledger_is_not_fully_verified(self):
        # A ledger with no items verifies nothing — rendering 0/0 would
        # count the trial as fully verified in the coverage tally.
        make_jobs(self.jobs, "fa-4.0-docker-cpu-0", [{"resolved": True}])
        _write_ledger(self.jobs / "fa-4.0-docker-cpu-0" / "trial-0", [])
        rc, out = self._run_default()
        self.assertEqual(rc, 0)
        self.assertNotIn("Checklist coverage", out)


if __name__ == "__main__":
    unittest.main()
