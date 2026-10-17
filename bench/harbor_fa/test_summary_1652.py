#!/usr/bin/env python3
"""gh-1652 C4: the CLEAN-WRONG class in the harbor summary.

The mirror image of the gh-1646 surrender guard: a trial that ended on
its own (`__FA_EXIT=0`), whose FINAL `task_ledger` carries ZERO unmet
items, and whose verifier rewards are all 0 — the agent validated through
its own checklist oracle and never ran the grader's invocation. Reported
per run NEXT to the early-exit share; the two classes stay DISJOINT (a
trial is counted once — the caffe-style surrender never appears here).

Run: python3 -m unittest discover -s bench/harbor_fa
"""
import json
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from summary import classify_clean_exit_wrong, main, render

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
    """A pre-built summary row (the test_summary_1646 shape) with the
    gh-1652 fields filled in."""
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
        "clean_exit_wrong": None,
        "reward_zero": None,
        "duration_secs": None,
        "cap_secs": None,
    }
    row.update(overrides)
    return row


class ClassifierTest(unittest.TestCase):
    """UT: the pure gh-1652 classifier — clean exit + zero-unmet ledger
    + verifier reward 0 is the class; any other combination is not;
    missing inputs never fabricate one (the gh-1646 contract shape)."""

    def test_clean_wrong_is_true(self):
        # The chess-best-move shape: ledger fully verified, reward 0.
        self.assertIs(
            classify_clean_exit_wrong(
                clean_exit=True, ledger_unmet=0, reward_zero=True
            ),
            True,
        )

    def test_killed_trial_is_not_the_class(self):
        self.assertIs(
            classify_clean_exit_wrong(
                clean_exit=False, ledger_unmet=0, reward_zero=True
            ),
            False,
        )

    def test_surrender_ledger_is_not_the_class(self):
        # REG (disjoint classes): a caffe-style surrender — unmet items
        # — is the gh-1646 class, never this one.
        self.assertIs(
            classify_clean_exit_wrong(
                clean_exit=True, ledger_unmet=2, reward_zero=True
            ),
            False,
        )

    def test_nonzero_reward_is_not_the_class(self):
        self.assertIs(
            classify_clean_exit_wrong(
                clean_exit=True, ledger_unmet=0, reward_zero=False
            ),
            False,
        )

    def test_missing_inputs_are_unclassifiable(self):
        for kwargs in (
            {"ledger_unmet": None, "reward_zero": True},
            {"ledger_unmet": 0, "reward_zero": None},
        ):
            with self.subTest(kwargs=kwargs):
                self.assertIsNone(classify_clean_exit_wrong(True, **kwargs))

    def test_classes_are_disjoint_for_every_input_shape(self):
        from summary import classify_early_exit_unmet

        for clean in (True, False):
            for unmet in (None, 0, 1, 3):
                for reward in (None, True, False):
                    early = classify_early_exit_unmet(clean, unmet, 734, 900)
                    wrong = classify_clean_exit_wrong(clean, unmet, reward)
                    self.assertFalse(
                        early is True and wrong is True,
                        msg=(clean, unmet, reward),
                    )


