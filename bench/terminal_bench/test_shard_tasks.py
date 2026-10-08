#!/usr/bin/env python3
"""Unit tests for shard_tasks.py (issue #142). Run: python3 -m unittest discover -s bench/terminal_bench"""
import json
import os
import random
import tempfile
import unittest
from pathlib import Path

import shard_tasks
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


class BudgetFloorTest(unittest.TestCase):
    """gh-1206: shard sizing must see the padded (floored) test budgets."""

    def test_floor_raises_test_side_of_budget(self):
        tmp, root = make_dataset({
            "t": "max_agent_timeout_sec: 360\nmax_test_timeout_sec: 60\n"
        })
        try:
            self.assertEqual(task_budget(root, "t", test_floor=120.0), 480.0)
        finally:
            tmp.cleanup()

    def test_task_at_or_above_floor_untouched(self):
        tmp, root = make_dataset({
            "t": "max_agent_timeout_sec: 360\nmax_test_timeout_sec: 240\n"
        })
        try:
            self.assertEqual(task_budget(root, "t", test_floor=120.0), 600.0)
        finally:
            tmp.cleanup()

    def test_no_floor_and_zero_floor_keep_declared(self):
        body = "max_agent_timeout_sec: 360\nmax_test_timeout_sec: 60\n"
        tmp, root = make_dataset({"t": body})
        try:
            self.assertEqual(task_budget(root, "t"), 420.0)
            self.assertEqual(task_budget(root, "t", test_floor=0.0), 420.0)
        finally:
            tmp.cleanup()

    def test_floor_applied_per_task_across_dataset(self):
        tmp, root = make_dataset({
            "a": "max_agent_timeout_sec: 360\nmax_test_timeout_sec: 60\n",
            "b": "max_agent_timeout_sec: 360\nmax_test_timeout_sec: 600\n",
        })
        try:
            self.assertEqual(
                [task_budget(root, t, test_floor=120.0) for t in ("a", "b")],
                [480.0, 960.0],
            )
        finally:
            tmp.cleanup()

    def test_main_wires_floor_into_budgets(self):
        """Two tasks whose floored budgets tie must LPT tie-break by name.

        a declares test=120, b declares test=60; floored at 120 both budget
        480 -> name order puts a in shard 0. Without the floor wired, b
        (480) outranks a (420) and lands in shard 0 — the placement flip is
        the observable.
        """
        tmp, root = make_dataset({
            "a": "max_agent_timeout_sec: 360\nmax_test_timeout_sec: 120\n",
            "b": "max_agent_timeout_sec: 360\nmax_test_timeout_sec: 60\n",
        })
        try:
            out = tempfile.NamedTemporaryFile("w", delete=False, suffix=".out")
            out.close()
            os.environ["GITHUB_OUTPUT"] = out.name
            import runpy
            import sys
            sys.argv = [
                "shard_tasks.py", "--dataset-dir", str(root), "--shards", "2",
                "--test-timeout-floor", "120",
            ]
            try:
                runpy.run_path(
                    str(Path(__file__).parent / "shard_tasks.py"),
                    run_name="__main__",
                )
            finally:
                sys.argv = ["shard_tasks.py"]
                del os.environ["GITHUB_OUTPUT"]
            emitted = Path(out.name).read_text()
            matrix = json.loads(
                [l for l in emitted.splitlines() if l.startswith("matrix=")][0]
                .split("=", 1)[1]
            )
            firsts = [entry["tasks"].split()[0] for entry in matrix["include"]]
            self.assertEqual(firsts, ["a", "b"])
            os.unlink(out.name)
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


