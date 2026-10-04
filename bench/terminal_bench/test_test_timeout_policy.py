#!/usr/bin/env python3
"""Unit tests for test_timeout_policy.py (gh-1206).

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import unittest

from test_timeout_policy import (
    FLOOR_ENV,
    floor_task_yaml,
    floored,
    parse_floor,
    resolve_floor,
)

TASK_YAML_60 = (
    "# canary\n"
    "difficulty: easy\n"
    "max_agent_timeout_sec: 360.0\n"
    "max_test_timeout_sec: 60.0\n"
    "run_tests_in_same_shell: false\n"
)
TASK_YAML_120 = TASK_YAML_60.replace("60.0\nrun_tests", "120.0\nrun_tests")
TASK_YAML_FLOORED = TASK_YAML_60.replace(
    "max_test_timeout_sec: 60.0", "max_test_timeout_sec: 120.0"
)


class ParseFloorTest(unittest.TestCase):
    def test_absent_and_empty_mean_no_floor(self):
        self.assertIsNone(parse_floor({}))
        self.assertIsNone(parse_floor({FLOOR_ENV: ""}))
        self.assertIsNone(parse_floor({FLOOR_ENV: "   "}))

    def test_numeric_values(self):
        self.assertEqual(parse_floor({FLOOR_ENV: "120"}), 120.0)
        self.assertEqual(parse_floor({FLOOR_ENV: " 90.5 "}), 90.5)
        self.assertEqual(parse_floor({FLOOR_ENV: "0"}), 0.0)

    def test_invalid_fails_loud(self):
        # A mistyped knob must never silently disable the floor (a silent
        # mis-parse costs a multi-hour run) - same contract as #1122.
        for bad in ("abc", "-5", "nan", "inf"):
            with self.assertRaises(ValueError):
                parse_floor({FLOOR_ENV: bad})


class FlooredTest(unittest.TestCase):
    def test_below_floor_is_raised(self):
        self.assertEqual(floored(60.0, 120.0), 120.0)

    def test_at_or_above_floor_is_untouched(self):
        self.assertEqual(floored(120.0, 120.0), 120.0)
        self.assertEqual(floored(240.0, 120.0), 240.0)

    def test_no_floor_or_zero_floor_keeps_declared(self):
        self.assertEqual(floored(60.0, None), 60.0)
        self.assertEqual(floored(60.0, 0.0), 60.0)


class FloorTaskYamlTest(unittest.TestCase):
    def test_below_floor_rewrites_only_the_test_line(self):
        new, declared, padded = floor_task_yaml(TASK_YAML_60, 120.0)
        self.assertEqual((declared, padded), (60.0, 120.0))
        self.assertEqual(new, TASK_YAML_FLOORED)

    def test_at_floor_is_byte_identical(self):
        self.assertEqual(
            floor_task_yaml(TASK_YAML_120, 120.0), (TASK_YAML_120, 120.0, 120.0)
        )

    def test_above_floor_is_byte_identical(self):
        text = "max_test_timeout_sec: 600.0\n"
        self.assertEqual(floor_task_yaml(text, 120.0), (text, 600.0, 600.0))

    def test_idempotent(self):
        once, _, _ = floor_task_yaml(TASK_YAML_60, 120.0)
        twice, declared, padded = floor_task_yaml(once, 120.0)
        self.assertEqual(twice, once)
        self.assertEqual((declared, padded), (120.0, 120.0))

    def test_missing_key_left_implicit(self):
        # tb's 60s TrialHandler default applies when the key is absent; the
        # patcher reports it as skipped instead of inventing yaml shape.
        text = "difficulty: easy\n"
        self.assertEqual(floor_task_yaml(text, 120.0), (text, None, None))


class ResolveFloorTest(unittest.TestCase):
    def test_flag_wins_over_env(self):
        self.assertEqual(resolve_floor("90", {FLOOR_ENV: "120"}), 90.0)

    def test_env_used_when_flag_blank(self):
        self.assertEqual(resolve_floor(None, {FLOOR_ENV: "120"}), 120.0)
        self.assertEqual(resolve_floor("", {FLOOR_ENV: "120"}), 120.0)
        self.assertEqual(resolve_floor("  ", {FLOOR_ENV: "120"}), 120.0)

    def test_neither_means_no_floor(self):
        self.assertIsNone(resolve_floor(None, {}))
        self.assertIsNone(resolve_floor("", {}))

    def test_invalid_flag_fails_loud(self):
        with self.assertRaises(ValueError):
            resolve_floor("abc", {})


if __name__ == "__main__":
    unittest.main()
