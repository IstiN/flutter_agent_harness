#!/usr/bin/env python3
"""Unit tests for test_timeout_policy.py (gh-1206).

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from test_timeout_policy import (
    FLOOR_ENV,
    MULTIPLIER_ENV,
    OVERRIDES_ENV,
    floor_task_yaml,
    floored,
    load_overrides,
    override_declared,
    padded_task_yaml,
    parse_floor,
    resolve_floor,
    resolve_multiplier,
    effective_test_seconds,
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


class OverridePolicyTest(unittest.TestCase):
    """gh-1407: per-task override table policy (the slow-suite fix).

    The floor (above) serves fast suites; the override table carries the
    runner-MEASURED p95 per repeat-offender task and pads that task's
    declared budget so effective >= measured p95 x 1.5 — never a global
    floor bump.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def _write_json(self, name, payload):
        path = os.path.join(self.tmp.name, name)
        Path(path).write_text(json.dumps(payload))
        return path

    # -- multiplier -----------------------------------------------------
    def test_multiplier_defaults_to_bench_two(self):
        self.assertEqual(resolve_multiplier(), 2.0)

    def test_multiplier_flag_beats_env(self):
        self.assertEqual(resolve_multiplier("3", {MULTIPLIER_ENV: "4"}), 3.0)
        self.assertEqual(resolve_multiplier(None, {MULTIPLIER_ENV: "4"}), 4.0)

    def test_multiplier_must_be_finite_positive(self):
        for bad in ("0", "-1", "abc", "inf", "nan"):
            with self.assertRaises(ValueError):
                resolve_multiplier(None, {MULTIPLIER_ENV: bad})

    # -- override table loading -----------------------------------------
    def test_builtin_table_loads_and_validates(self):
        table = load_overrides(env={})
        self.assertIn("jupyter-notebook-server", table)
        for task_id, entry in table.items():
            self.assertIn("measured_p95_sec", entry, task_id)
            self.assertGreater(entry["measured_p95_sec"], 0, task_id)
            self.assertTrue(entry.get("source"), task_id)

    def test_extra_env_table_merges_over_builtin(self):
        extra = self._write_json(
            "extra.json", {"my-task": {"measured_p95_sec": 90.0, "source": "s"}}
        )
        table = load_overrides(env={OVERRIDES_ENV: extra})
        self.assertEqual(table["my-task"]["measured_p95_sec"], 90.0)
        self.assertIn("jupyter-notebook-server", table)

    def test_explicit_path_replaces_builtin(self):
        path = self._write_json("only.json", {"solo": {"measured_p95_sec": 5.0}})
        self.assertEqual(list(load_overrides(path=path, env={})), ["solo"])

    def test_no_overrides_disables_everything(self):
        extra = self._write_json(
            "extra.json", {"my-task": {"measured_p95_sec": 90.0, "source": "s"}}
        )
        self.assertEqual(
            load_overrides(path=extra, no_overrides=True, env={OVERRIDES_ENV: extra}),
            {},
        )

    def test_missing_builtin_loads_empty(self):
        # A checkout without the shipped table (or a renamed file): the
        # guard simply has nothing to say — never a crash.
        with mock.patch(
            "test_timeout_policy.default_overrides_path",
            return_value=Path(self.tmp.name) / "absent.json",
        ):
            self.assertEqual(load_overrides(env={}), {})

    def test_underscore_keys_are_metadata_not_tasks(self):
        path = self._write_json(
            "meta.json",
            {"_format": "doc", "t": {"measured_p95_sec": 5.0, "source": "s"}},
        )
        self.assertEqual(
            list(load_overrides(path=path, env={})), ["t"]
        )

    def test_missing_explicit_path_fails_loud(self):
        with self.assertRaises(ValueError):
            load_overrides(path=os.path.join(self.tmp.name, "nope.json"), env={})

    def test_invalid_entries_fail_loud(self):
        path = os.path.join(self.tmp.name, "bad.json")
        Path(path).write_text("{not json")
        with self.assertRaises(ValueError):
            load_overrides(path=path, env={})
        Path(path).write_text(json.dumps({"t": {"source": "no p95"}}))
        with self.assertRaises(ValueError):
            load_overrides(path=path, env={})
        Path(path).write_text(json.dumps({"t": {"measured_p95_sec": -5.0}}))
        with self.assertRaises(ValueError):
            load_overrides(path=path, env={})

    # -- budget math ------------------------------------------------------
    def test_override_declared_is_p95_times_factor_over_multiplier(self):
        # effective = declared x multiplier >= p95 x 1.5:
        # 360.1 x 1.5 = 540.15 wall; /2 = 270.075 -> 271 declared -> 542s.
        self.assertEqual(override_declared(180.0, None, 360.1, 2.0), 271)

    def test_override_declared_never_lowers_declared(self):
        self.assertEqual(override_declared(600.0, None, 360.1, 2.0), 600.0)

    def test_override_declared_stacks_on_floor(self):
        # The floor raises first; the override only wins when higher.
        self.assertEqual(override_declared(60.0, 120.0, None, 2.0), 120.0)
        self.assertEqual(override_declared(60.0, 120.0, 360.1, 2.0), 271)
        self.assertEqual(override_declared(60.0, 120.0, 100.0, 2.0), 120.0)

    def test_effective_test_seconds(self):
        self.assertEqual(effective_test_seconds(271, 2.0), 542.0)

    def test_effective_below_p95_is_detectable(self):
        # The fairness guard's whole point: floor-only dispatch on the
        # gh-1407 evidence leaves jupyter below its measured p95.
        effective = effective_test_seconds(
            override_declared(180.0, 180.0, None, 2.0), 2.0
        )
        self.assertEqual(effective, 360.0)
        self.assertLess(effective, 360.1)

    # -- yaml rewrite -------------------------------------------------------
    def test_padded_task_yaml_writes_override_as_plain_int(self):
        new, declared, padded = padded_task_yaml(
            TASK_YAML_60, floor=None, p95=360.1, multiplier=2.0
        )
        self.assertEqual(declared, 60.0)
        self.assertEqual(padded, 271)
        self.assertIn("max_test_timeout_sec: 271\n", new)
        self.assertNotIn("271.0", new)
        self.assertIn("max_agent_timeout_sec: 360.0\n", new)

    def test_padded_task_yaml_floor_only_stays_byte_compatible(self):
        new, declared, padded = padded_task_yaml(TASK_YAML_60, floor=120.0)
        self.assertEqual((declared, padded), (60.0, 120.0))
        self.assertEqual(new, TASK_YAML_FLOORED)

    def test_floor_task_yaml_ignores_override_table(self):
        # The legacy entry point stays floor-only by contract.
        new, declared, padded = floor_task_yaml(TASK_YAML_60, 120.0)
        self.assertEqual((declared, padded), (60.0, 120.0))
        self.assertEqual(new, TASK_YAML_FLOORED)


if __name__ == "__main__":
    unittest.main()
