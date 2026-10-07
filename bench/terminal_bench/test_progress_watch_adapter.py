#!/usr/bin/env python3
"""Round-3 adapter ITs (issue #1392 AC1/AC2/AC3/AC7 adapter side).

Run: python3 -m unittest discover -s bench/terminal_bench

These run against a minimal stdlib stub of the terminal_bench surface
fa_agent.py imports (the REAL-module integration tests are
test_fa_agent_timeout.py's, which skip where terminal-bench is not
installed). The stub pins only the four names the adapter touches, so the
deadline-loop behavior under the gap-aware ProgressWatch is testable
anywhere python3 runs.
"""
import base64
import importlib.util
import json
import os
import sys
import tempfile
import threading
import time
import types
import unittest
from contextlib import redirect_stderr
from io import StringIO
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import fa_agent_timeout
from fa_agent_timeout import TimeoutKnobs


def _importable(name: str) -> bool:
    try:
        importlib.import_module(name)
        return True
    except ImportError:
        return False


TB_AVAILABLE = _importable("terminal_bench.agents.base_agent")

KNOB_NAMES = (
    "FA_AGENT_TIMEOUT_SEC",
    "FA_PROGRESS_EXTENSION",
    "FA_AGENT_IDLE_WINDOW_SEC",
    "FA_AGENT_CEILING_MULTIPLIER",
    "FA_STALL_GAP_SEC",
    "FA_AGENT_TIMEOUT_ABS_CEILING_SEC",
)


def clean_env(**overrides):
    env = {name: value for name, value in os.environ.items() if name not in KNOB_NAMES}
    env.update(overrides)
    return env


def _install_tb_stubs():
    """Minimal terminal_bench surface for fa_agent.py's imports."""
    if TB_AVAILABLE:
        return
    def module(name):
        mod = types.ModuleType(name)
        mod.__fa_tb_stub__ = True
        sys.modules[name] = mod
        return mod
    tb = module("terminal_bench")
    agents = module("terminal_bench.agents")
    tb.agents = agents
    agents.__path__ = []
    base = module("terminal_bench.agents.base_agent")
    agents.base_agent = base

    class AgentResult:
        def __init__(self, total_input_tokens=0, total_output_tokens=0,
                     failure_mode=None, timestamped_markers=None):
            self.total_input_tokens = total_input_tokens
            self.total_output_tokens = total_output_tokens
            self.failure_mode = failure_mode
            self.timestamped_markers = timestamped_markers or []

    base.AgentResult = AgentResult
    failure = module("terminal_bench.agents.failure_mode")
    agents.failure_mode = failure

    class FailureMode:
        AGENT_TIMEOUT = "agent_timeout"
        AGENT_INSTALLATION_FAILED = "agent_installation_failed"
        UNKNOWN_AGENT_ERROR = "unknown_agent_error"

    failure.FailureMode = FailureMode
    installed = module("terminal_bench.agents.installed_agents")
    agents.installed_agents = installed
    installed.__path__ = []
    abstract = module("terminal_bench.agents.installed_agents.abstract_installed_agent")
    installed.abstract_installed_agent = abstract

    class AbstractInstalledAgent:
        def __init__(self, **kwargs):
            self._version = None

        def _get_templated_script_path(self, name):
            return Path(name)

        def perform_task(self, instruction, session, logging_dir=None):
            raise NotImplementedError

    abstract.AbstractInstalledAgent = AbstractInstalledAgent
    terminal = module("terminal_bench.terminal")
    tb.terminal = terminal
    terminal.__path__ = []
    models = module("terminal_bench.terminal.models")
    terminal.models = models

    class TerminalCommand:
        def __init__(self, **kwargs):
            self.__dict__.update(kwargs)

    models.TerminalCommand = TerminalCommand


_install_tb_stubs()

_ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("fa_agent_r3", _ROOT / "terminal_bench" / "fa_agent.py")
fa_agent = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fa_agent)


