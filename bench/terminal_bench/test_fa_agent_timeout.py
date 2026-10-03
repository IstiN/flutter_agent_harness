#!/usr/bin/env python3
"""Unit tests for the bench agent-timeout ladder (issue #1122).

Run: python3 -m unittest discover -s bench/terminal_bench
The adapter-level tests skip when terminal_bench / harbor is not installed;
the ladder tests run anywhere (pure stdlib shared module).
"""
import asyncio
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
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import fa_agent_timeout
from fa_agent_timeout import ProgressLadder, TimeoutKnobs, audit_dict

def _importable(name: str) -> bool:
    # find_spec is not enough: with bench/terminal_bench on sys.path (as
    # unittest discover does), find_spec("terminal_bench") matches the
    # DIRECTORY itself as a namespace package and false-positives.
    try:
        importlib.import_module(name)
        return True
    except ImportError:
        return False


TB_AVAILABLE = _importable("terminal_bench.agents.base_agent")
HARBOR_AVAILABLE = _importable("harbor")

KNOB_NAMES = (
    "FA_AGENT_TIMEOUT_SEC",
    "FA_PROGRESS_EXTENSION",
    "FA_AGENT_IDLE_WINDOW_SEC",
    "FA_AGENT_CEILING_MULTIPLIER",
)


def clean_env(**overrides):
    env = {name: value for name, value in os.environ.items() if name not in KNOB_NAMES}
    env.update(overrides)
    return env


class KnobParsingTest(unittest.TestCase):
    """UT-1 / AC3: input plumbing — absent = no takeover, flag = effective cap."""

    def test_absent_knobs_means_no_takeover(self):
        self.assertIsNone(TimeoutKnobs.from_env(clean_env()))

    def test_empty_string_counts_as_absent(self):
        # workflow_dispatch inputs default to '' and still land in the env.
        env = clean_env(FA_AGENT_TIMEOUT_SEC="", FA_PROGRESS_EXTENSION="")
        self.assertIsNone(TimeoutKnobs.from_env(env))

    def test_any_knob_activates_with_defaults(self):
        knobs = TimeoutKnobs.from_env(clean_env(FA_PROGRESS_EXTENSION="1"))
        self.assertEqual(knobs.base_sec, 360.0)  # absent input = 360s base
        self.assertTrue(knobs.progress_extension)
        self.assertEqual(knobs.idle_window_sec, 120.0)
        self.assertEqual(knobs.ceiling_multiplier, 4.0)
        self.assertEqual(knobs.ceiling_sec, 1440.0)

    def test_agent_timeout_flag_sets_effective_cap(self):
        knobs = TimeoutKnobs.from_env(clean_env(FA_AGENT_TIMEOUT_SEC="600"))
        self.assertEqual(knobs.base_sec, 600.0)
        self.assertFalse(knobs.progress_extension)

    def test_garbage_value_fails_loud(self):
        with self.assertRaises(ValueError):
            TimeoutKnobs.from_env(clean_env(FA_AGENT_TIMEOUT_SEC="six minutes"))

    def test_nonpositive_value_fails_loud(self):
        with self.assertRaises(ValueError):
            TimeoutKnobs.from_env(clean_env(FA_AGENT_TIMEOUT_SEC="0"))

    def test_nonfinite_value_fails_loud(self):
        # inf/nan parse as float - reject them explicitly (round-1 thread 5)
        for bad in ("inf", "nan", "-inf"):
            with self.assertRaises(ValueError):
                TimeoutKnobs.from_env(clean_env(FA_AGENT_TIMEOUT_SEC=bad))
            with self.assertRaises(ValueError):
                TimeoutKnobs.from_env(
                    clean_env(FA_AGENT_CEILING_MULTIPLIER=bad)
                )

    def test_flag_garbage_fails_loud_and_zero_is_explicit_off(self):
        # round-2 thread 1: a mistyped flag must not silently disable
        # the extension.
        with self.assertRaises(ValueError):
            TimeoutKnobs.from_env(
                clean_env(
                    FA_AGENT_TIMEOUT_SEC="600", FA_PROGRESS_EXTENSION="maybe"
                )
            )
        knobs = TimeoutKnobs.from_env(
            clean_env(FA_AGENT_TIMEOUT_SEC="600", FA_PROGRESS_EXTENSION="0")
        )
        self.assertFalse(knobs.progress_extension)  # explicit off, cap on


