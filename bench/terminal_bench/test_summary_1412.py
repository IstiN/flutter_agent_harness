#!/usr/bin/env python3
"""gh-1412 UT-3: the bench summary renders the per-task checklist-coverage
line from the trial's hidden `task_ledger` session records (the
FinalizeGate contract's telemetry), with the no-ledger edge degrading to
`checklist: none`.

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "summary_r1412", Path(__file__).resolve().parent / "summary.py"
)
summary = importlib.util.module_from_spec(spec)
sys.modules["summary_r1412"] = summary
spec.loader.exec_module(summary)


def _results(run_dir, rows):
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "results.json").write_text(json.dumps({"results": rows}))


def _row(task, name, resolved=True):
    return {
        "task_id": task,
        "trial_name": name,
        "is_resolved": resolved,
        "failure_mode": "",
        "total_input_tokens": 0,
        "total_output_tokens": 0,
    }


def _ledger_record(items):
    """The exact shape the Dart side persists: a hidden `custom` session
    record, customType `task_ledger`, data.items carrying per-item
    requirement/command/status."""
    return json.dumps({
        "type": "custom",
        "customType": "task_ledger",
        "data": {"items": items},
    })


def _ledger(run_dir, task, trial, items):
    sessions = run_dir / "shard-0" / task / trial / "agent-logs" / "fah-sessions"
    sessions.mkdir(parents=True)
    (sessions / "session.jsonl").write_text(_ledger_record(items) + "\n")


_ITEM = {
    "requirement": "script.py is executable",
    "command": "test -x script.py",
    "expected": "exit 0",
    "actual": "exit 0",
    "status": "pass",
}


class ChecklistCoverageTest(unittest.TestCase):
    """AC4: the per-task table carries the near-miss proximity line."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.runs = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def _render_one(self, items, name="t.1-of-1.shard-1"):
        _results(self.runs / "shard-0", [_row("t", name)])
        _ledger(self.runs, "t", name, items)
        lines, _ = summary.render(self.runs)
        return "\n".join(lines)

    def test_all_verified(self):
        out = self._render_one([dict(_ITEM), dict(_ITEM, status="fixed")])
        self.assertIn("checklist: 2/2 |", out)

    def test_near_miss_is_visible(self):
        # The gh-1412 headline case: 6 of 7 verified, one unmet — the
        # summary must show the proximity, not just "no".
        items = [dict(_ITEM) for _ in range(6)] + [dict(_ITEM, status="fail")]
        out = self._render_one(items)
        self.assertIn("checklist: 6/7 (1 unmet) |", out)

    def test_last_ledger_wins(self):
        # The agent re-verifies after fixes: the FINAL ledger is the
        # trial's coverage, earlier drafts are ignored.
        name = "t.1-of-1.shard-1"
        sessions = self.runs / "shard-0" / "t" / name / "agent-logs" / "fah-sessions"
        sessions.mkdir(parents=True)
        (sessions / "session.jsonl").write_text(
            _ledger_record([dict(_ITEM, status="fail")])
            + "\n"
            + _ledger_record([_ITEM])
            + "\n"
        )
        _results(self.runs / "shard-0", [_row("t", name)])
        lines, _ = summary.render(self.runs)
        self.assertIn("checklist: 1/1 |", "\n".join(lines))

    def test_unknown_status_counts_unmet(self):
        out = self._render_one([dict(_ITEM, status="reported")])
        self.assertIn("checklist: 0/1 (1 unmet) |", out)

    def test_no_ledger_renders_none(self):
        _results(self.runs / "shard-0", [_row("t", "t.1-of-1.shard-1")])
        lines, _ = summary.render(self.runs)
        out = "\n".join(lines)
        self.assertIn("checklist: none |", out)

    def test_corrupt_ledger_payload_never_crashes(self):
        # gh-1412 review: the Dart fold tolerates corrupt ledger payloads
        # ("a corrupt ledger payload never throws"); the Python parser must
        # degrade the same way — a non-dict `data` renders `checklist:
        # none`, it never kills the summary render.
        for garbage in (3, "garbage", [1, 2], None, {"items": "nope"}):
            with self.subTest(garbage=garbage):
                name = "t.1-of-1.shard-1"
                sessions = (
                    self.runs / "shard-0" / "t" / name / "agent-logs"
                    / "fah-sessions"
                )
                sessions.mkdir(parents=True, exist_ok=True)
                (sessions / "session.jsonl").write_text(
                    json.dumps({
                        "type": "custom",
                        "customType": "task_ledger",
                        "data": garbage,
                    })
                    + "\n"
                )
                _results(self.runs / "shard-0", [_row("t", name)])
                lines, _ = summary.render(self.runs)
                self.assertIn("checklist: none |", "\n".join(lines))

    def test_empty_items_ledger_is_none(self):
        # An items-less ledger verifies nothing; rendering 0/0 would count
        # it as fully verified downstream.
        out = self._render_one([])
        self.assertIn("checklist: none |", out)

    def test_ledger_less_trial_among_ledgered_ones(self):
        # Mixed run: one trial with a ledger, one legacy trial without.
        _results(self.runs / "shard-0", [_row("a", "a.1"), _row("b", "b.1")])
        _ledger(self.runs, "a", "a.1", [_ITEM])
        lines, _ = summary.render(self.runs)
        out = "\n".join(lines)
        self.assertIn("| a | a.1 | yes |  | checklist: 1/1 |", out)
        self.assertIn("| b | b.1 | yes |  | checklist: none |", out)


if __name__ == "__main__":
    unittest.main()
