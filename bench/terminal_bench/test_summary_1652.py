#!/usr/bin/env python3
"""gh-1652 C4: the CLEAN-WRONG class in the bench summaries (tb side).

The mirror image of the gh-1646 surrender guard: a trial that exited
cleanly, whose FINAL `task_ledger` carries ZERO unmet items (the agent
believed it was done — it validated through its own checklist oracle:
file exists, move is legal), and whose verifier still scored reward 0.
41% of the gh-1652 bench failures (chess-best-move verified the move is
LEGAL, not that it matches the grader's expected answer; mteb-retrieve
never ran the grader's `len(lines) == 1` check).

The class is DISJOINT from `early_exit_unmet` by construction: the two
key on opposite sides of `ledger_unmet <= 0`, so a trial is counted once
— the REG case is the caffe-style surrender trial, which must land in
early_exit_unmet and NEVER in clean_exit_wrong.

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "summary_r1652", Path(__file__).resolve().parent / "summary.py"
)
summary = importlib.util.module_from_spec(spec)
sys.modules["summary_r1652"] = summary
spec.loader.exec_module(summary)

_BASE = 1700000000.0  # a fixed epoch second; timestamps are fixture-only


def _iso(offset_sec: float) -> str:
    return datetime.fromtimestamp(_BASE + offset_sec, timezone.utc).isoformat()


def _item(status="pass", requirement="script.py is executable"):
    return {
        "requirement": requirement,
        "command": "test -x script.py",
        "expected": "exit 0",
        "actual": "exit 0",
        "status": status,
    }


def _ledger_record(items):
    """The hidden `task_ledger` custom record exactly as the Dart side
    persists it (gh-1412)."""
    return json.dumps({
        "type": "custom",
        "customType": "task_ledger",
        "data": {"items": items},
    })


class ClassifierTest(unittest.TestCase):
    """UT: the pure gh-1652 classifier — clean exit + zero-unmet ledger
    + verifier reward 0 is the class; any other combination is not;
    missing inputs never fabricate one (the gh-1646 contract shape)."""

    def test_clean_wrong_is_true(self):
        # The chess-best-move shape: ledger fully verified (the agent
        # proved the move LEGAL), verifier says the answer is wrong.
        self.assertIs(
            summary.classify_clean_exit_wrong(
                clean_exit=True, ledger_unmet=0, reward_zero=True
            ),
            True,
        )

    def test_killed_trial_is_not_the_class(self):
        self.assertIs(
            summary.classify_clean_exit_wrong(
                clean_exit=False, ledger_unmet=0, reward_zero=True
            ),
            False,
        )

    def test_surrender_ledger_is_not_the_class(self):
        # REG (disjoint classes): a caffe-style surrender — unmet items
        # in the final ledger — is the gh-1646 class, never this one,
        # even with a clean exit and reward 0.
        self.assertIs(
            summary.classify_clean_exit_wrong(
                clean_exit=True, ledger_unmet=2, reward_zero=True
            ),
            False,
        )

    def test_nonzero_reward_is_not_the_class(self):
        self.assertIs(
            summary.classify_clean_exit_wrong(
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
                self.assertIsNone(
                    summary.classify_clean_exit_wrong(True, **kwargs)
                )

    def test_classes_are_disjoint_for_every_input_shape(self):
        # No (clean_exit, ledger_unmet, reward_zero) triple classifies
        # as BOTH early-exit-surrender and clean-exit-wrong.
        for clean in (True, False):
            for unmet in (None, 0, 1, 3):
                for reward in (None, True, False):
                    early = summary.classify_early_exit_unmet(
                        clean, unmet, 734, 900
                    )
                    wrong = summary.classify_clean_exit_wrong(
                        clean, unmet, reward
                    )
                    self.assertFalse(
                        early is True and wrong is True,
                        msg=(clean, unmet, reward),
                    )


class CleanExitWrongGuardTest(unittest.TestCase):
    """AC3: the summary surfaces the clean_exit_wrong share per run,
    next to the early-exit share, and the two stay disjoint."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.runs = Path(self.tmp.name)
        self.rows = []
        self.addCleanup(self.tmp.cleanup)

    def _trial(
        self,
        task,
        trial,
        *,
        ledger_items=None,
        stamps=(0.0, 734.0),
        cap=900.0,
        audit=True,
        mode="",
        resolved=False,
    ):
        shard = self.runs / "shard-0"
        trial_dir = shard / task / trial
        sessions = trial_dir / "agent-logs" / "fah-sessions"
        sessions.mkdir(parents=True, exist_ok=True)
        self.rows.append({
            "task_id": task,
            "trial_name": trial,
            "is_resolved": resolved,
            "failure_mode": mode,
            "total_input_tokens": 10,
            "total_output_tokens": 10,
        })
        (shard / "results.json").write_text(json.dumps({"results": self.rows}))
        lines = [
            json.dumps({"type": "system", "timestamp": _iso(stamps[0])}),
            json.dumps({
                "type": "message",
                "timestamp": _iso(stamps[1]),
                "message": {"role": "assistant"},
            }),
        ]
        if ledger_items is not None:
            lines.append(_ledger_record(ledger_items))
        (sessions / "session.jsonl").write_text("\n".join(lines) + "\n")
        if audit:
            (trial_dir / "fa-agent-timeout.json").write_text(json.dumps({
                "outcome": "completed",
                "cap_resolution": {
                    "external_cap_status": "known",
                    "effective_cap_sec": cap,
                    "external_cap_sec": cap,
                    "winning_cap_source": "external",
                    "deadline_clamped": False,
                },
            }))

    def _render(self):
        lines, _ = summary.render(self.runs)
        return "\n".join(lines)

    @staticmethod
    def _line(out: str, prefix: str) -> str:
        for line in out.splitlines():
            if line.startswith(prefix):
                return line
        return ""

    def test_reg_chess_best_move_shape_is_counted(self):
        # The flagship CLEAN-WRONG shape: the ledger is fully verified
        # (the agent proved the move legal) and the verifier scored 0 —
        # validated with the wrong oracle.
        self._trial(
            "chess-best-move",
            "chess-best-move.1-of-1.shard-1",
            ledger_items=[
                _item(requirement="a legal move written", status="pass"),
                _item(requirement="single line output", status="pass"),
            ],
        )
        out = self._render()
        self.assertIn(
            "clean_exit_wrong (gh-1652): 1/1 failures (100%)", out
        )
        # The clean_exit_wrong listing is the bare trial line (anchored:
        # the early-exit listing's `- trial (734s/900s)` must not match).
        self.assertRegex(
            out, r"(?m)^- chess-best-move\.1-of-1\.shard-1$"
        )
        # Disjointness on the same trial: the early-exit class stays 0.
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 0/1 failures (0%)", out
        )

    def test_reg_surrender_trial_is_not_clean_exit_wrong(self):
        # The caffe shape: unmet ledger items — the gh-1646 class owns
        # this trial; clean_exit_wrong must NOT count it (counted once).
        self._trial(
            "caffe-cifar-10",
            "caffe-cifar-10.1-of-1.shard-1",
            ledger_items=[
                _item(requirement="caffe builds", status="pass"),
                _item(requirement="model trains 1 epoch", status="fail"),
            ],
        )
        out = self._render()
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 1/1 failures (100%)", out
        )
        self.assertIn(
            "clean_exit_wrong (gh-1652): 0/1 failures (0%)", out
        )
        self.assertNotRegex(
            out, r"(?m)^- caffe-cifar-10\.1-of-1\.shard-1$"
        )

    def test_killed_trial_is_not_counted(self):
        self._trial(
            "t",
            "t.1-of-1.shard-1",
            ledger_items=[_item(status="pass")],
            mode="agent_timeout",
        )
        out = self._render()
        self.assertIn(
            "clean_exit_wrong (gh-1652): 0/1 failures (0%)", out
        )
        self.assertNotRegex(out, r"(?m)^- t\.1-of-1\.shard-1$")

    def test_unverified_ledger_is_not_counted(self):
        # A zero-unmet claim needs a ledger — none/empty is unmet-unknown
        # (the gh-1412 parse contract), never a fabricated clean pass.
        self._trial("t", "t.1-of-1.shard-1", ledger_items=None)
        out = self._render()
        self.assertIn(
            "clean_exit_wrong (gh-1652): 0/1 failures (0%)", out
        )
        self.assertIn("1 failure(s) unclassifiable for clean_exit_wrong", out)
        self.assertNotRegex(out, r"(?m)^- t\.1-of-1\.shard-1$")

    def test_pending_trial_without_verifier_verdict_is_unclassifiable(self):
        # No verifier verdict (pending) = no reward-0 evidence → the
        # trial is never claimed as clean-exit-wrong.
        self._trial(
            "t",
            "t.1-of-1.shard-1",
            ledger_items=[_item(status="pass")],
            mode="unresolved",
        )
        self._rows_resolved_none()
        out = self._render()
        self.assertIn(
            "clean_exit_wrong (gh-1652): 0/1 failures (0%)", out
        )
        self.assertNotRegex(out, r"(?m)^- t\.1-of-1\.shard-1$")

    def _rows_resolved_none(self):
        """Rewrite the fixture row to the `is_resolved: None` shape."""
        shard = self.runs / "shard-0"
        data = json.loads((shard / "results.json").read_text())
        data["results"][0]["is_resolved"] = None
        (shard / "results.json").write_text(json.dumps(data))

    def test_mixed_run_share_counts_once(self):
        # Two failures: one CLEAN-WRONG (verified ledger, reward 0), one
        # surrender (unmet ledger). Each lands in exactly one class.
        self._trial(
            "chess-best-move",
            "chess-best-move.1-of-2.shard-1",
            ledger_items=[_item(status="pass")],
        )
        self._trial(
            "caffe-cifar-10",
            "caffe-cifar-10.2-of-2.shard-1",
            ledger_items=[_item(status="fail")],
        )
        out = self._render()
        self.assertIn(
            "clean_exit_wrong (gh-1652): 1/2 failures (50%)", out
        )
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 1/2 failures (50%)", out
        )

    def test_all_green_run_stays_silent(self):
        self._trial(
            "t", "t.1-of-1.shard-1", ledger_items=[_item()], resolved=True
        )
        self.assertNotIn("clean_exit_wrong", self._render())


if __name__ == "__main__":
    unittest.main()
