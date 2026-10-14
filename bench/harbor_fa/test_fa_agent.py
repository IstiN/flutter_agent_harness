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
import signal
import sys
import threading
import time
import warnings
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
    # gh-1576: the external harness cap — stripped so a host-exported cap
    # cannot leak into a test pinning the no-cap byte-identity.
    "FA_EXTERNAL_CAP_SEC",
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
    pkill's OWN exit-143 propagating, not fa surviving. `launch_delay`
    turns the launch into a natural completion after that many seconds,
    and `counter` makes the progress samples grow (gh-1576 checkpoints).
    """

    def __init__(self, fail_pkill=False, launch_delay=None, counter=None,
                 launch_error=None):
        self._version = None
        self.fail_pkill = fail_pkill
        self.launch_delay = launch_delay
        self.launch_error = launch_error
        self.counter = counter
        self.root_calls = []
        self.launch_env = None
        self.killed = None
        self.audit_payload = None
        self.audit_payloads = []

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
            if self.launch_error is not None:
                # The crashed-exec shape (e.g. harbor's
                # NonZeroAgentExitCodeError after a non-zero fa exit).
                raise self.launch_error
            if self.launch_delay is not None:
                await asyncio.sleep(self.launch_delay)
                return _ExecResult()
            await self.killed.wait()
            return _ExecResult()
        if command.startswith("wc -c"):
            value = self.counter["bytes"] if self.counter else 10
            return _ExecResult(str(value))
        if command.startswith("if p=$(wc -c"):
            value = self.counter["bytes"] if self.counter else 10
            return _ExecResult(f"{value} 0")
        if "printf %s" in command:
            payload = command.split("printf %s ", 1)[1].split(" ", 1)[0]
            self.audit_payload = json.loads(base64.b64decode(payload))
            self.audit_payloads.append(self.audit_payload)
            return _ExecResult()
        return _ExecResult()


class _FastWatch:
    """ProgressWatch stand-in that kills on the first sample."""

    constructed = []

    def __init__(self, knobs, external_cap_sec=None):
        self.knobs = knobs
        self.external_cap_sec = external_cap_sec
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
        # AC7: the fa-visible deadline is audited next to the knobs. The
        # flat 1s cap sits under the 30s min-remaining window: gh-1576 E7
        # clamps the deadline to start + cap (zero margin) — the old clamp
        # projected a 30s clock over a 1s guillotine, exactly the lying-
        # clock class this card kills (I1: never later than the kill).
        agent = FakeAgent()
        before_ms = int(time.time() * 1000)
        with self.assertRaises(asyncio.TimeoutError):
            asyncio.run(self._run_deadline(agent))
        after_ms = int(time.time() * 1000)
        self.assertEqual(agent.audit_payload["outcome"], "stall")
        deadline = agent.audit_payload["deadline_epoch_ms"]
        self.assertGreaterEqual(deadline, before_ms + 1_000)
        self.assertLessEqual(deadline, after_ms + 1_000 + 50)
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


class ExternalCapAdapterTest(unittest.TestCase):
    """IT-1 (gh-1576 AC1/AC2): the external cap reaches the adapter's
    deadline and the audit — the incident fix, on the fake-harbor surface.
    """

    WATCH_ENV = {
        "FA_PROGRESS_EXTENSION": "1",
        "FA_STALL_GAP_SEC": "360",
        "FA_AGENT_TIMEOUT_ABS_CEILING_SEC": "3600",
    }

    def setUp(self):
        env = dict(self.WATCH_ENV)
        env.update(
            {
                "FA_EXTERNAL_CAP_SEC": "1800",
                "FA_PROVIDER_CONFIG": json.dumps({"apiKeyEnvVar": "FA_KEY_FAKE"}),
                "FA_KEY_FAKE": "secret",
            }
        )
        self._env = _clean_env(**env)
        self._env.start()
        self.addCleanup(self._env.stop)

    def _knobs(self):
        return fa_agent_timeout.TimeoutKnobs.from_env()

    def test_it1_deadline_is_external_cap_minus_margin(self):
        # AC1: external 1800s vs knob ceiling 3600s — the launch env that
        # reaches fa projects 1800 - 120 (wrap-up margin) = 1680s.
        agent = FakeAgent(launch_delay=0.05)
        before_ms = int(time.time() * 1000)
        asyncio.run(agent._run_with_deadline(self._knobs(), "task", object()))
        after_ms = int(time.time() * 1000)
        deadline = int(agent.launch_env["FA_DEADLINE_EPOCH_MS"])
        self.assertGreaterEqual(deadline, before_ms + 1_679_000)
        self.assertLessEqual(deadline, after_ms + 1_681_000)

    def test_it1_audit_names_external_as_winning_source(self):
        # AC2: the audit record names the winning source and BOTH inputs.
        agent = FakeAgent(launch_delay=0.05)
        asyncio.run(agent._run_with_deadline(self._knobs(), "task", object()))
        payload = agent.audit_payload
        self.assertEqual(payload["outcome"], "completed")
        resolved = payload["cap_resolution"]
        self.assertEqual(resolved["winning_cap_source"], "external")
        self.assertEqual(resolved["external_cap_sec"], 1800.0)
        self.assertEqual(resolved["external_cap_status"], "known")
        self.assertEqual(resolved["knob_cap_sec"], 3600.0)
        self.assertEqual(resolved["effective_cap_sec"], 1800.0)
        self.assertEqual(
            payload["deadline_epoch_ms"],
            int(agent.launch_env["FA_DEADLINE_EPOCH_MS"]),
        )

    def test_it3_cancel_writes_external_kill_audit(self):
        # AC4/IT-3: harbor's wait_for kill arrives as a cancellation of
        # run() — the audit must STILL be flushed, outcome external_kill,
        # with the deadline fa actually saw (the incident's missing file).
        agent = FakeAgent()

        async def scenario():
            task = asyncio.create_task(
                agent._run_with_deadline(self._knobs(), "task", object())
            )
            await asyncio.sleep(0.1)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task

        asyncio.run(scenario())
        payload = agent.audit_payload
        self.assertIsNotNone(payload)
        self.assertEqual(payload["outcome"], "external_kill")
        self.assertEqual(payload["external_kill"]["cause"], "cancelled")
        self.assertEqual(
            payload["deadline_epoch_ms"],
            int(agent.launch_env["FA_DEADLINE_EPOCH_MS"]),
        )

    def test_it3_sigterm_handler_flushes_external_kill_audit(self):
        # IT-3: the installed handler dispatches the flush for every
        # attached trial (previous=None in the test = no re-signal chain).
        if threading.current_thread() is not threading.main_thread():
            self.skipTest("signal handlers need the main thread")
        agent = FakeAgent()
        agent._run_environment = object()  # the supervised run stashes it
        loop = asyncio.new_event_loop()
        try:
            self.assertTrue(
                fa_agent._hold_signal_auditor(agent, signal.SIGTERM, loop)
            )
            fa_agent._dispatch_external_kill("SIGTERM", loop, None)
            loop.run_until_complete(asyncio.sleep(0.2))
        finally:
            fa_agent._release_signal_auditor(agent, signal.SIGTERM, loop)
            loop.close()
        killed = [
            p
            for p in agent.audit_payloads
            if p.get("outcome") == "external_kill"
            and p.get("external_kill", {}).get("signal") == "SIGTERM"
        ]
        self.assertEqual(len(killed), 1, agent.audit_payloads)

    def test_it3_incremental_checkpoints_from_first_sample(self):
        # IT-3/E3: the audit is written incrementally — a partial marker
        # exists from the first progress sample, before any kill.
        agent = FakeAgent(counter={"bytes": 10})
        with mock.patch.object(fa_agent, "_POLL_SEC", 0.05):

            async def scenario():
                task = asyncio.create_task(
                    agent._run_with_deadline(self._knobs(), "task", object())
                )
                await asyncio.sleep(0.12)
                agent.counter["bytes"] = 500  # the next sample makes progress
                await asyncio.sleep(0.12)
                task.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await task

            asyncio.run(scenario())
        checkpoints = [p for p in agent.audit_payloads if p.get("checkpoint")]
        self.assertGreaterEqual(len(checkpoints), 2, agent.audit_payloads)
        self.assertEqual(checkpoints[0]["outcome"], "running")
        # The last checkpoint predates the final external_kill flush.
        self.assertEqual(agent.audit_payloads[-1]["outcome"], "external_kill")

    def test_malformed_cap_degrades_to_knobs_only(self):
        # AC8/UT-3 on the adapter surface: a garbage cap is a warning +
        # knobs-only deadline, never a crash, and the audit says rejected.
        agent = FakeAgent(launch_delay=0.05)
        with mock.patch.dict(os.environ, {"FA_EXTERNAL_CAP_SEC": "soon"}):
            with warnings.catch_warnings(record=True) as caught:
                warnings.simplefilter("always")
                with mock.patch.object(fa_agent, "_POLL_SEC", 0.05):
                    asyncio.run(
                        agent._run_with_deadline(self._knobs(), "task", object())
                    )
        self.assertTrue(any("FA_EXTERNAL_CAP_SEC" in str(w.message) for w in caught))
        deadline = int(agent.launch_env["FA_DEADLINE_EPOCH_MS"])
        # Knob ceiling 3600 - 120s margin — NOT derived from the garbage.
        self.assertGreaterEqual(deadline, int(time.time() * 1000) + 3_479_000)
        resolved = agent.audit_payload["cap_resolution"]
        self.assertEqual(resolved["external_cap_status"], "rejected")
        self.assertEqual(resolved["winning_cap_source"], "knobs")


class ExternalCapOnlyRunTest(unittest.TestCase):
    """gh-1576: a known external cap with NO adapter knobs — the adapter
    does not supervise (the harness owns the kill) but fa still learns the
    true budget and every termination still lands the audit (I2)."""

    def setUp(self):
        env = _clean_env(
            FA_EXTERNAL_CAP_SEC="1800",
            FA_PROVIDER_CONFIG=json.dumps({"apiKeyEnvVar": "FA_KEY_FAKE"}),
            FA_KEY_FAKE="secret",
        )
        env.start()
        self.addCleanup(env.stop)

    def test_deadline_exported_and_completion_audited(self):
        agent = FakeAgent(launch_delay=0.05)
        before_ms = int(time.time() * 1000)
        asyncio.run(agent.run("instruction", object(), {}))
        deadline = int(agent.launch_env["FA_DEADLINE_EPOCH_MS"])
        self.assertGreaterEqual(deadline, before_ms + 1_679_000)
        payload = agent.audit_payload
        self.assertEqual(payload["outcome"], "completed")
        self.assertEqual(payload["policy"], "external-cap")
        self.assertNotIn("knobs", payload)
        self.assertEqual(payload["cap_resolution"]["winning_cap_source"], "external")

    def test_cancel_still_leaves_the_external_kill_audit(self):
        agent = FakeAgent()

        async def scenario():
            task = asyncio.create_task(agent.run("instruction", object(), {}))
            await asyncio.sleep(0.1)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task

        asyncio.run(scenario())
        self.assertIsNotNone(agent.audit_payload)
        self.assertEqual(agent.audit_payload["outcome"], "external_kill")

    def test_crashed_exec_still_leaves_the_audit(self):
        # I2: every termination leaves the audit. A crashed exec (e.g.
        # harbor's NonZeroAgentExitCodeError after a non-zero fa exit) on
        # this path used to propagate without writing anything — exactly
        # the "the kill came from outside, the audit writer never ran" gap
        # this card exists to close (review round 2). Mirrors the
        # supervised sibling's `crashed` handling.
        agent = FakeAgent(launch_error=RuntimeError("NonZeroAgentExitCodeError: 1"))
        with self.assertRaises(RuntimeError):
            asyncio.run(agent.run("instruction", object(), {}))
        payload = agent.audit_payload
        self.assertIsNotNone(payload, agent.audit_payloads)
        self.assertEqual(payload["outcome"], "crashed")
        self.assertEqual(payload["policy"], "external-cap")
        self.assertEqual(payload["cap_resolution"]["winning_cap_source"], "external")

    def test_no_cap_no_knobs_stays_byte_identical(self):
        # AC5/REG-2: without the cap env the unsupervised path exports
        # nothing and writes no audit — exactly today's behavior.
        env = _clean_env(
            FA_PROVIDER_CONFIG=json.dumps({"apiKeyEnvVar": "FA_KEY_FAKE"}),
            FA_KEY_FAKE="secret",
        )
        env.start()
        self.addCleanup(env.stop)
        agent = FakeAgent(launch_delay=0.05)
        asyncio.run(agent.run("instruction", object(), {}))
        self.assertNotIn("FA_DEADLINE_EPOCH_MS", agent.launch_env)
        self.assertIsNone(agent.audit_payload)


class SignalLifecycleTest(unittest.TestCase):
    """Review round 2 (`PRRT_kwDOTXdlLc6sD_xd`): the SIGTERM/SIGINT audit
    handler must honor the process's signal lifecycle.

    - the captured `previous` disposition is RESTORED by the teardown —
      `loop.remove_signal_handler` alone leaves SIG_DFL behind, so a later
      process-level SIGTERM would bypass harbor's graceful handling for
      the rest of the process;
    - a disposition we cannot faithfully restore (another loop's
      add_signal_handler registration, seen as `signal._sighandler_noop`)
      is never stolen — skipping the install is safe (the cancel-path
      flush still covers I2), half-restoring is not;
    - overlapping trials (`--n-concurrent` > 1) share ONE holder: the
      first release must not strip the handler a live trial still needs;
      the last release restores.
    """

    WATCH_ENV = {
        "FA_PROGRESS_EXTENSION": "1",
        "FA_STALL_GAP_SEC": "360",
        "FA_AGENT_TIMEOUT_ABS_CEILING_SEC": "3600",
        "FA_PROVIDER_CONFIG": '{"apiKeyEnvVar": "FA_KEY_FAKE"}',
        "FA_KEY_FAKE": "secret",
    }

    def setUp(self):
        env = _clean_env(**self.WATCH_ENV)
        env.start()
        self.addCleanup(env.stop)

    def _noop_sentinel(self):
        """The disposition another loop's add_signal_handler installs."""
        unix_events = getattr(asyncio, "unix_events", None)
        return (
            getattr(signal, "sighandler_noop", None)
            or getattr(unix_events, "_sighandler_noop", None)
        )

    def test_kill_auditors_restore_the_captured_disposition(self):
        if threading.current_thread() is not threading.main_thread():
            self.skipTest("signal handlers need the main thread")
        recorder = mock.Mock(name="harbor_sigterm_handler")
        original = signal.getsignal(signal.SIGTERM)
        signal.signal(signal.SIGTERM, recorder)
        try:
            agent = FakeAgent(launch_delay=0.1)
            with mock.patch.object(fa_agent, "_POLL_SEC", 0.05):
                asyncio.run(
                    agent._run_with_deadline(
                        fa_agent_timeout.TimeoutKnobs.from_env(), "task", object()
                    )
                )
            self.assertIs(signal.getsignal(signal.SIGTERM), recorder)
        finally:
            signal.signal(signal.SIGTERM, original)

    def test_kill_auditors_skip_a_disposition_they_cannot_restore(self):
        if threading.current_thread() is not threading.main_thread():
            self.skipTest("signal handlers need the main thread")
        # Simulate harbor's own loop-level registration: the process
        # disposition becomes the noop sentinel, which we cannot restore.
        original = signal.getsignal(signal.SIGTERM)
        outer = asyncio.new_event_loop()
        try:
            outer.add_signal_handler(signal.SIGTERM, lambda: None)
            noop = signal.getsignal(signal.SIGTERM)
            self.assertIs(noop, self._noop_sentinel())
            agent = FakeAgent(launch_delay=0.05)

            async def scenario():
                await agent._run_with_deadline(
                    fa_agent_timeout.TimeoutKnobs.from_env(), "task", object()
                )

            with mock.patch.object(fa_agent, "_POLL_SEC", 0.05):
                asyncio.run(scenario())
            # Not stolen: still the other loop's noop disposition, and
            # the natural-completion audit still landed (I2 unaffected).
            self.assertIs(signal.getsignal(signal.SIGTERM), noop)
            self.assertIsNotNone(agent.audit_payload)
            self.assertEqual(agent.audit_payload["outcome"], "completed")
        finally:
            outer.remove_signal_handler(signal.SIGTERM)
            outer.close()
            signal.signal(signal.SIGTERM, original)

    def test_overlapping_trials_share_one_disposition(self):
        if threading.current_thread() is not threading.main_thread():
            self.skipTest("signal handlers need the main thread")
        original = signal.getsignal(signal.SIGTERM)
        self.assertIs(original, signal.SIG_DFL)  # the state this pins on
        noop = self._noop_sentinel()
        a = FakeAgent(launch_delay=0.25)
        b = FakeAgent(launch_delay=0.5)

        async def scenario():
            ta = asyncio.create_task(
                a._run_with_deadline(
                    fa_agent_timeout.TimeoutKnobs.from_env(), "task", object()
                )
            )
            tb = asyncio.create_task(
                b._run_with_deadline(
                    fa_agent_timeout.TimeoutKnobs.from_env(), "task", object()
                )
            )
            await asyncio.sleep(0.1)
            during = signal.getsignal(signal.SIGTERM)
            await ta
            after_first = signal.getsignal(signal.SIGTERM)  # b still live
            await tb
            after_last = signal.getsignal(signal.SIGTERM)
            return during, after_first, after_last

        try:
            with mock.patch.object(fa_agent, "_POLL_SEC", 0.05):
                during, after_first, after_last = asyncio.run(scenario())
            self.assertIs(during, noop)  # installed while both run
            # The first release must NOT strip the handler the live
            # trial still holds (the pre-fix per-trial remove did).
            self.assertIs(after_first, noop)
            self.assertIs(after_last, signal.SIG_DFL)  # last release restores
        finally:
            signal.signal(signal.SIGTERM, original)

    def test_dispatch_flushes_every_live_trial_then_rehonors(self):
        # One process handler serves every live trial: the dispatch
        # flushes EACH attached agent's audit, and only after the last
        # write lands is the captured disposition restored and the
        # signal re-delivered (the process still dies; the audits
        # outlive the race). This also pins the _rehonor chain the
        # round-1 tests left uncovered (every test passed previous=None).
        if threading.current_thread() is not threading.main_thread():
            self.skipTest("signal handlers need the main thread")
        original = signal.getsignal(signal.SIGTERM)
        loop = asyncio.new_event_loop()
        a, b = FakeAgent(), FakeAgent()
        a._run_environment = object()
        b._run_environment = object()
        try:
            for agent in (a, b):
                self.assertTrue(
                    fa_agent._hold_signal_auditor(agent, signal.SIGTERM, loop)
                )
            recorder = mock.Mock(name="harbor_sigterm_handler")
            with mock.patch.object(signal, "signal") as fake_signal, \
                    mock.patch.object(os, "kill") as fake_kill:
                fa_agent._dispatch_external_kill("SIGTERM", loop, recorder)
                loop.run_until_complete(asyncio.sleep(0.3))
            killed = [
                p for p in (*a.audit_payloads, *b.audit_payloads)
                if p.get("outcome") == "external_kill"
                and p.get("external_kill", {}).get("signal") == "SIGTERM"
            ]
            self.assertEqual(len(killed), 2, (a.audit_payloads, b.audit_payloads))
            fake_signal.assert_called_once_with(signal.SIGTERM, recorder)
            fake_kill.assert_called_once_with(os.getpid(), signal.SIGTERM)
        finally:
            for agent in (a, b):
                fa_agent._release_signal_auditor(agent, signal.SIGTERM, loop)
            loop.close()
            signal.signal(signal.SIGTERM, original)


if __name__ == "__main__":
    unittest.main()