class FakeContainer:
    """exec_run surface: byte counter, pane buffer, trace file, snapshot."""

    def __init__(self):
        self.pane = []           # str chunks appended by the fake agent
        self.trace_file = ""     # container-side FA_CONN trace file content
        self.snapshot = None     # container-side payload snapshot JSON text

    def exec_run(self, cmd, **kwargs):
        joined = " ".join(cmd) if isinstance(cmd, list) else str(cmd)
        if "wc -c" in joined:
            total = sum(len(chunk) for chunk in self.pane)
            return types.SimpleNamespace(exit_code=0, output=f"{total}\n".encode())
        if "tail -c +" in joined:
            start = int(joined.split("+")[1].split()[0])  # tail -c +N is 1-based
            data = "".join(self.pane)[start - 1:]
            return types.SimpleNamespace(exit_code=0, output=data.encode())
        if "cat /tmp/fa-conn-trace.jsonl" in joined and self.trace_file:
            return types.SimpleNamespace(exit_code=0, output=self.trace_file.encode())
        if "cat /tmp/fa-conn-snapshot.jsonl" in joined:
            return types.SimpleNamespace(exit_code=0, output=b"")
        if "cat /tmp/fa-conn-snapshot.json" in joined and self.snapshot:
            return types.SimpleNamespace(exit_code=0, output=self.snapshot.encode())
        return types.SimpleNamespace(exit_code=0, output=b"")


class FakeSession:
    def __init__(self):
        self.container = FakeContainer()
        self.sent = []
        self.interrupted = threading.Event()

    def copy_to_container(self, *args, **kwargs):
        pass

    def send_keys(self, keys, **kwargs):
        self.sent.append(keys)
        if "C-c" in keys:
            self.interrupted.set()


