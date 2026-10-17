#!/usr/bin/env python3
"""gh-1646 C3: the early-exit-with-unmet-ledger bench guard (harbor).

The FinalizeGate contract must never read as an early-exit license: a
failure that ended on its own (`__FA_EXIT=0` in the synced fa.txt), whose
FINAL `task_ledger` still carries unmet items, ending ≥60s before the
effective cap is the "honest surrender" class — 49% of the gh-1646
failures (caffe-cifar-10 0/5 with a "to finish from here" plan,
compile-compcert 586s/600s, ...). The summary counts the class per run
and prints its share of the failures.

Run: python3 -m unittest discover -s bench/harbor_fa
"""
import json
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from summary import (
    _EARLY_EXIT_MARGIN_SEC,
    _fa_exit_code,
    classify_early_exit_unmet,
    main,
)

_BASE = datetime(2025, 10, 16, 9, 0, 0, tzinfo=timezone.utc)


def _iso(offset_sec: float) -> str:
    return (_BASE + timedelta(seconds=offset_sec)).isoformat()


def _item(status="pass", requirement="model trains 1 epoch"):
    return {
        "requirement": requirement,
        "command": "python train.py --epochs 1",
        "expected": "exit 0",
        "actual": "exit 0",
        "status": status,
    }


def make_row(**overrides):
    """A pre-built summary row (the test_summary_1578 shape) with the
    gh-1646 fields filled in."""
    row = {
        "resolved": False,
        "exception": "",
        "verifier_timeout": False,
        "hang_secs": None,
        "tokens_in": 0,
        "tokens_out": 0,
        "cost": None,
        "estimated": 0,
        "checklist": "checklist: none",
        "trial": "fa-4.0-docker-cpu-0/trial-0",
        "integrity": None,
        "integrity_note": "",
        "early_exit_unmet": None,
        "duration_secs": None,
        "cap_secs": None,
    }
    row.update(overrides)
    return row


class ClassifierTest(unittest.TestCase):
    """UT: the pure gh-1646 classifier — unmet ledger + clean exit +
    remaining budget is classifiable from adapter data."""

    def test_honest_surrender_is_true(self):
        self.assertIs(
            classify_early_exit_unmet(
                clean_exit=True, ledger_unmet=2, duration_secs=734, cap_secs=900
            ),
            True,
        )

    def test_killed_trial_is_not_the_class(self):
        self.assertIs(
            classify_early_exit_unmet(
                clean_exit=False, ledger_unmet=2, duration_secs=734, cap_secs=900
            ),
            False,
        )

    def test_fully_verified_ledger_is_not_the_class(self):
        self.assertIs(
            classify_early_exit_unmet(
                clean_exit=True, ledger_unmet=0, duration_secs=734, cap_secs=900
            ),
            False,
        )

    def test_at_the_wall_is_not_the_class(self):
        self.assertIs(
            classify_early_exit_unmet(
                clean_exit=True, ledger_unmet=3, duration_secs=880, cap_secs=900
            ),
            False,
        )

    def test_missing_inputs_are_unclassifiable(self):
        for kwargs in (
            {"ledger_unmet": None, "duration_secs": 734, "cap_secs": 900},
            {"ledger_unmet": 2, "duration_secs": None, "cap_secs": 900},
            {"ledger_unmet": 2, "duration_secs": 734, "cap_secs": None},
        ):
            with self.subTest(kwargs=kwargs):
                self.assertIsNone(classify_early_exit_unmet(True, **kwargs))

    def test_margin_matches_the_tb_sibling(self):
        self.assertEqual(_EARLY_EXIT_MARGIN_SEC, 60.0)


