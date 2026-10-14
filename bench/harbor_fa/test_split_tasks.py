#!/usr/bin/env python3
"""Tests for split_tasks.py's gh-1576 external-cap discovery.

The workflow must resolve each shard task's declared agent timeout
(task.toml `[agent] timeout_sec`) BEFORE launch and export it as
FA_EXTERNAL_CAP_SEC — the harbor per-task timeout is otherwise invisible
to the adapter (pinned negative fact: the kill arrives as a wait_for
TimeoutError). One env value bounds a whole shard, so the conservative
truth is the MIN across the shard's tasks: fa's deadline can then never
outlive any task's harness kill (invariant I1).

Run: python3 -m unittest discover -s bench/harbor_fa
"""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

from split_tasks import _agent_timeout_sec, _cap_str, _shard_cap, main


def _task(dir_path: Path, name: str, toml: str) -> None:
    task_dir = dir_path / name
    task_dir.mkdir(parents=True)
    (task_dir / "task.toml").write_text(toml)


_TASK_TMPL = """\
schema_version = "1.1"
[task]
name = "org/{name}"

[agent]
{agent_block}

[environment]
gpus = 0
"""

_GPU_TASK_TMPL = """\
schema_version = "1.1"
[task]
name = "org/{name}"

[agent]
timeout_sec = 5400.0

[environment]
gpus = 1
"""


class AgentTimeoutParseTest(unittest.TestCase):
    def test_declared_timeout_parsed(self):
        self.assertEqual(_agent_timeout_sec({"agent": {"timeout_sec": 1800.0}}), 1800.0)
        self.assertEqual(_agent_timeout_sec({"agent": {"timeout_sec": 600}}), 600.0)

    def test_undeclared_or_malformed_is_unknown(self):
        # E1: no cap is ever invented; AC8: malformed never crashes.
        self.assertIsNone(_agent_timeout_sec({}))
        self.assertIsNone(_agent_timeout_sec({"agent": {}}))
        self.assertIsNone(_agent_timeout_sec({"agent": {"timeout_sec": None}}))
        self.assertIsNone(_agent_timeout_sec({"agent": {"timeout_sec": "soon"}}))
        self.assertIsNone(_agent_timeout_sec({"agent": {"timeout_sec": 0}}))
        self.assertIsNone(_agent_timeout_sec({"agent": {"timeout_sec": -5}}))
        # A bool is an int subclass — never a cap.
        self.assertIsNone(_agent_timeout_sec({"agent": {"timeout_sec": True}}))


class ShardCapTest(unittest.TestCase):
    def test_min_across_shard_tasks(self):
        # One env value bounds the shard: the smallest declared cap wins.
        caps = {"a": 1800.0, "b": 3600.0, "c": None}
        self.assertEqual(_shard_cap(caps, ["a", "b", "c"]), 1800.0)

    def test_undeclared_tasks_do_not_constrain(self):
        self.assertEqual(_shard_cap({"a": None, "b": 900.0}, ["a", "b"]), 900.0)

    def test_no_declared_cap_is_none(self):
        # AC5/E1: no invented clock — the workflow exports nothing.
        self.assertIsNone(_shard_cap({"a": None}, ["a"]))

    def test_cap_str_normalizes_integral_floats(self):
        self.assertEqual(_cap_str(1800.0), "1800")
        self.assertEqual(_cap_str(1800.5), "1800.5")
        self.assertEqual(_cap_str(None), "")


class SplitCapEmissionTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dataset = Path(tmp.name)
        _task(self.dataset, "video-task", _TASK_TMPL.format(
            name="video-task", agent_block="timeout_sec = 1800.0"))
        _task(self.dataset, "quick-task", _TASK_TMPL.format(
            name="quick-task", agent_block="timeout_sec = 600"))
        _task(self.dataset, "no-cap-task", _TASK_TMPL.format(
            name="no-cap-task", agent_block=""))
        _task(self.dataset, "gpu-task", _GPU_TASK_TMPL.format(name="gpu-task"))

    def _run(self, *cli: str) -> dict:
        """Runs split_tasks.main, capturing GITHUB_OUTPUT and stdout."""
        output = Path(self.dataset) / "github_output"
        if output.exists():
            output.unlink()
        argv = sys.argv
        env = os.environ.get("GITHUB_OUTPUT")
        sys.argv = ["split_tasks.py", str(self.dataset), *cli]
        os.environ["GITHUB_OUTPUT"] = str(output)
        try:
            with contextlib.redirect_stdout(io.StringIO()) as stdout:
                code = main()
        finally:
            sys.argv = argv
            if env is None:
                os.environ.pop("GITHUB_OUTPUT", None)
            else:
                os.environ["GITHUB_OUTPUT"] = env
        self.assertEqual(code, 0, stdout.getvalue())
        text = stdout.getvalue()
        if output.exists():
            text += "\n" + output.read_text()
        result = {}
        for line in text.splitlines():
            key, _, value = line.partition("=")
            if key:
                # shell-quoting (CPU_TASKS="...") vs plain GITHUB_OUTPUT.
                result[key] = value.strip('"')
        return result

    def _include(self, result: dict) -> list:
        return json.loads(result["matrix"])["include"]

    def test_per_shard_external_cap_in_the_matrix(self):
        # 3 CPU tasks in 2 shards: shard 0 = (no-cap, quick) exports their
        # min (600); shard 1 = (video) alone exports 1800. The gpu shard
        # exports its own declared cap.
        include = self._include(self._run(
            "--shards", "2", "--cpu-env", "docker",
        ))
        caps = {e["i"]: e.get("external_cap") for e in include}
        self.assertEqual(caps[0], "600")
        self.assertEqual(caps[1], "1800")

    def test_gpu_shard_declared_cap_flows(self):
        gpu = next(
            e for e in self._include(self._run(
                "--shards", "8", "--cpu-env", "docker",
            )) if e["kind"] == "gpu"
        )
        self.assertEqual(gpu["external_cap"], "5400")

    def test_shard_without_declared_caps_has_no_cap_key(self):
        include = self._include(self._run(
            "--filter", "no-cap-task", "--shards", "2",
            "--cpu-env", "docker", "--task-prefix", "org/",
        ))
        self.assertEqual(len(include), 1)
        self.assertNotIn("external_cap", include[0])

    def test_non_shard_mode_prints_caps(self):
        result = self._run()
        self.assertEqual(result.get("CPU_CAP"), "600")
        self.assertEqual(result.get("GPU_CAP"), "5400")


if __name__ == "__main__":
    unittest.main()