class LadderTest(unittest.TestCase):
    """Ladder semantics; times are seconds elapsed since the agent started."""

    @staticmethod
    def knobs(base=360.0, extension=False, window=120.0, mult=4.0):
        return TimeoutKnobs(
            base_sec=base,
            progress_extension=extension,
            idle_window_sec=window,
            ceiling_multiplier=mult,
        )

    def test_silent_agent_dies_at_base_cap(self):
        # AC2 regression pin: zero events => kill at the base cap, exactly
        # as today's flat guillotine.
        ladder = ProgressLadder(self.knobs())
        self.assertIsNone(ladder.evaluate(359.9, 0))
        self.assertEqual(ladder.evaluate(360.0, 0), "stall")
        self.assertEqual(ladder.kill_at, 360.0)

    def test_stall_uses_last_progress_plus_window(self):
        ladder = ProgressLadder(self.knobs(base=360.0, extension=True))
        ladder.evaluate(300.0, 1000)  # progress until t=300
        self.assertIsNone(ladder.evaluate(419.9, 1000))
        self.assertEqual(ladder.evaluate(420.0, 1000), "stall")

    def test_extension_recedes_deadline_while_events_flow(self):
        # AC1: steady activity survives past the base cap.
        ladder = ProgressLadder(self.knobs(base=360.0, extension=True))
        for t in (100.0, 200.0, 361.0, 500.0):
            self.assertIsNone(ladder.evaluate(t, t * 100), f"survive at t={t}")
        # pushes only recorded once they exceed the standing deadline
        self.assertEqual(len(ladder.events), 2)
        self.assertGreater(ladder.kill_at, 500.0)

    def test_hard_cap_overrides_extensions(self):
        # E2: a gigantic task dies loudly at the ceiling, distinct reason.
        ladder = ProgressLadder(self.knobs(base=360.0, extension=True, mult=4.0))
        t = 0.0
        while t < 1439.0:
            self.assertIsNone(ladder.evaluate(t, t * 100))
            t += 60.0
        self.assertEqual(ladder.evaluate(1440.0, 144000), "hard-ceiling")
        self.assertEqual(ladder.kill_at, 1440.0)

    def test_flat_cap_ignores_events_when_extension_disabled(self):
        ladder = ProgressLadder(self.knobs(base=360.0, extension=False))
        self.assertIsNone(ladder.evaluate(359.0, 50_000))
        self.assertEqual(ladder.evaluate(360.0, 50_000), "stall")
        self.assertEqual(ladder.events, [])

    def test_unreadable_sample_keeps_previous_progress(self):
        # A failed wc poll must not reset the stall clock.
        ladder = ProgressLadder(self.knobs(base=200.0, extension=True))
        ladder.evaluate(100.0, 500)
        self.assertIsNone(ladder.evaluate(219.9, None))
        self.assertEqual(ladder.evaluate(220.0, None), "stall")

    def test_single_multiplier_ceiling_never_shadows_stall_reason(self):
        # ceiling == base: a death at base is a stall, not a hard ceiling.
        ladder = ProgressLadder(self.knobs(base=360.0, extension=True, mult=1.0))
        self.assertEqual(ladder.evaluate(360.0, 0), "stall")