class FaExitCodeTest(unittest.TestCase):
    """The `__FA_EXIT=` marker parse: the LAST line wins."""

    def _dir(self, text):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        trial = Path(tmp.name) / "trial"
        (trial / "agent").mkdir(parents=True)
        (trial / "agent" / "fa.txt").write_text(text)
        return trial

    def test_zero_marker(self):
        self.assertEqual(
            _fa_exit_code(self._dir("output...\n__FA_EXIT=0\n")), 0
        )

    def test_last_marker_wins(self):
        self.assertEqual(
            _fa_exit_code(self._dir("__FA_EXIT=1\nmore\n__FA_EXIT=0\n")), 0
        )

    def test_nonzero_marker(self):
        self.assertEqual(
            _fa_exit_code(self._dir("__FA_EXIT=143\n")), 143
        )

    def test_absent_file_and_marker_degrade_to_none(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.assertIsNone(_fa_exit_code(Path(tmp.name)))
        self.assertIsNone(_fa_exit_code(self._dir("no marker here")))


class EarlyExitGuardTest(unittest.TestCase):
    """AC2: the summary surfaces the early-exit-with-unmet-ledger share
    per run. The REG case is the caffe-cifar-10 shape: the agent builds
    the task, its ledger still says fail on the remaining items with a
    plan "to finish from here", and the process exits `__FA_EXIT=0`
    at 734s of a 900s cap."""

    def setUp(self):
        # Hermetic: CI exports GITHUB_STEP_SUMMARY for EVERY step and
        # main() prefers that sink over stdout (the test_summary.py
        # lesson) — pop it so _run() sees the report text.
        self._summary_bak = os.environ.pop("GITHUB_STEP_SUMMARY", None)
        self.addCleanup(self._restore_summary)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.jobs = Path(tmp.name)

    def _restore_summary(self):
        if self._summary_bak is not None:
            os.environ["GITHUB_STEP_SUMMARY"] = self._summary_bak

    def _trial(
        self,
        job,
        trial,
        *,
        resolved=False,
        exception=None,
        fa_exit=0,
        fa_txt="agent output...\n",
        ledger_items=None,
        duration=734.0,
        cap=900.0,
        audit=True,
    ):
        trial_dir = self.jobs / job / trial
        agent = trial_dir / "agent"
        agent.mkdir(parents=True, exist_ok=True)
        data = {
            "verifier_result": {"rewards": {"r": 1.0 if resolved else 0.0}},
            "started_at": _iso(0),
            "finished_at": _iso(duration),
        }
        if exception:
            data["exception_info"] = {"exception_type": exception}
        (trial_dir / "result.json").write_text(json.dumps(data))
        if fa_txt is not None:
            (agent / "fa.txt").write_text(fa_txt + (f"__FA_EXIT={fa_exit}\n" if fa_exit is not None else ""))
        sessions = agent / "fah-sessions"
        sessions.mkdir(parents=True, exist_ok=True)
        if ledger_items is not None:
            (sessions / "session.jsonl").write_text(json.dumps({
                "type": "custom",
                "customType": "task_ledger",
                "data": {"items": ledger_items},
            }) + "\n")
        if audit:
            (agent / "fa-timeout-metadata.json").write_text(json.dumps({
                "outcome": "completed",
                "cap_resolution": {
                    "external_cap_status": "known",
                    "effective_cap_sec": cap,
                    "external_cap_sec": cap,
                    "winning_cap_source": "external",
                    "deadline_clamped": False,
                },
            }))

    def _run(self):
        import io
        import contextlib

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = main([str(self.jobs)])
        return rc, out.getvalue()

    @staticmethod
    def _guard_line(out: str) -> str:
        for line in out.splitlines():
            if line.startswith("**early-exit-with-unmet-ledger"):
                return line
        return ""

    def test_reg_caffe_cifar10_shape_is_counted(self):
        # The flagship: build succeeds, model/training items unmet, a
        # plan for the remaining work, `__FA_EXIT=0` at 734s of 900s.
        self._trial(
            "fa-4.0-docker-cpu-0",
            "caffe-cifar-10",
            ledger_items=[
                _item(requirement="caffe builds", status="pass"),
                _item(requirement="model trains 1 epoch", status="fail"),
                _item(requirement="accuracy above chance", status="fail"),
            ],
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 1/1 failures (100%)", out
        )
        self.assertIn("- fa-4.0-docker-cpu-0/caffe-cifar-10 (734s/900s)", out)

    def test_nonzero_fa_exit_is_not_counted(self):
        self._trial(
            "fa-4.0-docker-cpu-0",
            "t0",
            fa_exit=1,
            ledger_items=[_item(status="fail")],
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 0/1 failures (0%)", out
        )
        self.assertNotIn("- fa-4.0-docker-cpu-0/t0 (", out)

    def test_no_fa_txt_falls_back_to_the_exception_class(self):
        # Legacy artifacts without the marker: no exception = the exec
        # ended on its own — still classifiable.
        self._trial(
            "fa-4.0-docker-cpu-0",
            "t0",
            fa_txt=None,
            ledger_items=[_item(status="fail")],
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 1/1 failures (100%)", out
        )

    def test_killed_trial_is_not_counted(self):
        self._trial(
            "fa-4.0-docker-cpu-0",
            "t0",
            exception="AgentTimeoutError",
            fa_txt=None,
            ledger_items=[_item(status="fail")],
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        # The errored trial is outside the scored-failure denominator.
        self.assertNotIn("early-exit-with-unmet-ledger", out)

    def test_fully_verified_ledger_is_not_counted(self):
        self._trial(
            "fa-4.0-docker-cpu-0",
            "t0",
            ledger_items=[_item(status="pass")],
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 0/1 failures (0%)", out
        )
        self.assertNotIn("- fa-4.0-docker-cpu-0/t0 (", out)

    def test_at_the_wall_is_not_counted(self):
        self._trial(
            "fa-4.0-docker-cpu-0",
            "t0",
            ledger_items=[_item(status="fail")],
            duration=880.0,
            cap=900.0,
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 0/1 failures (0%)", out
        )

    def test_legacy_trial_without_audit_or_ledger_is_unclassifiable(self):
        self._trial(
            "fa-4.0-docker-cpu-0", "t0", ledger_items=None, audit=False
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 0/1 failures (0%)", out
        )
        self.assertIn("1 failure(s) unclassifiable", out)

    def test_mixed_run_share(self):
        self._trial(
            "fa-4.0-docker-cpu-0",
            "caffe-cifar-10",
            ledger_items=[_item(status="fail")],
        )
        self._trial(
            "fa-4.0-docker-cpu-1",
            "other",
            ledger_items=[_item(status="pass")],
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 1/2 failures (50%)", out
        )

    def test_all_green_run_stays_silent(self):
        self._trial(
            "fa-4.0-docker-cpu-0",
            "t0",
            resolved=True,
            ledger_items=[_item()],
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        self.assertNotIn("early-exit-with-unmet-ledger", out)

    def test_render_tolerates_rows_without_gh1646_fields(self):
        # Hand-built rows predating the guard (the gh-1578 make_row
        # shape) must not KeyError the render: the tolerant `.get`
        # contract keeps legacy rows unclassified.
        from summary import render

        lines, _ = render(
            {
                "cpu": [make_row()],
                "gpu": [
                    make_row(
                        early_exit_unmet=True,
                        duration_secs=448.0,
                        cap_secs=600.0,
                        trial="fa-4.0-docker-cpu-0/path-tracing",
                    )
                ],
            },
        )
        out = "\n".join(lines)
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 1/2 failures (50%)", out
        )
        self.assertIn("- fa-4.0-docker-cpu-0/path-tracing (448s/600s)", out)


if __name__ == "__main__":
    unittest.main()
