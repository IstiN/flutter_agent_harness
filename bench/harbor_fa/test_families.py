#!/usr/bin/env python3
"""Unit tests for families.py (issue #1124). Run: python3 -m unittest discover -s bench/harbor_fa"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from families import FAMILIES, SMOKE_TASKS, TASK_COUNTS, FamilyError, resolve

SCRIPT = str(Path(__file__).parent / "families.py")


class ManifestTest(unittest.TestCase):
    def test_ids_verified_against_harbor_hub(self):
        # OQ1 (2026-09-30): 4.0/3.0 are tags on the terminal-bench package;
        # the 2.x sets live under separate package names, whose only tag is
        # 'latest'. A change here means the Hub moved — re-verify before
        # editing.
        self.assertEqual(FAMILIES, {
            "2.0": "terminal-bench/terminal-bench-2@latest",
            "2.1": "terminal-bench/terminal-bench-2-1@latest",
            "3.0": "terminal-bench/terminal-bench@3.0.0",
            "4.0": "terminal-bench/terminal-bench@4.0.0",
        })

    def test_every_family_has_smoke_and_count(self):
        self.assertEqual(set(FAMILIES), set(SMOKE_TASKS))
        self.assertEqual(set(FAMILIES), set(TASK_COUNTS))
        for count in TASK_COUNTS.values():
            self.assertGreater(count, 0)


class ResolveTest(unittest.TestCase):
    def test_each_family_resolves_its_dataset(self):
        for label, expected in FAMILIES.items():
            self.assertEqual(resolve(label), (label, expected))

    def test_full_id_and_bare_version_forms(self):
        self.assertEqual(
            resolve("terminal-bench/terminal-bench@4.0.0"),
            ("4.0", "terminal-bench/terminal-bench@4.0.0"),
        )
        self.assertEqual(resolve("4.0.0"), ("4.0", FAMILIES["4.0"]))
        self.assertEqual(resolve("v2.1"), ("2.1", FAMILIES["2.1"]))
        self.assertEqual(resolve("3"), ("3.0", FAMILIES["3.0"]))

    def test_default_4_0_id_unchanged(self):
        # AC4: the workflow default dispatches today's 4.0 run exactly.
        self.assertEqual(FAMILIES["4.0"], "terminal-bench/terminal-bench@4.0.0")

    def test_canonical_ids_round_trip(self):
        # Copy the dataset id a run printed, paste it into the next
        # dispatch — works for every family, incl. the @latest 2.x sets.
        for label, dataset in FAMILIES.items():
            self.assertEqual(resolve(dataset), (label, dataset))

    def test_unknown_version_errors_loudly(self):
        with self.assertRaises(FamilyError) as ctx:
            resolve("terminal-bench/terminal-bench@2.2.0")
        msg = str(ctx.exception)
        self.assertIn("2.2.0", msg)
        for label in FAMILIES:
            self.assertIn(label, msg)

    def test_error_message_is_single_line_annotation_safe(self):
        # The spec comes from a dispatch input and lands in a ::error::
        # annotation: whitespace runs (incl. newlines) must collapse so
        # the injected text cannot start its own annotation line, and the
        # spec stays embedded verbatim-in-quotes (collapsed) for triage.
        with self.assertRaises(FamilyError) as ctx:
            resolve("terminal-bench/terminal-bench@9.9\n::warning::forged")
        msg = str(ctx.exception)
        self.assertNotIn("\n", msg)
        self.assertIn("'terminal-bench/terminal-bench@9.9 ::warning::forged'", msg)

    def test_version_less_spec_never_falls_back(self):
        with self.assertRaises(FamilyError):
            resolve("terminal-bench/terminal-bench")
        with self.assertRaises(FamilyError):
            resolve("")

    def test_out_of_family_slug_errors(self):
        # Real Hub dataset, but not one of the pinned family ids.
        with self.assertRaises(FamilyError):
            resolve("terminal-bench/terminal-bench-cpu-only@4.0.0")

    def test_card_assumed_2_1_id_is_rejected_with_pointer(self):
        # The issue card assumed terminal-bench@2.1.0 on one slug; the Hub
        # keeps 2.1 at terminal-bench-2-1. The wrong id must fail loudly.
        with self.assertRaises(FamilyError) as ctx:
            resolve("terminal-bench/terminal-bench@2.1.0")
        self.assertIn("terminal-bench-2-1@latest", str(ctx.exception))


class CliTest(unittest.TestCase):
    def _run(self, *args, env_extra=None):
        env = dict(os.environ)
        env.pop("GITHUB_OUTPUT", None)
        env.update(env_extra or {})
        return subprocess.run(
            [sys.executable, SCRIPT, *args],
            capture_output=True, text=True, env=env, check=False,
        )

    def test_resolve_stdout(self):
        p = self._run("resolve", "2.1")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("family=2.1", p.stdout)
        self.assertIn("dataset=terminal-bench/terminal-bench-2-1@latest", p.stdout)
        self.assertIn("tasks=89", p.stdout)
        self.assertIn("smoke=fix-git", p.stdout)

    def test_unknown_errors_loudly(self):
        p = self._run("resolve", "terminal-bench/terminal-bench@9.9")
        self.assertEqual(p.returncode, 1)
        self.assertIn("::error::", p.stderr)
        self.assertIn("9.9", p.stderr)

    def test_github_output_emitted(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "github-output"
            p = self._run("resolve", "4.0.0", env_extra={"GITHUB_OUTPUT": str(out)})
            self.assertEqual(p.returncode, 0, p.stderr)
            lines = (out.read_text().splitlines())
            self.assertIn("family=4.0", lines)
            self.assertIn("dataset=terminal-bench/terminal-bench@4.0.0", lines)
            self.assertIn("tasks=66", lines)
            self.assertIn("smoke=bun-sourcemap-leak", lines)


if __name__ == "__main__":
    unittest.main()
