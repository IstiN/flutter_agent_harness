#!/usr/bin/env python3
"""Pins the Bench Harbor dispatch defaults (issue #1316).

AC-first: these fail on the pre-#1316 workflow (4.0 dataset / modal env /
self-hosted runner) and pass after the migration flips the defaults to
Terminal-Bench 2.1 on the default Harbor `docker` sandbox, on ubuntu-latest.
Also pins the legacy `bench.yml` 0.1.1 default (issue #1316 req 6: the tb
1.x path stays untouched) and the adapter wiring the docker default rides
on (env type reaches `harbor run -e`; the #1122 timeout knob contract).

Run: python3 -m unittest discover -s bench/harbor_fa
"""
import re
import unittest
from pathlib import Path

from families import FAMILIES

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_HARBOR_YML = _REPO_ROOT / ".github" / "workflows" / "bench-harbor.yml"
_BENCH_YML = _REPO_ROOT / ".github" / "workflows" / "bench.yml"


def _input_default(workflow_text: str, name: str):
    """Reads `default:` from one workflow_dispatch input block (stdlib)."""
    m = re.search(
        rf"^      {re.escape(name)}:\n((?:        .*\n)+)", workflow_text, re.M
    )
    if not m:
        return None
    d = re.search(r"^\s+default: (.+)$", m.group(1), re.M)
    if not d:
        return None
    return d.group(1).strip().strip("'")


def _workflow_input(workflow_text: str, name: str):
    value = _input_default(workflow_text, name)
    if value is None:
        raise AssertionError(f"input `{name}` has no default in the workflow")
    return value


@unittest.skipUnless(
    _HARBOR_YML.exists(), "bench-harbor.yml not found (standalone bench checkout)"
)
class BenchHarborDefaultsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = _HARBOR_YML.read_text()

    def test_default_dataset_is_terminal_bench_2_1(self):
        # Issue #1316 req 4: default dataset is the 2.1 family; 2.0 (and
        # every other family) stays reachable via the same input.
        self.assertEqual(
            _workflow_input(self.text, "dataset"), FAMILIES["2.1"]
        )

    def test_default_cpu_env_is_docker(self):
        # Issue #1316 req 1: local docker is the default sandbox — no
        # Modal/cloud dependency for the default dispatch.
        self.assertEqual(_workflow_input(self.text, "cpu-env"), "docker")

    def test_default_cpu_runner_is_ubuntu_latest(self):
        # Issue #1316 req 1: GH runners already have docker.
        self.assertEqual(_workflow_input(self.text, "cpu-runner"), "ubuntu-latest")

    def test_adapter_and_timeout_wiring_intact(self):
        # The docker default must actually reach the harbor invocation and
        # the #1122 env contract must stay wired (issue #1316 reqs 2+5).
        self.assertIn('-e "$ENV_TYPE"', self.text)
        self.assertIn("export FA_AGENT_TIMEOUT_SEC", self.text)
        self.assertIn("FA_PROVIDER_TYPE: zai", self.text)


@unittest.skipUnless(
    _BENCH_YML.exists(), "bench.yml not found (standalone bench checkout)"
)
class LegacyBenchUntouchedTest(unittest.TestCase):
    def test_legacy_default_dataset_still_core_0_1_1(self):
        # Issue #1316 req 6: the tb 1.x path keeps running until a separate
        # decision retires it.
        self.assertEqual(
            _workflow_input(_BENCH_YML.read_text(), "dataset"),
            "terminal-bench-core==0.1.1",
        )


if __name__ == "__main__":
    unittest.main()