class AuditTest(unittest.TestCase):
    """UT-2 / AC4: extension decisions recorded for the trial artifact."""

    def test_audit_payload_documents_what_when_why(self):
        knobs = TimeoutKnobs(base_sec=360.0, progress_extension=True)
        ladder = ProgressLadder(knobs)
        ladder.evaluate(300.0, 4000)  # push 360 -> 420 — recorded
        ladder.evaluate(430.0, 0)  # then silence past the (pushed) deadline
        payload = audit_dict(knobs, ladder, "stall")
        self.assertEqual(payload["outcome"], "stall")
        self.assertEqual(payload["policy"], "progress-aware")
        self.assertEqual(payload["knobs"]["ceiling_sec"], 1440.0)
        self.assertEqual(payload["deadline_sec"], 420.0)
        self.assertEqual(
            payload["extensions"],
            [{"at_sec": 300.0, "output_bytes": 4000, "deadline_sec": 420.0}],
        )
        self.assertEqual(json.loads(json.dumps(payload)), payload)

    def test_audit_marks_flat_policy(self):
        knobs = TimeoutKnobs(base_sec=600.0)
        payload = audit_dict(knobs, ProgressLadder(knobs), "completed")
        self.assertEqual(payload["policy"], "flat-cap")
        self.assertEqual(payload["knobs"]["base_sec"], 600.0)

    def test_audit_documents_liveness_inflation_when_measured(self):
        # AC6 (issue #1185): with a readable progress stream the audit
        # carries the sample size and the ⏳ share the pane counter
        # counted as progress.
        knobs = TimeoutKnobs(base_sec=600.0)
        payload = audit_dict(
            knobs,
            ProgressLadder(knobs),
            "completed",
            progress_bytes=1000,
            liveness_bytes=120,
        )
        self.assertEqual(payload["progress_sample_bytes"], 1000)
        self.assertEqual(payload["progress_liveness_bytes"], 120)
        self.assertIn("#1185", payload["progress_note"])
        self.assertEqual(json.loads(json.dumps(payload)), payload)

    def test_audit_omits_liveness_fields_when_stream_unreadable(self):
        # None propagates: an unreadable stream never fabricates zeroes.
        knobs = TimeoutKnobs(base_sec=600.0)
        payload = audit_dict(knobs, ProgressLadder(knobs), "completed")
        self.assertNotIn("progress_sample_bytes", payload)
        self.assertNotIn("progress_liveness_bytes", payload)
        self.assertNotIn("progress_note", payload)


class LivenessBytesTest(unittest.TestCase):
    """AC6 (issue #1185): the ⏳ share of a progress stream, in bytes."""

    def test_counts_only_liveness_lines_with_newlines(self):
        stream = (
            "assistant text\n"
            "⏳ [bash] sleep 500 — running 60s\n"
            "✓ bash · 61s\n"
            "⏳ [bash] sleep 500 — running 120s\n"
        )
        measured = fa_agent_timeout.liveness_bytes_of(stream)
        expected = sum(
            len(line.encode("utf-8")) + 1
            for line in stream.split("\n")
            if "⏳" in line
        )
        self.assertEqual(measured, expected)
        self.assertGreater(measured, 0)

    def test_crlf_unterminated_and_control_bytes_count_exactly(self):
        # CRLF: the \r belongs to the line and is counted (splitlines()
        # would drop it — 1 byte under per line).
        crlf = "⏳ a\r\nplain\n"
        self.assertEqual(
            fa_agent_timeout.liveness_bytes_of(crlf),
            len("⏳ a\r".encode("utf-8")) + 1,
        )
        # A final unterminated ⏳ line counts without a newline.
        self.assertEqual(
            fa_agent_timeout.liveness_bytes_of("plain\n⏳ b"),
            len("⏳ b".encode("utf-8")),
        )
        # A stray vertical tab no longer splits phantom lines.
        self.assertEqual(
            fa_agent_timeout.liveness_bytes_of("⏳ a\x0bb\n"),
            len("⏳ a\x0bb\n".encode("utf-8")),
        )

    def test_accepts_bytes_and_propagates_none(self):
        self.assertEqual(
            fa_agent_timeout.liveness_bytes_of("⏳ x\n".encode("utf-8")),
            len("⏳ x\n".encode("utf-8")),
        )
        self.assertIsNone(fa_agent_timeout.liveness_bytes_of(None))
        self.assertEqual(fa_agent_timeout.liveness_bytes_of("no anchor"), 0)