class CleanExitWrongGuardTest(unittest.TestCase):
    """AC3: the summary surfaces the clean_exit_wrong share per run,
    next to the early-exit share, and the two stay disjoint."""

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
        reward=0.0,
        with_rewards=True,
        fa_exit=0,
        fa_txt="agent output...\n",
        ledger_items=None,
        exception=None,
        resolved=False,
        audit=True,
        duration=734.0,
        cap=900.0,
    ):
        trial_dir = self.jobs / job / trial
        agent = trial_dir / "agent"
        agent.mkdir(parents=True, exist_ok=True)
        data = {
            "started_at": _iso(0),
            "finished_at": _iso(duration),
        }
        if with_rewards:
            data["verifier_result"] = {"rewards": {"r": reward}}
        if exception:
            data["exception_info"] = {"exception_type": exception}
        (trial_dir / "result.json").write_text(json.dumps(data))
        if fa_txt is not None:
            marker = f"__FA_EXIT={fa_exit}\n" if fa_exit is not None else ""
            (agent / "fa.txt").write_text(fa_txt + marker)
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
    def _line(out: str, prefix: str) -> str:
        for line in out.splitlines():
            if line.startswith(prefix):
                return line
        return ""

    def test_reg_chess_best_move_shape_is_counted(self):
        # The flagship CLEAN-WRONG shape: ledger fully verified, every
        # verifier reward 0, `__FA_EXIT=0` — validated with the wrong
        # oracle.
        self._trial(
            "fa-4.0-docker-cpu-0",
            "chess-best-move",
            ledger_items=[
                _item(requirement="a legal move written", status="pass"),
                _item(requirement="single line output", status="pass"),
            ],
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        self.assertIn(
            "clean_exit_wrong (gh-1652): 1/1 failures (100%)", out
        )
        self.assertIn("- fa-4.0-docker-cpu-0/chess-best-move", out)
        # Disjointness on the same trial: the early-exit class stays 0.
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 0/1 failures (0%)", out
        )

    def test_reg_surrender_trial_is_not_clean_exit_wrong(self):
        # The caffe shape: unmet ledger items — the gh-1646 class owns
        # this trial; clean_exit_wrong must NOT count it (counted once).
        self._trial(
            "fa-4.0-docker-cpu-0",
            "caffe-cifar-10",
            ledger_items=[
                _item(requirement="caffe builds", status="pass"),
                _item(requirement="model trains 1 epoch", status="fail"),
            ],
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 1/1 failures (100%)", out
        )
        self.assertIn(
            "clean_exit_wrong (gh-1652): 0/1 failures (0%)", out
        )

    def test_nonzero_fa_exit_is_not_counted(self):
        self._trial(
            "fa-4.0-docker-cpu-0",
            "t0",
            fa_exit=1,
            ledger_items=[_item(status="pass")],
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        self.assertIn(
            "clean_exit_wrong (gh-1652): 0/1 failures (0%)", out
        )

    def test_partial_reward_is_not_the_class(self):
        # Partial credit is not reward 0 — the verifier disagreed only
        # partially, so the wrong-oracle claim is not established.
        self._trial(
            "fa-4.0-docker-cpu-0",
            "t0",
            reward=0.5,
            ledger_items=[_item(status="pass")],
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        self.assertIn(
            "clean_exit_wrong (gh-1652): 0/1 failures (0%)", out
        )

    def test_no_rewards_is_unclassifiable(self):
        # Legacy result.json without verifier rewards: no reward-0
        # evidence — unclassifiable, never a fabricated class.
        self._trial(
            "fa-4.0-docker-cpu-0",
            "t0",
            with_rewards=False,
            ledger_items=[_item(status="pass")],
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        self.assertIn(
            "clean_exit_wrong (gh-1652): 0/1 failures (0%)", out
        )
        self.assertIn("1 failure(s) unclassifiable for clean_exit_wrong", out)

    def test_killed_trial_is_not_counted(self):
        self._trial(
            "fa-4.0-docker-cpu-0",
            "t0",
            exception="AgentTimeoutError",
            fa_txt=None,
            ledger_items=[_item(status="pass")],
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        # The errored trial is outside the scored-failure denominator.
        self.assertNotIn("clean_exit_wrong", out)

    def test_mixed_run_share_counts_once(self):
        self._trial(
            "fa-4.0-docker-cpu-0",
            "chess-best-move",
            ledger_items=[_item(status="pass")],
        )
        self._trial(
            "fa-4.0-docker-cpu-1",
            "caffe-cifar-10",
            ledger_items=[_item(status="fail")],
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        self.assertIn(
            "clean_exit_wrong (gh-1652): 1/2 failures (50%)", out
        )
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 1/2 failures (50%)", out
        )

    def test_all_green_run_stays_silent(self):
        self._trial(
            "fa-4.0-docker-cpu-0",
            "t0",
            reward=1.0,
            ledger_items=[_item()],
        )
        rc, out = self._run()
        self.assertEqual(rc, 0)
        self.assertNotIn("clean_exit_wrong", out)

    def test_render_tolerates_rows_without_gh1652_fields(self):
        # Hand-built rows predating the guard (the gh-1578 make_row
        # shape) must not KeyError the render: the tolerant `.get`
        # contract keeps legacy rows unclassified.
        lines, _ = render(
            {
                "cpu": [make_row()],
                "gpu": [
                    make_row(
                        clean_exit_wrong=True,
                        trial="fa-4.0-docker-cpu-0/chess-best-move",
                    )
                ],
            },
        )
        out = "\n".join(lines)
        self.assertIn(
            "clean_exit_wrong (gh-1652): 1/2 failures (50%)", out
        )
        self.assertIn("- fa-4.0-docker-cpu-0/chess-best-move", out)


if __name__ == "__main__":
    unittest.main()
