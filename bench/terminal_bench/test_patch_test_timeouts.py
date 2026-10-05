#!/usr/bin/env python3
"""Unit tests for patch_test_timeouts.py (gh-1206).

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import contextlib
import io
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import patch_test_timeouts
from test_timeout_policy import FLOOR_ENV


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


if __name__ == "__main__":
    unittest.main()
