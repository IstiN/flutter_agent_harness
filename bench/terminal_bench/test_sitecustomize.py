#!/usr/bin/env python3
"""Unit tests for sitecustomize.py — tb compose-failure logging (gh-1208).

Run: python3 -m unittest discover -s bench/terminal_bench
The real-module test skips when terminal_bench is not installed; the rest
run anywhere (pure stdlib).
"""
import contextlib
import importlib.util
import io
import logging
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

# Load our sitecustomize.py explicitly by path: python startups may already
# have a SYSTEM sitecustomize in sys.modules (Debian ships one at
# /usr/lib/python3.x/sitecustomize.py), which would shadow ours on a plain
# `import sitecustomize`. Production is unaffected — PYTHONPATH entries
# precede stdlib dirs, so the tb interpreter imports ours at startup.
_MODULE_PATH = Path(__file__).resolve().parent / "sitecustomize.py"


def _load_sitecustomize():
    spec = importlib.util.spec_from_file_location("bench_sitecustomize", _MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # runs install(), like interpreter startup
    return module


sitecustomize = _load_sitecustomize()

TARGET = "terminal_bench.terminal.docker_compose_manager"

LOG_NAME = "sitecustomize-test"


def _importable(name):
    # importlib.import_module, not find_spec: with bench/terminal_bench on
    # sys.path (unittest discover), the bench directory itself matches as a
    # namespace package and false-positives (see test_fa_agent_timeout.py).
    try:
        __import__(name)
        return True
    except ImportError:
        return False


class FakeSelf:
    """Just enough of DockerComposeManager for the patched method to run."""

    _logger = logging.getLogger(LOG_NAME)
    env = {}

    def get_docker_compose_command(self, command):
        return ["docker", "compose", *command]


def _module_with(original):
    """A stand-in terminal_bench.terminal.docker_compose_manager module."""

    class FakeManager:
        _run_docker_compose_command = original

    module = type(sys)("fake_docker_compose_manager")
    module.DockerComposeManager = FakeManager
    return module, FakeManager


class InstallTest(unittest.TestCase):
    def _hooks(self):
        return [
            f
            for f in sys.meta_path
            if getattr(f, "fa_bench_compose_hook", False)
        ]

    def _strip_hooks(self):
        sys.meta_path[:] = [
            f for f in sys.meta_path if not getattr(f, "fa_bench_compose_hook", False)
        ]

    def tearDown(self):
        self._strip_hooks()
        sitecustomize._installed = False

    def test_fresh_module_exec_installs_hook_once(self):
        self._strip_hooks()
        sitecustomize._installed = False
        fresh = _load_sitecustomize()  # exec runs install(), like startup
        self.assertTrue(fresh._installed)
        self.assertEqual(len(self._hooks()), 1)
        # second install is a no-op
        self.assertFalse(fresh.install())
        self.assertEqual(len(self._hooks()), 1)

    def test_opt_out_disables(self):
        self._strip_hooks()
        sitecustomize._installed = False
        env = dict(os.environ, FA_TB_LOG_COMPOSE_FAILURES="0")
        with mock.patch.dict(os.environ, env, clear=True):
            self.assertFalse(sitecustomize.install())
        self.assertEqual(len(self._hooks()), 0)


class TailCapTest(unittest.TestCase):
    def test_caps_long_output(self):
        text = "x" * (sitecustomize._TAIL_CAP + 10)
        out = sitecustomize._tail(text)
        self.assertLess(len(out), len(text))
        self.assertIn("truncated", out)

    def test_passthrough_and_none(self):
        self.assertEqual(sitecustomize._tail("short"), "short")
        self.assertEqual(sitecustomize._tail(None), "")


class PatchTest(unittest.TestCase):
    """Drive _patch directly — no docker, no tb import needed."""

    def test_failure_logs_captured_output_and_reraises(self):
        error = subprocess.CalledProcessError(
            128, "docker compose build", output="OUT-MARKER", stderr="ERR-MARKER"
        )

        def original(self, command):
            raise error

        module, manager = _module_with(original)
        sitecustomize._patch(module)
        wrapped = manager._run_docker_compose_command
        self.assertIsNot(wrapped, original)
        with self.assertLogs(LOG_NAME, level="ERROR") as captured:
            with self.assertRaises(subprocess.CalledProcessError):
                wrapped(FakeSelf(), ["build"])
        text = "\n".join(captured.output)
        for needle in ("ERR-MARKER", "OUT-MARKER", "build", "128"):
            self.assertIn(needle, text)

    def test_success_passthrough_untouched(self):
        def original(self, command):
            return f"ok:{list(command)}"

        module, manager = _module_with(original)
        sitecustomize._patch(module)
        self.assertEqual(
            manager._run_docker_compose_command(FakeSelf(), ["up", "-d"]),
            "ok:['up', '-d']",
        )

    def test_silent_failure_without_captured_output(self):
        def original(self, command):
            raise subprocess.CalledProcessError(1, "docker compose build")

        module, manager = _module_with(original)
        sitecustomize._patch(module)
        with self.assertNoLogs(LOG_NAME, level="ERROR"):
            with self.assertRaises(subprocess.CalledProcessError):
                manager._run_docker_compose_command(FakeSelf(), ["build"])

    def test_api_drift_warns_without_raising(self):
        module = type(sys)("fake_docker_compose_manager")  # no DockerComposeManager
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            sitecustomize._patch(module)  # must not raise
        self.assertIn("compose failure logging disabled", buf.getvalue())


@unittest.skipUnless(_importable(TARGET), "terminal_bench not installed")
class RealModuleTest(unittest.TestCase):
    """The hook must patch tb's real DockerComposeManager on first import."""

    def setUp(self):
        sys.meta_path[:] = [
            f
            for f in sys.meta_path
            if not getattr(f, "fa_bench_compose_hook", False)
        ]
        sitecustomize._installed = False
        self.assertTrue(sitecustomize.install())
        # drop a possibly-cached import so the hook actually fires, exactly
        # like the production flow (hook installed before the first import)
        sys.modules.pop(TARGET, None)

    def tearDown(self):
        sys.meta_path[:] = [
            f
            for f in sys.meta_path
            if not getattr(f, "fa_bench_compose_hook", False)
        ]
        sitecustomize._installed = False

    def test_real_manager_gets_patched_on_import(self):
        module = importlib.import_module(TARGET)
        manager = module.DockerComposeManager
        self.assertEqual(manager._run_docker_compose_command.__name__, "logged_run")

        # and it must log captured output on failure without swallowing it
        with mock.patch(
            "subprocess.run",
            side_effect=subprocess.CalledProcessError(
                1, "docker compose build", stderr="BOOM: base image gone"
            ),
        ):
            with self.assertLogs(LOG_NAME, level="ERROR") as captured:
                with self.assertRaises(subprocess.CalledProcessError):
                    manager._run_docker_compose_command(FakeSelf(), ["build"])
        self.assertIn("BOOM: base image gone", "\n".join(captured.output))


if __name__ == "__main__":
    unittest.main()
