#!/usr/bin/env python3
"""UTs for run_shard.py's eval step (gh-1816).

Root cause under test: `programbench eval` defaults to DOCKER_CPUS=10 and
creates every eval container with `docker run --cpus 10`; GH hosted runners
expose 4 CPUs to the docker daemon, which rejects the container
("range of CPUs is from 0.01 to 4.00"), so eval died per instance with
`ERROR: RuntimeError` and never wrote eval.json. The shard driver must cap
programbench at the daemon's own CPU count (PROGRAMBENCH_DOCKER_CPUS).

Evidence gap under test: eval_all() printed only `proc.stdout[-4000:]` and
dropped stderr entirely — the diagnosing traceback (logging writes stderr)
never reached the CI log. The full output must tee into the run dir and the
failure path must surface stderr.

Run: python3 -m unittest discover -s bench/programbench
"""
import contextlib
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

import run_shard


@contextlib.contextmanager
def tempfile_dir():
    d = tempfile.mkdtemp(prefix="pbench-evaltest-")
    try:
        yield Path(d)
    finally:
        shutil.rmtree(d, ignore_errors=True)


def make_shard(tmp: Path) -> run_shard.Shard:
    """A Shard with __init__'s docker/env plumbing bypassed."""
    shard = run_shard.Shard.__new__(run_shard.Shard)
    shard.run_dir = tmp
    shard.eval_workers = 1
    return shard


class FakeProc:
    def __init__(self, stdout: str = "", stderr: str = "", returncode: int = 0):
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = returncode


class EvalDockerCpusTest(unittest.TestCase):
    """gh-1816: eval must run with PROGRAMBENCH_DOCKER_CPUS <= daemon NCPU."""

    def setUp(self):
        self._saved = os.environ.get("PROGRAMBENCH_DOCKER_CPUS")
        os.environ.pop("PROGRAMBENCH_DOCKER_CPUS", None)
        self.calls: list[tuple[list[str], dict]] = []

    def tearDown(self):
        if self._saved is None:
            os.environ.pop("PROGRAMBENCH_DOCKER_CPUS", None)
        else:
            os.environ["PROGRAMBENCH_DOCKER_CPUS"] = self._saved

    def patch_run(self, procs):
        real_run = run_shard.run

        def fake_run(cmd, **kw):
            self.calls.append((list(cmd), kw))
            if cmd[:2] == ["docker", "info"]:
                return procs["info"]
            return procs["eval"]

        run_shard.run = fake_run
        self.addCleanup(setattr, run_shard, "run", real_run)

    def test_eval_caps_cpus_at_daemon_ncpu(self):
        self.patch_run({
            "info": FakeProc(stdout="4\n"),
            "eval": FakeProc(stdout="summary", returncode=0),
        })
        with tempfile_dir() as tmp:
            shard = make_shard(tmp)
            self.assertTrue(shard.eval_all())
        eval_calls = [c for c in self.calls if c[0][0] == "programbench"]
        self.assertEqual(len(eval_calls), 1)
        env = eval_calls[0][1].get("env") or {}
        self.assertEqual(
            env.get("PROGRAMBENCH_DOCKER_CPUS"), "4",
            "eval must pass PROGRAMBENCH_DOCKER_CPUS = docker daemon NCPU",
        )

    def test_eval_respects_preset_cpus_env(self):
        os.environ["PROGRAMBENCH_DOCKER_CPUS"] = "2"
        self.patch_run({
            "info": FakeProc(stdout="4\n"),
            "eval": FakeProc(stdout="", returncode=0),
        })
        with tempfile_dir() as tmp:
            shard = make_shard(tmp)
            self.assertTrue(shard.eval_all())
        eval_calls = [c for c in self.calls if c[0][0] == "programbench"]
        env = eval_calls[0][1].get("env") or {}
        self.assertEqual(env.get("PROGRAMBENCH_DOCKER_CPUS"), "2")

    def test_ncpu_falls_back_to_cpu_count_on_daemon_error(self):
        self.patch_run({
            "info": FakeProc(stderr="cannot connect", returncode=1),
            "eval": FakeProc(stdout="", returncode=0),
        })
        self.assertEqual(run_shard.docker_ncpu(), max(1, os.cpu_count() or 1))

    def test_ncpu_floors_garbage_output_at_one(self):
        self.patch_run({
            "info": FakeProc(stdout="not-a-number\n"),
            "eval": FakeProc(stdout="", returncode=0),
        })
        self.assertGreaterEqual(run_shard.docker_ncpu(), 1)


class EvalOutputTeeTest(unittest.TestCase):
    """gh-1816 evidence gap: full eval stdout+stderr must survive into the
    run dir (rides the shard artifact) and stderr must surface on failure."""

    def setUp(self):
        self._saved = os.environ.get("PROGRAMBENCH_DOCKER_CPUS")
        os.environ["PROGRAMBENCH_DOCKER_CPUS"] = "4"

    def tearDown(self):
        if self._saved is None:
            os.environ.pop("PROGRAMBENCH_DOCKER_CPUS", None)
        else:
            os.environ["PROGRAMBENCH_DOCKER_CPUS"] = self._saved

    def patch_run(self, proc):
        real_run = run_shard.run
        run_shard.run = lambda cmd, **kw: proc
        self.addCleanup(setattr, run_shard, "run", real_run)

    def test_failure_teees_full_output_and_surfaces_stderr(self):
        big_out = "x" * 20000
        trace = "RuntimeError: Failed to start container: range of CPUs ...\n"
        self.patch_run(FakeProc(stdout=big_out, stderr=trace, returncode=1))
        captured = []
        real_write = sys.stdout.write
        sys.stdout.write = lambda s: captured.append(s)
        try:
            with tempfile_dir() as tmp:
                shard = make_shard(tmp)
                self.assertFalse(shard.eval_all())
                tee_out = (tmp / "eval-stdout.log").read_text()
                tee_err = (tmp / "eval-stderr.log").read_text()
        finally:
            sys.stdout.write = real_write
        self.assertEqual(tee_out, big_out, "full stdout must tee into the run dir")
        self.assertEqual(tee_err, trace, "full stderr must tee into the run dir")
        printed = "".join(captured)
        self.assertIn("Failed to start container", printed,
                      "failure path must print the stderr tail (the traceback)")

    def test_success_also_teees_output(self):
        self.patch_run(FakeProc(stdout="all good", stderr="", returncode=0))
        with tempfile_dir() as tmp:
            shard = make_shard(tmp)
            self.assertTrue(shard.eval_all())
            self.assertEqual((tmp / "eval-stdout.log").read_text(), "all good")
            self.assertEqual((tmp / "eval-stderr.log").read_text(), "")


if __name__ == "__main__":
    unittest.main()
