#!/usr/bin/env python3
"""gh-1646 C3: the early-exit-with-unmet-ledger bench guard.

The FinalizeGate contract must never read as an early-exit license: a
failure that ended on its own (clean exit — no agent_timeout kill),
whose FINAL `task_ledger` still carries unmet items, ending ≥60s before
the effective cap is the "honest surrender" class — 49% of the gh-1646
failures (caffe-cifar-10 0/5, compile-compcert 586s/600s, ...). The
summary counts the class per run and prints its share of the failures.

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
    "summary_r1646", Path(__file__).resolve().parent / "summary.py"
)
summary = importlib.util.module_from_spec(spec)
sys.modules["summary_r1646"] = summary
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
    """UT: the pure gh-1646 classifier — unmet ledger + clean exit +
    remaining budget is classifiable from adapter data, each counter-
    case alone is not the class."""

    def test_honest_surrender_is_true(self):
        self.assertIs(
            summary.classify_early_exit_unmet(
                clean_exit=True, ledger_unmet=2, duration_secs=734, cap_secs=900
            ),
            True,
        )

    def test_killed_trial_is_not_the_class(self):
        self.assertIs(
            summary.classify_early_exit_unmet(
                clean_exit=False, ledger_unmet=2, duration_secs=734, cap_secs=900
            ),
            False,
        )

    def test_fully_verified_ledger_is_not_the_class(self):
        self.assertIs(
            summary.classify_early_exit_unmet(
                clean_exit=True, ledger_unmet=0, duration_secs=734, cap_secs=900
            ),
            False,
        )

    def test_at_the_wall_is_not_the_class(self):
        # 880s of a 900s cap: inside the 60s margin — the wall was
        # effectively reached.
        self.assertIs(
            summary.classify_early_exit_unmet(
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
                self.assertIsNone(summary.classify_early_exit_unmet(True, **kwargs))

    def test_custom_margin(self):
        self.assertIs(
            summary.classify_early_exit_unmet(True, 1, 100, 120, margin=10),
            True,
        )
        self.assertIs(
            summary.classify_early_exit_unmet(True, 1, 115, 120, margin=10),
            False,
        )


class EarlyExitGuardTest(unittest.TestCase):
    """AC2: the summary surfaces the early-exit-with-unmet-ledger share
    per run. The REG case is the caffe-cifar-10 shape: the agent builds
    the task, its ledger still says fail on the remaining items with a
    plan "to finish from here", and the process exits cleanly well
    before the cap."""

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
        extra_ledger_records=(),
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
        lines.extend(extra_ledger_records)
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
    def _guard_line(out: str) -> str:
        for line in out.splitlines():
            if line.startswith("**early-exit-with-unmet-ledger"):
                return line
        return ""

    def test_reg_caffe_cifar10_shape_is_counted(self):
        # The flagship: build succeeds, model/training items unmet, a
        # plan for the remaining work, clean exit at 734s of 900s.
        self._trial(
            "caffe-cifar-10",
            "caffe-cifar-10.1-of-1.shard-1",
            ledger_items=[
                _item(requirement="caffe builds", status="pass"),
                _item(requirement="model trains 1 epoch", status="fail"),
                _item(requirement="accuracy above chance", status="fail"),
            ],
        )
        out = self._render()
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 1/1 failures (100%)", out
        )
        self.assertIn("- caffe-cifar-10.1-of-1.shard-1 (734s/900s)", out)

    def test_multi_item_ledger_counts_unmet_not_trials(self):
        # R5: a 2+ item ledger where only some items verify — the unmet
        # count drives the class, and a single-item happy path must not
        # be the only shape that works.
        self._trial(
            "t",
            "t.1-of-1.shard-1",
            ledger_items=[
                _item(status="fixed"),
                _item(status="pass"),
                _item(status="fail", requirement="second requirement"),
                _item(status="fail", requirement="third requirement"),
            ],
        )
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 1/1 failures (100%)",
            self._render(),
        )

    def test_killed_trial_is_not_counted(self):
        self._trial(
            "t",
            "t.1-of-1.shard-1",
            ledger_items=[_item(status="fail")],
            mode="agent_timeout",
        )
        out = self._render()
        self.assertEqual(
            self._guard_line(out),
            "**early-exit-with-unmet-ledger (gh-1646): 0/1 failures (0%)**"
            " — clean exit + unmet task ledger + ≥60s budget left",
        )
        self.assertNotIn("- t.1-of-1.shard-1 (", out)

    def test_fully_verified_ledger_is_not_counted(self):
        self._trial(
            "t", "t.1-of-1.shard-1", ledger_items=[_item(status="pass")]
        )
        out = self._render()
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 0/1 failures (0%)", out
        )
        self.assertNotIn("- t.1-of-1.shard-1 (", out)

    def test_at_the_wall_is_not_counted(self):
        self._trial(
            "t",
            "t.1-of-1.shard-1",
            ledger_items=[_item(status="fail")],
            stamps=(0.0, 880.0),
            cap=900.0,
        )
        out = self._render()
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 0/1 failures (0%)", out
        )
        self.assertNotIn("- t.1-of-1.shard-1 (", out)

    def test_last_ledger_wins(self):
        # The agent re-verifies after fixes: an EARLY unmet ledger that a
        # later fully-verified ledger supersedes is not the class — the
        # LAST ledger is the state the trial exited with.
        task, name = "t", "t.1-of-1.shard-1"
        self._trial(
            task,
            name,
            extra_ledger_records=[
                _ledger_record([_item(status="fail")]),
                _ledger_record([_item(status="pass")]),
            ],
        )
        out = self._render()
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 0/1 failures (0%)", out
        )
        self.assertNotIn("- t.1-of-1.shard-1 (", out)

    def test_legacy_trial_without_audit_or_ledger_is_unclassifiable(self):
        self._trial("t", "t.1-of-1.shard-1", ledger_items=None, audit=False)
        out = self._render()
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 0/1 failures (0%)", out
        )
        self.assertIn("1 failure(s) unclassifiable", out)
        self.assertNotIn("- t.1-of-1.shard-1 (", out)

    def test_mixed_run_share(self):
        self._trial(
            "caffe-cifar-10",
            "caffe-cifar-10.1-of-2.shard-1",
            ledger_items=[_item(status="fail")],
        )
        self._trial(
            "other",
            "other.2-of-2.shard-1",
            ledger_items=[_item(status="fail")],
            mode="agent_timeout",
        )
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 1/2 failures (50%)",
            self._render(),
        )

    def test_all_green_run_stays_silent(self):
        self._trial(
            "t", "t.1-of-1.shard-1", ledger_items=[_item()], resolved=True
        )
        self.assertNotIn("early-exit-with-unmet-ledger", self._render())

    def test_pending_rows_stay_out_of_the_denominator(self):
        # A `pending` row is a lost/crashed shard (no verdict), not an
        # honest surrender — it must not enter the guard's denominator
        # even when its disk state happens to carry an unmet ledger
        # (review gh-1646: keep the share comparable with the harbor
        # sibling's scored_failures).
        self._trial(
            "t",
            "t.1-of-1.shard-1",
            ledger_items=[_item(status="fail")],
        )
        self._trial(
            "lost",
            "lost.1-of-1.shard-1",
            ledger_items=[_item(status="fail")],
            resolved=None,
        )
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 1/1 failures (100%)",
            self._render(),
        )

    def test_pending_only_run_stays_silent(self):
        # A run whose every non-yes row is pending (shard crashed) has
        # no scored failures — no guard block at all, never a fabricated
        # share over an empty denominator.
        self._trial(
            "lost",
            "lost.1-of-1.shard-1",
            ledger_items=[_item(status="fail")],
            resolved=None,
        )
        self.assertNotIn("early-exit-with-unmet-ledger", self._render())

    def test_test_timeout_is_not_a_clean_exit(self):
        # `test_timeout` = the verify phase burned the budget (gh-1206):
        # the trial did not end on its own. Clean exit is an allow-list
        # (failure mode empty) — the conservative direction (review
        # gh-1646): the row stays in the denominator, never the class.
        self._trial(
            "t",
            "t.1-of-1.shard-1",
            ledger_items=[_item(status="fail")],
            mode="test_timeout",
        )
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 0/1 failures (0%)",
            self._render(),
        )

    def test_unknown_future_failure_mode_is_not_a_clean_exit(self):
        # Allow-list, not block-list: an unrecognized failure mode is
        # never silently treated as a clean exit (review gh-1646).
        self._trial(
            "t",
            "t.1-of-1.shard-1",
            ledger_items=[_item(status="fail")],
            mode="some_future_mode",
        )
        self.assertIn(
            "early-exit-with-unmet-ledger (gh-1646): 0/1 failures (0%)",
            self._render(),
        )


if __name__ == "__main__":
    unittest.main()
