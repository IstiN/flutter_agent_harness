#!/usr/bin/env python3
"""gh-1556 adapter REGs for bench/harbor_fa/fa_agent.py.

Run: python3 -m unittest discover -s bench/harbor_fa

AC1 (pkill self-match): the ladder kill used `pkill -f 'fa --session-root'`
— the exec wrapper's OWN cmdline contains the pattern, so pkill SIGTERMed
its own shell (exit 143); the exception skipped the audit write AND the
TimeoutError, and harbor recorded ladder kills as agent crashes (TB 2.0
run 38150649548: a SOLVED task scored 0). The command now uses the `[f]a`
bracket trick and the kill is wrapped so its failure can never replace the
ladder's TimeoutError.

AC2/Class C (progress-watch default): the harbor adapter now picks the
gap-aware ProgressWatch when a watch knob is set — parity with the
terminal-bench adapter — instead of always running the retired byte-growth
ladder.

AC7 (deadline wiring): the run exports FA_DEADLINE_EPOCH_MS (effective cap
minus a wrap-up margin) to the fa session env and audits the exact value in
/fa-timeout-metadata.json; no knobs => no export.

These run against a stdlib stub of the harbor surface (the REAL-module
integration tests need `pip install harbor`, as in the bench workflow).
"""
import asyncio
import base64
import dataclasses
import importlib.util
import json
import os
import sys
import time
import types
import unittest
from pathlib import Path
from unittest import mock

_REPO_BENCH = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO_BENCH))

import fa_agent_timeout  # noqa: E402

_KNOB_NAMES = (
    "FA_AGENT_TIMEOUT_SEC",
    "FA_PROGRESS_EXTENSION",
    "FA_AGENT_IDLE_WINDOW_SEC",
    "FA_AGENT_CEILING_MULTIPLIER",
    "FA_STALL_GAP_SEC",
    "FA_AGENT_TIMEOUT_ABS_CEILING_SEC",
)

_AGENT_LAUNCH_SNIPPET = "fa --session-root /logs/agent/fah-sessions -p"


def _clean_env(**overrides):
    env = {k: v for k, v in os.environ.items() if k not in _KNOB_NAMES}
    env.update(overrides)
    return mock.patch.dict(os.environ, env, clear=True)


def _install_harbor_stubs():
    """Minimal harbor surface for fa_agent.py's imports (stdlib only)."""
    def module(name):
        mod = types.ModuleType(name)
        mod.__fa_harbor_stub__ = True
        sys.modules[name] = mod
        return mod

    harbor = module("harbor")
    harbor.__path__ = []
    agents = module("harbor.agents")
    harbor.agents = agents
    agents.__path__ = []
    installed = module("harbor.agents.installed")
    agents.installed = installed
    installed.__path__ = []
    installed_base = module("harbor.agents.installed.base")
    installed.base = installed_base

    class BaseInstalledAgent:
        # gh-1592: FaAgent's ERROR_PATTERNS override filters this table;
        # the stub stays minimal (empty — the anchored-pattern semantics
        # are pinned against the real package in test_error_classifier.py).
        ERROR_PATTERNS = []

        def __init__(self, **kwargs):
            self._version = None

    @dataclasses.dataclass
    class ErrorPattern:
        pattern: str
        exception: type

    class ApiRateLimitError(RuntimeError):
        pass

    installed_base.BaseInstalledAgent = BaseInstalledAgent
    installed_base.ErrorPattern = ErrorPattern
    installed_base.ApiRateLimitError = ApiRateLimitError
    environments = module("harbor.environments")
    harbor.environments = environments
    environments.__path__ = []
    env_base = module("harbor.environments.base")
    environments.base = env_base

    class BaseEnvironment:
        pass

    env_base.BaseEnvironment = BaseEnvironment
    models = module("harbor.models")
    harbor.models = models
    models.__path__ = []
    models_agent = module("harbor.models.agent")
    models.agent = models_agent
    models_agent.__path__ = []
    context = module("harbor.models.agent.context")
    models_agent.context = context
    context.AgentContext = dict


_install_harbor_stubs()