class Round3AdapterTest(unittest.TestCase):
    """Adapter ITs against the gap-aware watch (issue #1392)."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)

    def _agent(self):
        tarball = Path(self.tmpdir.name) / "fa-bundle.tar.gz"
        tarball.write_bytes(b"")
        with mock.patch.dict(os.environ, {"FA_BUNDLE_TARBALL": str(tarball)}):
            return fa_agent.FaAgent()

    def _run(self, session, stock, logging_dir, env, poll=0.05):
        agent = self._agent()

        def with_stock(self_agent, instruction, session, logging_dir=None):
            return stock(session=session)

        stderr = StringIO()
        with mock.patch.dict(os.environ, env), mock.patch.object(
            fa_agent, "_POLL_SEC", poll
        ), mock.patch.object(
            fa_agent.AbstractInstalledAgent, "perform_task", with_stock
        ), redirect_stderr(stderr):
            result = agent.perform_task("instr", session, logging_dir)
        return result, stderr.getvalue()

    def test_progressing_agent_completes_past_legacy_ceiling(self):
        # AC1 IT: steady output keeps the watch frozen; the run completes.
        session = FakeSession()
        logging_dir = Path(self.tmpdir.name) / "trial-dir"

        def stock(session):
            for _ in range(20):
                time.sleep(0.03)
                session.container.pane.append("x" * 100)
            return "stock-result"

        env = clean_env(
            FA_AGENT_TIMEOUT_SEC="0.3",
            FA_PROGRESS_EXTENSION="1",
            FA_STALL_GAP_SEC="240",
        )
        result, _ = self._run(session, stock, logging_dir, env)
        self.assertEqual(result, "stock-result")
        self.assertFalse(session.interrupted.is_set())
        audit = json.loads((logging_dir / "fa-agent-timeout.json").read_text())
        self.assertEqual(audit["policy"], "progress-watch")
        self.assertEqual(audit["outcome"], "completed")
        # bench_metrics.json (AC2): every trial dir carries one.
        metrics = json.loads((logging_dir / "bench_metrics.json").read_text())
        self.assertEqual(metrics["trial"], "trial-dir")
        self.assertIn("latency", metrics)
        self.assertIn("watchdog_events", metrics)
        self.assertIn("requests", metrics)

    def test_stalled_agent_captures_hang_payload_and_dies(self):
        # AC3 IT: a stall verdict captures hang-*.json BEFORE the kill.
        session = FakeSession()
        logging_dir = Path(self.tmpdir.name) / "trial-dir"
        session.container.pane.append("x" * 50)  # some progress, then silence
        session.container.snapshot = json.dumps(
            {"method": "POST", "url": "https://x/v1", "body": "{}"}
        )

        def stock(session):
            session.interrupted.wait(30)  # a truly stuck agent
            return "late"

        env = clean_env(
            FA_AGENT_TIMEOUT_SEC="30",
            FA_PROGRESS_EXTENSION="1",
            FA_STALL_GAP_SEC="0.3",
            FA_AGENT_IDLE_WINDOW_SEC="0.1",
        )
        started = time.monotonic()
        result, stderr = self._run(session, stock, logging_dir, env)
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 10.0, "the stall must die at the gap boundary")
        self.assertEqual(result.failure_mode, fa_agent.FailureMode.AGENT_TIMEOUT)
        self.assertIn("agent_timeout(stall)", result.timestamped_markers[0][1])
        hangs = list(logging_dir.glob("hang-*.json"))
        self.assertEqual(len(hangs), 1, stderr)
        hang = json.loads(hangs[0].read_text())
        self.assertEqual(hang["payload"]["method"], "POST")
        self.assertGreaterEqual(hang["gap_sec"], 0.3)
        self.assertEqual(hang["replay"], "scripts/replay_hang.sh <this-file>")
        audit = json.loads((logging_dir / "fa-agent-timeout.json").read_text())
        self.assertEqual(audit["outcome"], "stall")

    def test_live_progress_lines_stream_to_stderr(self):
        # AC2 live-line contract: FA_CONN pane events render as [fa-bench]
        # lines flushed while the run is still going.
        session = FakeSession()
        logging_dir = Path(self.tmpdir.name) / "trial-dir"
        session.container.pane.append(
            'FA_CONN {"event":"first_byte","seq":3,"wallSec":213.0,'
            '"slow":true,"fresh":false,"localPort":54321,"poolSize":2,'
            '"connAgeSec":912.0}\n'
        )

        def stock(session):
            for _ in range(8):
                time.sleep(0.03)
                session.container.pane.append("x" * 10)
            return "stock-result"

        env = clean_env(
            FA_AGENT_TIMEOUT_SEC="0.2",
            FA_PROGRESS_EXTENSION="1",
            FA_STALL_GAP_SEC="240",
        )
        _, stderr = self._run(session, stock, logging_dir, env)
        self.assertIn(
            "[fa-bench] req#3 first byte after 213s ⚠ (reused, pool=2, "
            "port=54321)",
            stderr,
        )
        # The event also folded into the trial metrics.
        metrics = json.loads((logging_dir / "bench_metrics.json").read_text())
        self.assertEqual(len(metrics["requests"]), 1)
        self.assertEqual(metrics["latency"]["first_byte"]["max"], 213.0)

    def test_container_trace_file_wins_over_pane_events(self):
        # The cleaner container-side ConnTrace file is preferred; the pane
        # parse is the fallback.
        session = FakeSession()
        logging_dir = Path(self.tmpdir.name) / "trial-dir"
        session.container.trace_file = (
            'FA_CONN {"event":"first_byte","seq":9,"wallSec":5.0,'
            '"slow":false,"fresh":true,"localPort":777,"poolSize":1,'
            '"connAgeSec":0.0}\n'
        )

        def stock(session):
            time.sleep(0.05)
            return "stock-result"

        env = clean_env(
            FA_AGENT_TIMEOUT_SEC="0.5",
            FA_STALL_GAP_SEC="240",
        )
        _, stderr = self._run(session, stock, logging_dir, env)
        metrics = json.loads((logging_dir / "bench_metrics.json").read_text())
        self.assertEqual(metrics["requests"][0]["local_port"], 777)
        self.assertEqual(metrics["concurrency_level"], None)

    def test_export_guard_row_on_empty_export(self):
        # AC7 adapter side: output but zero exported files -> ok=false row.
        session = FakeSession()
        logging_dir = Path(self.tmpdir.name) / "trial-dir"
        session.container.pane.append("x" * 50)

        def stock(session):
            time.sleep(0.1)
            return "stock-result"

        env = clean_env(FA_AGENT_TIMEOUT_SEC="0.5", FA_STALL_GAP_SEC="240")
        result, stderr = self._run(session, stock, logging_dir, env)
        self.assertEqual(result, "stock-result")
        guard = json.loads((logging_dir / "export-guard.json").read_text())
        self.assertEqual(guard["session_records"], 1)
        self.assertEqual(guard["export_files"], 0)
        self.assertFalse(guard["ok"])
        self.assertIn("EXPORT GUARD", stderr)

    def test_conn_env_vars_forwarded_into_container(self):
        agent = self._agent()
        env = clean_env(
            FA_PROVIDER_CONFIG="{}",
            FA_CONN_DEBUG="1",
            FA_CONN_TRACE_FILE="/tmp/fa-conn-trace.jsonl",
            FA_BENCH_CONCURRENCY="2",
        )
        with mock.patch.dict(os.environ, env, clear=False):
            payload = agent._env
        self.assertEqual(
            base64.b64decode(payload["FA_CONN_DEBUG_BASE64"]).decode(), "1"
        )
        self.assertEqual(
            base64.b64decode(payload["FA_CONN_TRACE_FILE_BASE64"]).decode(),
            "/tmp/fa-conn-trace.jsonl",
        )
        self.assertEqual(
            base64.b64decode(payload["FA_BENCH_CONCURRENCY_BASE64"]).decode(),
            "2",
        )


if __name__ == "__main__":
    unittest.main()
