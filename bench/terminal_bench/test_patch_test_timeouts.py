#!/usr/bin/env python3
"""Unit tests for patch_test_timeouts.py (gh-1206).

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import patch_test_timeouts
from test_timeout_policy import FLOOR_ENV, OVERRIDES_ENV


def task_yaml(test_timeout):
    return (
        "difficulty: easy\n"
        f"max_agent_timeout_sec: 360.0\n"
        f"max_test_timeout_sec: {test_timeout}\n"
    )


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


class PatchDatasetTest(unittest.TestCase):
    def test_below_floor_tasks_rewritten_others_byte_identical(self):
        # A multi-item dataset: one task below the floor, one above, one
        # without the key at all.
        tmp, root = make_dataset({
            "jupyter-notebook-server": task_yaml("60.0"),
            "big-budget": task_yaml("600.0"),
            "no-key": "difficulty: easy\n",
        })
        try:
            changed, total = patch_test_timeouts.patch_dataset(root, 120.0)
            self.assertEqual((changed, total), (1, 3))
            padded = (root / "jupyter-notebook-server" / "task.yaml").read_text()
            self.assertIn("max_test_timeout_sec: 120.0", padded)
            self.assertNotIn(": 60.0", padded)
            self.assertEqual(
                (root / "big-budget" / "task.yaml").read_text(),
                task_yaml("600.0"),
            )
            self.assertEqual(
                (root / "no-key" / "task.yaml").read_text(), "difficulty: easy\n"
            )
        finally:
            tmp.cleanup()

    def test_idempotent_second_run_changes_nothing(self):
        tmp, root = make_dataset({"t": task_yaml("60.0")})
        try:
            patch_test_timeouts.patch_dataset(root, 120.0)
            before = (root / "t" / "task.yaml").read_text()
            changed, _ = patch_test_timeouts.patch_dataset(root, 120.0)
            self.assertEqual(changed, 0)
            self.assertEqual((root / "t" / "task.yaml").read_text(), before)
        finally:
            tmp.cleanup()

    def test_zero_floor_is_a_noop(self):
        tmp, root = make_dataset({"t": task_yaml("60.0")})
        try:
            changed, total = patch_test_timeouts.patch_dataset(root, 0.0)
            self.assertEqual((changed, total), (0, 1))
            self.assertEqual(
                (root / "t" / "task.yaml").read_text(), task_yaml("60.0")
            )
        finally:
            tmp.cleanup()

    def test_missing_dataset_dir_errors(self):
        tmp, root = make_dataset({})
        try:
            with self.assertRaises(SystemExit):
                patch_test_timeouts.patch_dataset(root / "nope", 120.0)
        finally:
            tmp.cleanup()


class MainCliTest(unittest.TestCase):
    def test_flag_floor_patches_and_reports(self):
        tmp, root = make_dataset({"jupyter": task_yaml("60.0")})
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                patch_test_timeouts.main([str(root), "--floor", "120"])
            out = buf.getvalue()
            self.assertIn("patched jupyter/task.yaml", out)
            self.assertIn("60.0 -> 120.0", out)
            self.assertIn("1 of 1 task.yaml(s) floored at 120.0s", out)
            self.assertIn(
                "max_test_timeout_sec: 120.0",
                (root / "jupyter" / "task.yaml").read_text(),
            )
        finally:
            tmp.cleanup()

    def test_env_floor_used_when_flag_absent(self):
        tmp, root = make_dataset({"jupyter": task_yaml("60.0")})
        try:
            env = {FLOOR_ENV: "120"}
            with mock.patch.dict(os.environ, env):
                buf = io.StringIO()
                with contextlib.redirect_stdout(buf):
                    patch_test_timeouts.main([str(root)])
            self.assertIn(
                "max_test_timeout_sec: 120.0",
                (root / "jupyter" / "task.yaml").read_text(),
            )
        finally:
            tmp.cleanup()

    def test_no_floor_configured_is_a_reported_noop(self):
        tmp, root = make_dataset({"jupyter": task_yaml("60.0")})
        try:
            env = {FLOOR_ENV: ""}
            with mock.patch.dict(os.environ, env):
                buf = io.StringIO()
                with contextlib.redirect_stdout(buf):
                    patch_test_timeouts.main([str(root)])
            self.assertIn("no floor configured", buf.getvalue())
            self.assertEqual(
                (root / "jupyter" / "task.yaml").read_text(), task_yaml("60.0")
            )
        finally:
            tmp.cleanup()

    def test_invalid_floor_fails_loud(self):
        tmp, root = make_dataset({"jupyter": task_yaml("60.0")})
        try:
            with self.assertRaises(SystemExit):
                patch_test_timeouts.main([str(root), "--floor", "abc"])
            self.assertEqual(
                (root / "jupyter" / "task.yaml").read_text(), task_yaml("60.0")
            )
        finally:
            tmp.cleanup()


class OverrideTableTest(unittest.TestCase):
    """gh-1407: per-task effective budget = max(declared, measured p95 x 1.5).

    The override table is evidence-driven (runner-measured p95 per
    repeat-offender task), applied on TOP of the floor for the table's
    tasks only — never a global floor bump.
    """

    def test_override_pads_only_tabled_task_above_floor(self):
        tmp, root = make_dataset({
            "jupyter-notebook-server": task_yaml("180.0"),
            "plain-task": task_yaml("60.0"),
        })
        try:
            overrides = {"jupyter-notebook-server": {"measured_p95_sec": 360.1}}
            changed, total = patch_test_timeouts.patch_dataset(
                root, 180.0, overrides=overrides
            )
            self.assertEqual((changed, total), (2, 2))
            self.assertIn(
                "max_test_timeout_sec: 271",
                (root / "jupyter-notebook-server" / "task.yaml").read_text(),
            )
            # floor-only task: same numbers as the gh-1206 behavior.
            self.assertIn(
                "max_test_timeout_sec: 180.0",
                (root / "plain-task" / "task.yaml").read_text(),
            )
        finally:
            tmp.cleanup()

    def test_override_never_lowers_a_declared_budget(self):
        tmp, root = make_dataset({"big": task_yaml("600.0")})
        try:
            overrides = {"big": {"measured_p95_sec": 360.1}}
            changed, _ = patch_test_timeouts.patch_dataset(root, None, overrides)
            self.assertEqual(changed, 0)
            self.assertEqual(
                (root / "big" / "task.yaml").read_text(), task_yaml("600.0")
            )
        finally:
            tmp.cleanup()

    def test_override_idempotent(self):
        tmp, root = make_dataset({"jupyter-notebook-server": task_yaml("180.0")})
        try:
            overrides = {"jupyter-notebook-server": {"measured_p95_sec": 360.1}}
            patch_test_timeouts.patch_dataset(root, 180.0, overrides)
            before = (root / "jupyter-notebook-server" / "task.yaml").read_text()
            changed, _ = patch_test_timeouts.patch_dataset(root, 180.0, overrides)
            self.assertEqual(changed, 0)
            self.assertEqual(
                (root / "jupyter-notebook-server" / "task.yaml").read_text(), before
            )
        finally:
            tmp.cleanup()

    def test_multiplier_flag_scales_the_declared_write(self):
        tmp, root = make_dataset({"jupyter-notebook-server": task_yaml("180.0")})
        try:
            overrides = {"jupyter-notebook-server": {"measured_p95_sec": 360.1}}
            patch_test_timeouts.patch_dataset(
                root, None, overrides=overrides, multiplier=1.0
            )
            # 360.1 x 1.5 = 540.15 -> ceil 541 declared = 541s effective.
            self.assertIn(
                "max_test_timeout_sec: 541",
                (root / "jupyter-notebook-server" / "task.yaml").read_text(),
            )
        finally:
            tmp.cleanup()

    def test_builtin_table_applies_by_default(self):
        # No --overrides flag: the checked-in table drives the patch, so
        # bench jobs pick the fix up with zero workflow changes.
        tmp, root = make_dataset({"jupyter-notebook-server": task_yaml("180.0")})
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                patch_test_timeouts.main([str(root), "--floor", "180"])
            self.assertIn(
                "max_test_timeout_sec: 271",
                (root / "jupyter-notebook-server" / "task.yaml").read_text(),
            )
            self.assertIn("override p95 360.1s", buf.getvalue())
        finally:
            tmp.cleanup()

    def test_no_overrides_flag_restores_floor_only(self):
        tmp, root = make_dataset({"jupyter-notebook-server": task_yaml("180.0")})
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                patch_test_timeouts.main(
                    [str(root), "--floor", "180", "--no-overrides"]
                )
            self.assertIn(
                "max_test_timeout_sec: 180.0",
                (root / "jupyter-notebook-server" / "task.yaml").read_text(),
            )
        finally:
            tmp.cleanup()

    def test_overrides_flag_points_at_custom_table(self):
        tmp, root = make_dataset({"my-task": task_yaml("60.0")})
        try:
            table = os.path.join(str(root), "table.json")
            Path(table).write_text(
                json.dumps({"my-task": {"measured_p95_sec": 100.0, "source": "s"}})
            )
            patch_test_timeouts.main([str(root), "--overrides", table])
            # 100 x 1.5 = 150 / 2 = 75 -> declared 75 (150s effective).
            self.assertIn(
                "max_test_timeout_sec: 75",
                (root / "my-task" / "task.yaml").read_text(),
            )
        finally:
            tmp.cleanup()

    def test_env_table_merges_over_builtin(self):
        tmp, root = make_dataset({"my-task": task_yaml("60.0")})
        try:
            table = os.path.join(str(root), "table.json")
            Path(table).write_text(
                json.dumps({"my-task": {"measured_p95_sec": 100.0, "source": "s"}})
            )
            env = {OVERRIDES_ENV: table}
            with mock.patch.dict(os.environ, env):
                patch_test_timeouts.main([str(root)])
            self.assertIn(
                "max_test_timeout_sec: 75",
                (root / "my-task" / "task.yaml").read_text(),
            )
        finally:
            tmp.cleanup()

    def test_invalid_overrides_file_fails_loud(self):
        tmp, root = make_dataset({"t": task_yaml("60.0")})
        try:
            bad = os.path.join(str(root), "bad.json")
            Path(bad).write_text("{not json")
            with self.assertRaises(SystemExit):
                patch_test_timeouts.main([str(root), "--overrides", bad])
            self.assertEqual(
                (root / "t" / "task.yaml").read_text(), task_yaml("60.0")
            )
        finally:
            tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