_spec = importlib.util.spec_from_file_location(
    "fa_agent_harbor", Path(__file__).resolve().parent / "fa_agent.py"
)
fa_agent = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fa_agent)


class _ExecResult:
    def __init__(self, stdout=""):
        self.return_code = 0
        self.stdout = stdout


class FakeAgent(fa_agent.FaAgent):
    """FaAgent with scripted exec_as_agent/exec_as_root.

    The agent launch hangs until the kill lands (fa dying on SIGTERM); the
    kill sets `killed` even when scripted to fail — the pre-fix bug was the
    pkill's OWN exit-143 propagating, not fa surviving.
    """

    def __init__(self, fail_pkill=False):
        self._version = None
        self.fail_pkill = fail_pkill
        self.root_calls = []
        self.launch_env = None
        self.killed = None
        self.audit_payload = None

    async def exec_as_root(self, environment, command=None, timeout_sec=None, env=None):
        self.root_calls.append(command)
        if "pkill" in command:
            self.killed.set()
            if self.fail_pkill:
                raise RuntimeError(
                    "Command failed (exit 143): pkill -f 'fa --session-root' || true"
                )
        return _ExecResult()

    async def exec_as_agent(self, environment, command=None, env=None, timeout_sec=None):
        if _AGENT_LAUNCH_SNIPPET in command:
            self.launch_env = env
            self.killed = asyncio.Event()
            await self.killed.wait()
            return _ExecResult()
        if command.startswith("wc -c") or command.startswith("if p=$(wc -c"):
            return _ExecResult("10 0")
        if "printf %s" in command:
            payload = command.split("printf %s ", 1)[1].split(" ", 1)[0]
            self.audit_payload = json.loads(base64.b64decode(payload))
            return _ExecResult()
        return _ExecResult()


class _FastWatch:
    """ProgressWatch stand-in that kills on the first sample."""

    constructed = []

    def __init__(self, knobs):
        self.knobs = knobs
        self.kill_at = 0.0
        self.last_progress_at = 0.0
        self.last_bytes = 0
        self.events = []
        _FastWatch.constructed.append(self)

    def evaluate(self, elapsed, output_bytes=None):
        return "abs_ceiling"