class FakeTmuxSession:
    """Duck-typed TmuxSession: pane tap via a byte counter, keys recorded."""

    def __init__(self):
        self.counter = {"bytes": 0}
        self.sent = []
        self.copied = []
        self.interrupted = threading.Event()
        self.container = types.SimpleNamespace(exec_run=self._exec_run)

    def _exec_run(self, cmd, **kwargs):
        if "wc -c" in " ".join(cmd):
            return types.SimpleNamespace(
                exit_code=0, output=f"{self.counter['bytes']}\n".encode()
            )
        return types.SimpleNamespace(exit_code=0, output=b"")

    def copy_to_container(self, *args, **kwargs):
        self.copied.append(args)

    def send_keys(self, keys, **kwargs):
        self.sent.append(keys)
        if "C-c" in keys:
            self.interrupted.set()


@unittest.skipUnless(TB_AVAILABLE, "terminal_bench not installed")
class LegacyWatcherTest(unittest.TestCase):
    """Fake-agent IT against the legacy adapter's deadline watcher."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        root = Path(__file__).resolve().parents[1]
        spec = importlib.util.spec_from_file_location(
            "legacy_fa_agent", root / "terminal_bench" / "fa_agent.py"
        )
        self.legacy_fa = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.legacy_fa)

    def _agent(self):
        tarball = Path(self.tmpdir.name) / "fa-bundle.tar.gz"
        tarball.write_bytes(b"")
        with mock.patch.dict(os.environ, {"FA_BUNDLE_TARBALL": str(tarball)}):
            return self.legacy_fa.FaAgent()

    def _with_stock(self, agent, stock):
        return mock.patch.object(
            self.legacy_fa.AbstractInstalledAgent, "perform_task",
            side_effect=stock,
        )

    def test_no_knobs_delegates_to_stock(self):
        agent = self._agent()
        # issue #1123's perform_task guard reads result.failure_mode before
        # delegating — the stock sentinel must carry it (NONE = healthy).
        sentinel = types.SimpleNamespace(failure_mode=None)
        session = FakeTmuxSession()
        with mock.patch.dict(os.environ, clean_env()), self._with_stock(
            agent, lambda *args, **kwargs: sentinel
        ) as stock:
            result = agent.perform_task("instr", session, None)
        self.assertIs(result, sentinel)
        stock.assert_called_once()
        self.assertEqual(len(session.copied), 1)  # bundle copy preserved

    def test_active_agent_survives_past_base_and_completes(self):
        # IT-1 / AC1: steady output past the base cap resolves the task.
        agent = self._agent()
        session = FakeTmuxSession()
        logging_dir = Path(self.tmpdir.name)

        def stock(**kwargs):
            for _ in range(14):  # ~0.7s of steady deltas
                time.sleep(0.05)
                session.counter["bytes"] += 100
            return "stock-result"

        with mock.patch.dict(
            os.environ, clean_env(FA_AGENT_TIMEOUT_SEC="0.5", FA_PROGRESS_EXTENSION="1")
        ), mock.patch.object(self.legacy_fa, "_POLL_SEC", 0.05), self._with_stock(
            agent, stock
        ):
            started = time.monotonic()
            result = agent.perform_task("instr", session, logging_dir)
        self.assertEqual(result, "stock-result")
        self.assertGreater(time.monotonic() - started, 0.5)  # survived the base
        self.assertFalse(session.interrupted.is_set())
        audit = json.loads((logging_dir / "fa-agent-timeout.json").read_text())
        self.assertEqual(audit["outcome"], "completed")
        self.assertGreaterEqual(len(audit["extensions"]), 1)

    def test_silent_agent_killed_at_base(self):
        # IT-2 / AC2 regression pin: zero events dies at the base cap.
        agent = self._agent()
        session = FakeTmuxSession()
        logging_dir = Path(self.tmpdir.name)

        def stock(**kwargs):
            session.interrupted.wait(10)  # silent fa: only dies when interrupted
            return "late-result"

        with mock.patch.dict(
            os.environ, clean_env(FA_AGENT_TIMEOUT_SEC="0.5")
        ), mock.patch.object(self.legacy_fa, "_POLL_SEC", 0.05), self._with_stock(
            agent, stock
        ):
            started = time.monotonic()
            result = agent.perform_task("instr", session, logging_dir)
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 2.0)
        self.assertGreaterEqual(elapsed, 0.45)  # not before the base cap either
        self.assertTrue(session.interrupted.is_set())
        self.assertEqual(
            result.failure_mode, self.legacy_fa.FailureMode.AGENT_TIMEOUT
        )
        self.assertIn("stall", result.timestamped_markers[0][1])
        audit = json.loads((logging_dir / "fa-agent-timeout.json").read_text())
        self.assertEqual(audit["outcome"], "stall")

    def test_hard_ceiling_kills_endlessly_active_agent(self):
        # E2: productive but gigantic => dies loudly at the hard ceiling.
        agent = self._agent()
        session = FakeTmuxSession()
        logging_dir = Path(self.tmpdir.name)

        def stock(**kwargs):
            while not session.interrupted.wait(0.02):
                session.counter["bytes"] += 100
            return "never"

        with mock.patch.dict(
            os.environ,
            clean_env(
                FA_AGENT_TIMEOUT_SEC="0.4",
                FA_PROGRESS_EXTENSION="1",
                FA_AGENT_CEILING_MULTIPLIER="2",
            ),
        ), mock.patch.object(self.legacy_fa, "_POLL_SEC", 0.02), self._with_stock(
            agent, stock
        ):
            started = time.monotonic()
            result = agent.perform_task("instr", session, logging_dir)
        elapsed = time.monotonic() - started
        self.assertGreater(elapsed, 0.7)  # extensions pushed it past the base
        self.assertLess(elapsed, 2.0)  # ...but the hard ceiling held
        self.assertEqual(
            result.failure_mode, self.legacy_fa.FailureMode.AGENT_TIMEOUT
        )
        self.assertIn("hard-ceiling", result.timestamped_markers[0][1])
        audit = json.loads((logging_dir / "fa-agent-timeout.json").read_text())
        self.assertEqual(audit["outcome"], "hard-ceiling")

    def test_crashed_stock_body_audited_as_crashed(self):
        # Round-1 thread 3: a stock-body crash must not be audited
        # "completed" - the audit records the true outcome class.
        agent = self._agent()
        session = FakeTmuxSession()
        logging_dir = Path(self.tmpdir.name)

        def stock(**kwargs):
            raise RuntimeError("fa exploded")

        with mock.patch.dict(
            os.environ,
            clean_env(FA_AGENT_TIMEOUT_SEC="3600", FA_PROGRESS_EXTENSION="1"),
        ), self._with_stock(agent, stock):
            with self.assertRaises(RuntimeError):
                agent.perform_task("instr", session, logging_dir)
        audit = json.loads((logging_dir / "fa-agent-timeout.json").read_text())
        self.assertEqual(audit["outcome"], "crashed")

    def test_verdict_over_late_crash_logs_the_error(self):
        # round-2 thread 3: the ladder verdict wins over a late stock-body
        # crash, but the dropped exception must be logged for postmortem.
        agent = self._agent()
        session = FakeTmuxSession()

        def stock(**kwargs):
            session.interrupted.wait(10)  # silent: dies only at the kill
            raise RuntimeError("late crash after C-c")

        with mock.patch.dict(
            os.environ, clean_env(FA_AGENT_TIMEOUT_SEC="0.5")
        ), mock.patch.object(self.legacy_fa, "_POLL_SEC", 0.05), self._with_stock(
            agent, stock
        ), self.assertLogs(
            self.legacy_fa._LOG, level="WARNING"
        ) as logs:
            result = agent.perform_task("instr", session, None)
        self.assertEqual(
            result.failure_mode, self.legacy_fa.FailureMode.AGENT_TIMEOUT
        )
        self.assertIn("stall", result.timestamped_markers[0][1])
        self.assertTrue(any("late crash after C-c" in line for line in logs.output))


@unittest.skipUnless(HARBOR_AVAILABLE, "harbor not installed")
class HarborParityTest(unittest.TestCase):
    """UT-3 / AC5: the 4.0 adapter honors the same knob contract."""

    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[2]
        spec = importlib.util.spec_from_file_location(
            "harbor_fa_agent", root / "bench" / "harbor_fa" / "fa_agent.py"
        )
        cls.harbor_fa = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.harbor_fa)

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)

    def _agent(self):
        tarball = Path(self.tmpdir.name) / "fa-bundle.tar.gz"
        tarball.write_bytes(b"")
        with mock.patch.dict(
            os.environ,
            {
                "FA_BUNDLE_TARBALL": str(tarball),
            },
        ):
            return self.harbor_fa.FaAgent(Path(self.tmpdir.name) / "logs")

    def test_same_decision_core_as_legacy(self):
        # Both adapters import bench/fa_agent_timeout: measurement policy
        # cannot drift between legacy and 4.0.
        self.assertIs(self.harbor_fa._timeout, fa_agent_timeout)

    def test_agent_command_unchanged_from_legacy_contract(self):
        cmd = self._agent()._agent_command("do $things")
        self.assertIn("fa --session-root /logs/agent/fah-sessions", cmd)
        self.assertIn("tee /logs/agent/fa.txt", cmd)
        self.assertIn("__FA_EXIT=", cmd)

    @staticmethod
    def _fake_env(counter, kill_event=None, audit_sink=None):
        class FakeEnv:
            def __init__(self):
                self.commands = []

            async def exec(self, command, user=None, env=None, cwd=None,
                           timeout_sec=None):
                self.commands.append(command)
                if "wc -c" in command:
                    return types.SimpleNamespace(
                        return_code=0,
                        stdout=f"{counter['bytes']}\n",
                        stderr="",
                    )
                if "pkill" in command:
                    if kill_event is not None:
                        kill_event.set()
                    return types.SimpleNamespace(
                        return_code=0, stdout="", stderr=""
                    )
                if "base64 -d" in command:
                    if audit_sink is not None:
                        audit_sink.append(command)
                    return types.SimpleNamespace(
                        return_code=0, stdout="", stderr=""
                    )
                if "fa --session-root" in command:
                    if kill_event is not None:
                        await kill_event.wait()  # silent agent: only pkill ends it
                    else:
                        await asyncio.sleep(0.3)
                    return types.SimpleNamespace(
                        return_code=0, stdout="", stderr=""
                    )
                return types.SimpleNamespace(return_code=0, stdout="", stderr="")

        return FakeEnv()

    @staticmethod
    def _audit_payload(audit_sink):
        encoded = audit_sink[0].split("printf %s ")[1].split(" |")[0]
        return json.loads(base64.b64decode(encoded))

    def test_natural_completion_with_extensions(self):
        agent = self._agent()
        with mock.patch.dict(
            os.environ,
            clean_env(
                FA_AGENT_TIMEOUT_SEC="0.2",
                FA_PROGRESS_EXTENSION="1",
                FA_PROVIDER_CONFIG="{}",
            ),
        ), mock.patch.object(self.harbor_fa, "_POLL_SEC", 0.05):
            knobs = TimeoutKnobs.from_env()
            self.assertTrue(knobs.progress_extension)
            counter = {"bytes": 0}
            audit_sink = []
            env = self._fake_env(counter, audit_sink=audit_sink)

            async def scenario():
                async def grow():
                    for _ in range(14):
                        await asyncio.sleep(0.05)
                        counter["bytes"] += 500

                grower = asyncio.create_task(grow())
                await agent._run_with_deadline(knobs, "work", env)
                grower.cancel()

            asyncio.run(scenario())  # no TimeoutError => survived past base
            payload = self._audit_payload(audit_sink)
            self.assertEqual(payload["outcome"], "completed")
            self.assertGreaterEqual(len(payload["extensions"]), 1)
            self.assertFalse(any("pkill" in c for c in env.commands))

    def test_crashed_exec_audited_as_crashed(self):
        # Round-1 thread 3: a non-zero fa exit re-raises (today's
        # semantics) and the audit records "crashed", not "completed".
        agent = self._agent()
        with mock.patch.dict(
            os.environ,
            clean_env(
                FA_AGENT_TIMEOUT_SEC="0.4",
                FA_PROGRESS_EXTENSION="1",
                FA_PROVIDER_CONFIG="{}",
            ),
        ), mock.patch.object(self.harbor_fa, "_POLL_SEC", 0.05):
            knobs = TimeoutKnobs.from_env()
            counter = {"bytes": 0}
            audit_sink = []
            env = self._fake_env(counter, audit_sink=audit_sink)
            original_exec = env.exec

            async def failing_exec(command, **kwargs):
                result = await original_exec(command, **kwargs)
                if "fa --session-root" in command:
                    result.return_code = 1
                return result

            env.exec = failing_exec
            with self.assertRaises(Exception) as ctx:
                asyncio.run(agent._run_with_deadline(knobs, "work", env))
            self.assertNotIsInstance(ctx.exception, asyncio.TimeoutError)
            payload = self._audit_payload(audit_sink)
            self.assertEqual(payload["outcome"], "crashed")

    def test_silent_agent_killed_and_classified_as_timeout(self):
        agent = self._agent()
        with mock.patch.dict(
            os.environ,
            clean_env(
                FA_AGENT_TIMEOUT_SEC="0.4",
                FA_AGENT_IDLE_WINDOW_SEC="0.2",
                FA_PROVIDER_CONFIG="{}",
            ),
        ), mock.patch.object(self.harbor_fa, "_POLL_SEC", 0.02):
            knobs = TimeoutKnobs.from_env()
            counter = {"bytes": 100}
            kill_event = asyncio.Event()
            audit_sink = []
            env = self._fake_env(counter, kill_event=kill_event, audit_sink=audit_sink)
            started = time.monotonic()
            with self.assertRaises(asyncio.TimeoutError):
                asyncio.run(agent._run_with_deadline(knobs, "work", env))
            self.assertLess(time.monotonic() - started, 2.0)
            self.assertTrue(any("pkill" in cmd for cmd in env.commands))
            payload = self._audit_payload(audit_sink)
            self.assertEqual(payload["outcome"], "stall")

    def test_no_knobs_takes_today_path(self):
        agent = self._agent()
        calls = []

        async def fake_exec(environment, command, env=None, timeout_sec=None):
            calls.append(command)

        with mock.patch.dict(
            os.environ, clean_env(FA_PROVIDER_CONFIG="{}")
        ), mock.patch.object(
            agent, "exec_as_agent", side_effect=fake_exec
        ):
            asyncio.run(agent.run("work", object(), object()))
        self.assertEqual(len(calls), 1)
        self.assertIn("fa --session-root", calls[0])


if __name__ == "__main__":
    unittest.main()
