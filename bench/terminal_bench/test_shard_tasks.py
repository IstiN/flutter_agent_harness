#!/usr/bin/env python3
"""Unit tests for shard_tasks.py (issue #142). Run: python3 -m unittest discover -s bench/terminal_bench"""
import json
import os
import tempfile
import unittest
from pathlib import Path

from shard_tasks import resolve_task_ids, split_lpt, task_budget


def make_dataset(tasks):
    """tasks: dict of task_id -> task.yaml body (or None for a taskless dir)."""
    tmp = tempfile.TemporaryDirectory()
    root = Path(tmp.name)
    for task_id, body in tasks.items():
        d = root / task_id
        d.mkdir(parents=True)
        if body is not None:
            (d / "task.yaml").write_text(body)
    return tmp, root


class ResolveTest(unittest.TestCase):
    def test_glob_union_sorted(self):
        tmp, root = make_dataset({"b": "difficulty: easy\n", "a": None, "c": ""})
        try:
            self.assertEqual(resolve_task_ids(root, ["*"]), ["a", "b", "c"])
            self.assertEqual(resolve_task_ids(root, ["b"]), ["b"])
            self.assertEqual(resolve_task_ids(root, ["b", "a"]), ["a", "b"])
        finally:
            tmp.cleanup()

    def test_no_match_raises(self):
        tmp, root = make_dataset({"a": None})
        try:
            with self.assertRaises(SystemExit):
                resolve_task_ids(root, ["zzz*"])
        finally:
            tmp.cleanup()


class BudgetTest(unittest.TestCase):
    def test_declared_budget_summed(self):
        tmp, root = make_dataset({
            "t": "max_agent_timeout_sec: 900\nmax_test_timeout_sec: 120\n"
        })
        try:
            self.assertEqual(task_budget(root, "t"), 1020.0)
        finally:
            tmp.cleanup()

    def test_tb_defaults_when_fields_missing(self):
        tmp, root = make_dataset({"t": "difficulty: hard\n"})
        try:
            # tb TrialHandler defaults: 360s agent / 60s test.
            self.assertEqual(task_budget(root, "t"), 420.0)
        finally:
            tmp.cleanup()


class SplitLptTest(unittest.TestCase):
    def test_all_tasks_placed_exactly_once(self):
        ids = [f"t{i}" for i in range(23)]
        budgets = {t: 360.0 + 60.0 for t in ids}
        shards = split_lpt(ids, budgets, 8)
        placed = [t for s in shards for t in s]
        self.assertEqual(sorted(placed), sorted(ids))
        self.assertEqual(len(placed), len(set(placed)))

    def test_loads_balanced_within_one_task(self):
        # 10 tasks with distinct budgets; 2 shards must split 6/4 by LPT.
        budgets = {"a": 100, "b": 90, "c": 80, "d": 70, "e": 60, "f": 50,
                   "g": 40, "h": 30, "i": 20, "j": 10}
        shards = split_lpt(list(budgets), budgets, 2)
        loads = [sum(budgets[t] for t in s) for s in shards]
        self.assertLessEqual(max(loads) - min(loads), max(budgets.values()))

    def test_deterministic(self):
        ids = [f"task-{c}" for c in "abcdefgh"]
        budgets = {t: 420.0 for t in ids}  # all equal -> name tie-break
        self.assertEqual(split_lpt(ids, budgets, 3), split_lpt(ids, budgets, 3))

    def test_more_shards_than_tasks_drops_empties(self):
        ids = ["a", "b"]
        budgets = {t: 420.0 for t in ids}
        shards = [s for s in split_lpt(ids, budgets, 5) if s]
        self.assertEqual(len(shards), 2)


class MatrixOutputTest(unittest.TestCase):
    def test_github_output_contract(self):
        """The emitted matrix stays parseable: include entries with i + space-joined tasks."""
        tmp, root = make_dataset({
            f"task-{i}": "max_agent_timeout_sec: 360\n" for i in range(20)
        })
        try:
            out = tempfile.NamedTemporaryFile("w", delete=False, suffix=".out")
            out.close()
            os.environ["GITHUB_OUTPUT"] = out.name
            import runpy
            import sys
            sys.argv = ["shard_tasks.py", "--dataset-dir", str(root), "--shards", "4"]
            try:
                runpy.run_path(
                    str(Path(__file__).parent / "shard_tasks.py"), run_name="__main__"
                )
            finally:
                sys.argv = ["shard_tasks.py"]
                del os.environ["GITHUB_OUTPUT"]
            emitted = Path(out.name).read_text()
            matrix = json.loads(
                [l for l in emitted.splitlines() if l.startswith("matrix=")][0]
                .split("=", 1)[1]
            )
            count = int(
                [l for l in emitted.splitlines() if l.startswith("count=")][0]
                .split("=", 1)[1]
            )
            self.assertEqual(count, 20)
            self.assertEqual(
                sum(len(entry["tasks"].split()) for entry in matrix["include"]), 20
            )
            self.assertEqual(
                [entry["i"] for entry in matrix["include"]], [0, 1, 2, 3]
            )
            os.unlink(out.name)
        finally:
            tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