class HarborKillPathTest(unittest.TestCase):
    def setUp(self):
        self._env = _clean_env(
            FA_AGENT_TIMEOUT_SEC="1",
            FA_PROVIDER_CONFIG=json.dumps({"apiKeyEnvVar": "FA_KEY_FAKE"}),
            FA_KEY_FAKE="secret",
        )
        self._env.start()
        self.addCleanup(self._env.stop)

    def _run_deadline(self, agent, instruction="do the task"):
        return agent._run_with_deadline(
            fa_agent_timeout.TimeoutKnobs.from_env(),
            instruction,
            environment=object(),
        )

    def test_kill_command_uses_bracket_trick(self):
        # AC1: the kill must not match its own wrapper's cmdline.
        agent = FakeAgent()
        with self.assertRaises(asyncio.TimeoutError):
            asyncio.run(self._run_deadline(agent))
        pkill_calls = [c for c in agent.root_calls if "pkill" in c]
        self.assertEqual(len(pkill_calls), 1)
        self.assertIn("pkill -f '[f]a --session-root'", pkill_calls[0])
        self.assertNotIn("pkill -f 'fa --session-root'", pkill_calls[0])

    def test_self_matching_pkill_still_timeout_with_audit(self):
        # AC1 REG: the exact TB 2.0 Class-A failure — pkill exits 143
        # (self-match) — must NOT escape: the trial still classifies as a
        # ladder timeout AND the audit record is still written.
        agent = FakeAgent(fail_pkill=True)
        with self.assertRaises(asyncio.TimeoutError) as ctx:
            asyncio.run(self._run_deadline(agent))
        self.assertIn("bench timeout ladder", str(ctx.exception))
        self.assertIsNotNone(agent.audit_payload)
        self.assertEqual(agent.audit_payload["outcome"], "stall")

    def test_audit_written_on_kill_and_records_deadline(self):
        # AC7: the fa-visible deadline is audited next to the knobs; the
        # flat 1s cap clamps to the 30s minimal wrap-up window.
        agent = FakeAgent()
        before_ms = int(time.time() * 1000)
        with self.assertRaises(asyncio.TimeoutError):
            asyncio.run(self._run_deadline(agent))
        after_ms = int(time.time() * 1000)
        self.assertEqual(agent.audit_payload["outcome"], "stall")
        deadline = agent.audit_payload["deadline_epoch_ms"]
        self.assertGreaterEqual(deadline, before_ms + 30_000)
        self.assertLessEqual(deadline, after_ms + 31_000)
        # The launch env carries the SAME deadline fa steers by.
        self.assertEqual(
            agent.launch_env["FA_DEADLINE_EPOCH_MS"], str(deadline)
        )

    def test_watch_mode_is_the_default_decider(self):
        # AC2/Class C: with a watch knob set (the bench-harbor.yml
        # default), the kill decision is ProgressWatch, not the retired
        # byte-growth ladder, and the audit names the progress-watch
        # policy with the effective watch knobs + deadline.
        _FastWatch.constructed = []
        env = fa_agent_timeout.TimeoutKnobs.from_env(
            {
                "FA_PROGRESS_EXTENSION": "1",
                "FA_STALL_GAP_SEC": "360",
                "FA_AGENT_TIMEOUT_ABS_CEILING_SEC": "3600",
            }
        )
        self.assertTrue(env.progress_watch)
        agent = FakeAgent()
        with mock.patch.object(fa_agent_timeout, "ProgressWatch", _FastWatch):
            with self.assertRaises(asyncio.TimeoutError):
                asyncio.run(agent._run_with_deadline(env, "task", object()))
        self.assertEqual(len(_FastWatch.constructed), 1)
        self.assertEqual(agent.audit_payload["policy"], "progress-watch")
        self.assertEqual(agent.audit_payload["knobs"]["stall_gap_sec"], 360.0)
        self.assertEqual(agent.audit_payload["knobs"]["abs_ceiling_sec"], 3600.0)
        # Deadline = 3600s cap - 120s margin from the run's start.
        self.assertIn("deadline_epoch_ms", agent.audit_payload)
        self.assertEqual(
            agent.launch_env["FA_DEADLINE_EPOCH_MS"],
            str(agent.audit_payload["deadline_epoch_ms"]),
        )

    def test_legacy_ladder_still_reachable_without_watch_knobs(self):
        # REG: watch knobs absent -> the round-2 byte-for-byte ladder
        # (flat-cap policy here: no extension flag).
        _FastWatch.constructed = []
        env = fa_agent_timeout.TimeoutKnobs.from_env({"FA_AGENT_TIMEOUT_SEC": "1"})
        agent = FakeAgent()
        with mock.patch.object(fa_agent_timeout, "ProgressWatch", _FastWatch):
            with self.assertRaises(asyncio.TimeoutError):
                asyncio.run(agent._run_with_deadline(env, "task", object()))
        self.assertEqual(_FastWatch.constructed, [])
        self.assertEqual(agent.audit_payload["policy"], "flat-cap")


class NoKnobsDelegationTest(unittest.TestCase):
    def test_no_knobs_single_exec_and_no_deadline(self):
        # No knobs => today's single awaited exec, unsupervised, and NO
        # FA_DEADLINE_EPOCH_MS export (the dataset caps are harbor's own;
        # fa never invents a clock).
        env = _clean_env(
            FA_PROVIDER_CONFIG=json.dumps({"apiKeyEnvVar": "FA_KEY_FAKE"}),
            FA_KEY_FAKE="secret",
        )
        env.start()
        self.addCleanup(env.stop)
        agent = FakeAgent()
        calls = []

        async def fake_exec(environment, command=None, env=None, timeout_sec=None):
            calls.append((command, env))
            return _ExecResult()

        agent.exec_as_agent = fake_exec
        asyncio.run(agent.run("instruction", object(), {}))
        self.assertEqual(len(calls), 1)
        self.assertNotIn("FA_DEADLINE_EPOCH_MS", calls[0][1])
        self.assertIsNone(agent.audit_payload)


if __name__ == "__main__":
    unittest.main()