class PackCapTest(unittest.TestCase):
    """ShardPacker cap validation (issue #1392 AC5).

    The packer must never hand a shard a worst case above the job cap's
    usable budget (cap − 15 min headroom): round 2 lost shard-0 by ~1 min
    with zero headroom. Over-cap is a loud ::error naming the numbers —
    never a silent multi-hour over-run.
    """

    def test_split_within_cap_passes_and_respects_budget(self):
        ids = [f"t{i}" for i in range(20)]
        budgets = {t: 600.0 for t in ids}
        shards = split_lpt(ids, budgets, 4)
        loads = shard_tasks.check_cap(shards, budgets, 355 * 60.0)
        # 20 tasks x 600s over 4 shards = 3000s per shard, far under the
        # 340-min usable budget.
        self.assertTrue(all(load <= 340 * 60.0 for load in loads))

    def test_over_cap_raises_loud_error(self):
        ids = [f"t{i}" for i in range(8)]
        budgets = {t: 7200.0 for t in ids}  # 4 shards worth over 2 shards
        shards = split_lpt(ids, budgets, 2)
        with self.assertRaises(SystemExit) as ctx:
            shard_tasks.check_cap(shards, budgets, 355 * 60.0)
        self.assertIn("::error::", str(ctx.exception))
        self.assertIn("shards", str(ctx.exception))

    def test_zero_cap_disables_validation(self):
        ids = [f"t{i}" for i in range(8)]
        budgets = {t: 7200.0 for t in ids}
        shards = split_lpt(ids, budgets, 2)
        self.assertEqual(
            len(shard_tasks.check_cap(shards, budgets, 0)), 2
        )

    def test_property_random_mixes_never_silently_exceed_cap(self):
        # AC5 property: over seeded random task mixes, whenever the packer
        # returns shards, every shard's worst case fits the usable budget
        # (cap − 15 min); an infeasible mix fails LOUD via SystemExit.
        rng = random.Random(1392)
        for iteration in range(200):
            n_tasks = rng.randint(1, 40)
            n_shards = rng.randint(1, 8)
            ids = [f"task-{i}" for i in range(n_tasks)]
            budgets = {
                t: rng.uniform(60.0, 4800.0) for t in ids
            }
            shards = split_lpt(ids, budgets, n_shards)
            total = sum(budgets.values())
            cap = rng.uniform(max(budgets.values()) + 60.0, 355.0 * 60.0)
            try:
                loads = shard_tasks.check_cap(shards, budgets, cap)
            except SystemExit as exc:
                # Loud failure is a legal outcome for an infeasible mix;
                # the error must name the remedy either way.
                self.assertIn("::error::", str(exc))
                self.assertIn("shards", str(exc))
                continue
            for load in loads:
                self.assertLessEqual(
                    load,
                    cap - shard_tasks.HEADROOM_SEC,
                    f"iter {iteration}: shard load {load} > {cap} - headroom",
                )


class BudgetOverrideTest(unittest.TestCase):
    """gh-1407: LPT budgets must see the override-padded test budgets."""

    def test_task_budget_honors_override_p95(self):
        tmp, root = make_dataset({
            "jupyter-notebook-server":
                "max_agent_timeout_sec: 360\nmax_test_timeout_sec: 180\n",
        })
        try:
            self.assertEqual(
                task_budget(root, "jupyter-notebook-server",
                            override_p95=360.1, multiplier=2.0),
                360.0 + 271,
            )
        finally:
            tmp.cleanup()

    def test_task_budget_floor_plus_override_together(self):
        tmp, root = make_dataset({
            "t": "max_agent_timeout_sec: 360\nmax_test_timeout_sec: 60\n",
        })
        try:
            # floor wins over the small p95; override would only raise.
            self.assertEqual(
                task_budget(root, "t", test_floor=120.0,
                            override_p95=100.0, multiplier=2.0),
                480.0,
            )
            self.assertEqual(
                task_budget(root, "t", test_floor=120.0,
                            override_p95=360.1, multiplier=2.0),
                360.0 + 271,
            )
        finally:
            tmp.cleanup()


class FairnessWarningTest(unittest.TestCase):
    """gh-1407 AC2: never-again guard at planning time.

    When a planned task's EFFECTIVE test budget (declared x multiplier,
    after floor + override) is still below the runner-measured p95, the
    planner emits a ::warning:: naming both numbers — a structurally
    unpassable task must be caught before burning an agent run + test
    slot, not in the post-mortem.
    """

    def test_check_fairness_reports_offender_with_numbers(self):
        offenders = shard_tasks.check_fairness(
            {"jupyter-notebook-server": 360.0, "fast": 120.0},
            {"jupyter-notebook-server": 360.1},
        )
        self.assertEqual([(t, e, p) for t, e, p in offenders],
                         [("jupyter-notebook-server", 360.0, 360.1)])

    def test_check_fairness_silent_when_budget_covers_p95(self):
        self.assertEqual(
            shard_tasks.check_fairness(
                {"jupyter-notebook-server": 542.0},
                {"jupyter-notebook-server": 360.1},
            ),
            [],
        )

    def test_check_fairness_ignores_unmeasured_tasks(self):
        self.assertEqual(shard_tasks.check_fairness({"a": 1.0}, {}), [])

    def _run_planner(self, root, extra_args, out_path):
        os.environ["GITHUB_OUTPUT"] = out_path
        import runpy
        import sys
        sys.argv = ["shard_tasks.py", "--dataset-dir", str(root)] + extra_args
        import io as _io
        import contextlib as _contextlib
        buf = _io.StringIO()
        try:
            with _contextlib.redirect_stdout(buf):
                runpy.run_path(
                    str(Path(__file__).parent / "shard_tasks.py"),
                    run_name="__main__",
                )
        finally:
            sys.argv = ["shard_tasks.py"]
            del os.environ["GITHUB_OUTPUT"]
        return buf.getvalue(), Path(out_path).read_text()

    def test_floor_only_dispatch_warns_on_measured_offender(self):
        """The r3 configuration (floor, no overrides) must scream."""
        tmp, root = make_dataset({
            "jupyter-notebook-server":
                "max_agent_timeout_sec: 360\nmax_test_timeout_sec: 180\n",
        })
        try:
            out = tempfile.NamedTemporaryFile("w", delete=False, suffix=".out")
            out.close()
            stdout, emitted = self._run_planner(
                root,
                ["--shards", "1", "--test-timeout-floor", "180",
                 "--no-overrides"],
                out.name,
            )
            self.assertIn("::warning::", stdout)
            self.assertIn("jupyter-notebook-server", stdout)
            self.assertIn("360", stdout)   # effective budget seconds
            self.assertIn("360.1", stdout)  # measured p95 seconds
            self.assertIn("fairness_warnings=1", emitted)
            os.unlink(out.name)
        finally:
            tmp.cleanup()

    def test_override_applied_dispatch_does_not_warn(self):
        tmp, root = make_dataset({
            "jupyter-notebook-server":
                "max_agent_timeout_sec: 360\nmax_test_timeout_sec: 180\n",
        })
        try:
            out = tempfile.NamedTemporaryFile("w", delete=False, suffix=".out")
            out.close()
            stdout, emitted = self._run_planner(
                root, ["--shards", "1", "--test-timeout-floor", "180"], out.name
            )
            self.assertNotIn("::warning::", stdout)
            self.assertIn("fairness_warnings=0", emitted)
            os.unlink(out.name)
        finally:
            tmp.cleanup()

    def test_planner_sizes_lpt_on_overridden_budget(self):
        """The override must land in the emitted worst-shard math too."""
        tmp, root = make_dataset({
            "jupyter-notebook-server":
                "max_agent_timeout_sec: 360\nmax_test_timeout_sec: 180\n",
        })
        try:
            out = tempfile.NamedTemporaryFile("w", delete=False, suffix=".out")
            out.close()
            _, emitted = self._run_planner(
                root, ["--shards", "1", "--test-timeout-floor", "180"], out.name
            )
            worst = float([l for l in emitted.splitlines()
                           if l.startswith("worst_shard_seconds=")][0]
                          .split("=", 1)[1])
            self.assertEqual(worst, 360 + 271)
            os.unlink(out.name)
        finally:
            tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
