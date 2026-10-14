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
import re
import sys
import tempfile
import threading
import time
import types
import unittest
import warnings
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
        module = importlib.import_module(name)
    except ImportError:
        return False
    # test_progress_watch_adapter installs a stdlib stub package under the
    # same name (so its ITs run where terminal-bench is not installed);
    # a stub is not the real dependency.
    return not getattr(module, "__fa_tb_stub__", False)


TB_AVAILABLE = _importable("terminal_bench.agents.base_agent")
HARBOR_AVAILABLE = _importable("harbor")

KNOB_NAMES = (
    "FA_AGENT_TIMEOUT_SEC",
    "FA_PROGRESS_EXTENSION",
    "FA_AGENT_IDLE_WINDOW_SEC",
    "FA_AGENT_CEILING_MULTIPLIER",
)

# gh-1576: the external harness cap rides its own env var; every clean-env
# helper must strip it so a host-exported cap cannot leak into a test that
# means to pin the no-cap byte-identity.
EXTERNAL_CAP_NAME = "FA_EXTERNAL_CAP_SEC"


def clean_env(**overrides):
    env = {
        name: value
        for name, value in os.environ.items()
        if name not in KNOB_NAMES + (EXTERNAL_CAP_NAME,)
    }
    env.update(overrides)
    return env


def _dart_duration_seconds(declaration: str) -> float:
    """Seconds inside a Dart `Duration(...)` constructor call.

    Accepts any argument subset/order (`Duration(seconds: 180)`,
    `Duration(minutes: 5)`, `Duration(minutes: 1, seconds: 30)`,
    `Duration(milliseconds: 500)`) — the coupling REG (gh-1430) feeds it
    the `providerStreamIdleTimeout` line from the Dart source, and the
    parse must survive a benign unit change there.
    """
    body = declaration[declaration.index("(") + 1 : declaration.rindex(")")]
    factors = {
        "milliseconds": 0.001,
        "seconds": 1.0,
        "minutes": 60.0,
        "hours": 3600.0,
    }
    total = 0.0
    matched = False
    for name, factor in factors.items():
        # \b anchors the unit name: `seconds` occurs inside
        # `milliseconds`, and a bare substring match would double-count
        # every milliseconds argument as whole seconds (gh-1430 review).
        for value in re.findall(rf"\b{name}\s*:\s*([0-9.]+)", body):
            matched = True
            total += float(value) * factor
    if not matched:
        raise ValueError(f"no Duration arguments in: {declaration!r}")
    return total

class DartDurationParseTest(unittest.TestCase):
    """Unit table for _dart_duration_seconds (gh-1430 review thread 1).

    The coupling REG feeds this helper the `providerStreamIdleTimeout`
    line straight from the Dart source, and the docstring promises the
    parse survives a benign unit change there. `seconds` occurs INSIDE
    `milliseconds`, so the unit match must be word-boundary anchored —
    otherwise `Duration(milliseconds: 3000)` double-counts (3.0s from
    the milliseconds factor + 3000.0s from the `seconds` substring) and
    a no-op refactor reds the one REG whose job is to be trusted.
    """

    def test_seconds_and_minutes_compose(self):
        self.assertEqual(_dart_duration_seconds("Duration(seconds: 300)"), 300.0)
        self.assertEqual(_dart_duration_seconds("Duration(minutes: 5)"), 300.0)
        self.assertEqual(
            _dart_duration_seconds("Duration(minutes: 1, seconds: 30)"), 90.0
        )

    def test_milliseconds_does_not_double_count_as_seconds(self):
        # The exact case the substring matcher got wrong: `seconds`
        # matched inside `milli**seconds**` → 3003.0 instead of 3.0.
        self.assertEqual(
            _dart_duration_seconds("Duration(milliseconds: 3000)"), 3.0
        )
        self.assertEqual(
            _dart_duration_seconds("Duration(milliseconds: 500)"), 0.5
        )

    def test_mixed_milliseconds_and_seconds(self):
        self.assertEqual(
            _dart_duration_seconds(
                "Duration(seconds: 3, milliseconds: 500)"
            ),
            3.5,
        )

    def test_no_duration_arguments_fails_loud(self):
        with self.assertRaises(ValueError):
            _dart_duration_seconds("Duration()")



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

    def test_reasoning_heartbeat_lines_count_as_liveness_bytes(self):
        # gh-1430: the `… reasoning Ns (streaming)` heartbeat is fa's
        # in-band liveness signal alongside the ⏳ tool-liveness family —
        # the #1185 AC6 audit disclosure must see BOTH, or a trial kept
        # alive purely by reasoning heartbeats reports pane growth as
        # progress with zero disclosed liveness bytes.
        heartbeat = "… reasoning 60s (streaming)\n"
        self.assertEqual(
            fa_agent_timeout.liveness_bytes_of(heartbeat),
            len("… reasoning 60s (streaming)".encode("utf-8")) + 1,
        )
        tier2 = "… reasoning 45s\n"
        self.assertEqual(
            fa_agent_timeout.liveness_bytes_of(tier2),
            len("… reasoning 45s".encode("utf-8")) + 1,
        )

    def test_mixed_liveness_families_both_count(self):
        stream = (
            "assistant text\n"
            "⏳ [bash] sleep 500 — running 60s\n"
            "✓ bash · 61s\n"
            "… reasoning 120s (streaming)\n"
        )
        measured = fa_agent_timeout.liveness_bytes_of(stream)
        expected = sum(
            len(line.encode("utf-8")) + 1
            for line in stream.split("\n")
            if "⏳" in line or "… reasoning" in line
        )
        self.assertEqual(measured, expected)
        self.assertGreater(measured, 0)

    def test_plain_reasoning_prose_is_not_a_liveness_line(self):
        # The anchor is the ellipsis-led line head, not any mention of
        # reasoning: assistant prose stays outside the disclosure.
        self.assertEqual(
            fa_agent_timeout.liveness_bytes_of("I reason therefore I am\n"),
            0,
        )

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
        # gh-1576: the poll loop checkpoints the audit incrementally, so
        # the sink holds partial "running" rows first — the TERMINAL
        # record is the last write.
        encoded = audit_sink[-1].split("printf %s ")[1].split(" |")[0]
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


@unittest.skipUnless(TB_AVAILABLE, "terminal_bench not installed")
class TerminalBenchExternalCapTest(unittest.TestCase):
    """IT-4 (gh-1576): the same cap contract through the tb adapter.

    The tb harness cap (its --global-agent-timeout-sec / dataset caps) is
    normally the LARGER clock (bench.yml pins it above the adapter's own
    ceiling), so the external cap must be inert there (E4) — but when a
    harness ever caps BELOW the knobs (the harbor incident shape), the
    launch line, the audit, and the decider must all follow the smaller
    truth. Parity surface: identical audit schema to the harbor adapter.
    """

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        root = Path(__file__).resolve().parents[1]
        spec = importlib.util.spec_from_file_location(
            "legacy_fa_agent_extcap", root / "terminal_bench" / "fa_agent.py"
        )
        self.legacy_fa = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.legacy_fa)

    def _agent(self):
        tarball = Path(self.tmpdir.name) / "fa-bundle.tar.gz"
        tarball.write_bytes(b"")
        with mock.patch.dict(os.environ, {"FA_BUNDLE_TARBALL": str(tarball)}):
            return self.legacy_fa.FaAgent()

    def _run_supervised(self, env_overrides, stock, logging_dir):
        agent = self._agent()
        session = FakeTmuxSession()
        env = clean_env_all(
            FA_PROGRESS_EXTENSION="1",
            FA_STALL_GAP_SEC="360",
            FA_AGENT_TIMEOUT_ABS_CEILING_SEC="3600",
            FA_PROVIDER_CONFIG="{}",
            **env_overrides,
        )
        with mock.patch.dict(os.environ, env), mock.patch.object(
            self.legacy_fa, "_POLL_SEC", 0.05
        ), mock.patch.object(
            self.legacy_fa.AbstractInstalledAgent, "perform_task",
            side_effect=stock,
        ):
            started = time.monotonic()
            agent.perform_task("instr", session, logging_dir)
        return agent, time.monotonic() - started

    def test_it4_launch_line_carries_the_external_cap_deadline(self):
        # AC1 parity: the launch line's FA_DEADLINE_EPOCH_MS projects the
        # 1800s external cap - 120s margin, not the 3600s knob ceiling.
        logging_dir = Path(self.tmpdir.name)
        agent, _ = self._run_supervised(
            {fa_agent_timeout.EXTERNAL_CAP_ENV: "1800"},
            lambda **kwargs: "stock-result",
            logging_dir,
        )
        commands = agent._run_agent_commands("instr")
        self.assertEqual(len(commands), 1)
        self.assertIn("FA_DEADLINE_EPOCH_MS=", commands[0].command)
        exported = int(
            commands[0].command.split("FA_DEADLINE_EPOCH_MS=")[1].split(";")[0]
        )
        now_ms = int(time.time() * 1000)
        # 1680s ± the (sub-second) trial runtime.
        self.assertGreaterEqual(exported, now_ms + 1_679_000 - 5_000)
        self.assertLessEqual(exported, now_ms + 1_681_000)

    def test_it4_audit_names_the_winning_source(self):
        logging_dir = Path(self.tmpdir.name)
        self._run_supervised(
            {fa_agent_timeout.EXTERNAL_CAP_ENV: "1800"},
            lambda **kwargs: "stock-result",
            logging_dir,
        )
        audit = json.loads((logging_dir / "fa-agent-timeout.json").read_text())
        self.assertEqual(audit["outcome"], "completed")
        resolved = audit["cap_resolution"]
        self.assertEqual(resolved["winning_cap_source"], "external")
        self.assertEqual(resolved["external_cap_sec"], 1800.0)
        self.assertEqual(resolved["external_cap_status"], "known")
        self.assertEqual(resolved["knob_cap_sec"], 3600.0)
        self.assertEqual(resolved["effective_cap_sec"], 1800.0)

    def test_it4_larger_external_cap_is_inert(self):
        # E4 parity: bench.yml's shape — the tb harness cap sits ABOVE the
        # adapter ceiling, so nothing may change (byte-identical deadline).
        logging_dir = Path(self.tmpdir.name)
        agent, _ = self._run_supervised(
            {fa_agent_timeout.EXTERNAL_CAP_ENV: "86400"},
            lambda **kwargs: "stock-result",
            logging_dir,
        )
        audit = json.loads((logging_dir / "fa-agent-timeout.json").read_text())
        self.assertEqual(audit["cap_resolution"]["winning_cap_source"], "knobs")
        self.assertEqual(audit["cap_resolution"]["effective_cap_sec"], 3600.0)

    def test_it4_checkpoints_written_per_progress_sample(self):
        # IT-3/E3 tb parity: the audit is checkpointed incrementally on
        # the poll loop (partial "running" rows), the terminal row is not
        # a checkpoint. The writes are observed at the writer seam — the
        # file itself only survives with its last write.
        logging_dir = Path(self.tmpdir.name)
        writes = []
        original = self.legacy_fa.FaAgent._write_audit

        def recording(logging_dir, knobs, ladder, outcome, *args, **kwargs):
            original(logging_dir, knobs, ladder, outcome, *args, **kwargs)
            writes.append((outcome, kwargs.get("checkpoint", False)))

        def stock(**kwargs):
            for _ in range(6):
                time.sleep(0.05)
            return "stock-result"

        agent = self._agent()
        session = FakeTmuxSession()
        env = clean_env_all(
            FA_PROGRESS_EXTENSION="1",
            FA_STALL_GAP_SEC="360",
            FA_AGENT_TIMEOUT_ABS_CEILING_SEC="3600",
            FA_PROVIDER_CONFIG="{}",
            **{fa_agent_timeout.EXTERNAL_CAP_ENV: "1800"},
        )
        with mock.patch.dict(os.environ, env), mock.patch.object(
            self.legacy_fa, "_POLL_SEC", 0.05
        ), mock.patch.object(
            self.legacy_fa.AbstractInstalledAgent, "perform_task",
            side_effect=stock,
        ), mock.patch.object(
            self.legacy_fa.FaAgent, "_write_audit", staticmethod(recording)
        ):
            agent.perform_task("instr", session, logging_dir)
        self.assertGreaterEqual(len(writes), 2, writes)
        running = [w for w in writes if w == ("running", True)]
        self.assertGreaterEqual(len(running), 1)
        self.assertEqual(writes[-1][0], "completed")
        self.assertFalse(writes[-1][1])

    def test_audit_schema_matches_the_harbor_surface(self):
        # IT-4 semantic-drift property: both adapters render the audit via
        # the SAME shared writer — the cap_resolution block and the
        # checkpoint/external_kill extras must be the identical schema.
        logging_dir = Path(self.tmpdir.name)
        self._run_supervised(
            {fa_agent_timeout.EXTERNAL_CAP_ENV: "1800"},
            lambda **kwargs: "stock-result",
            logging_dir,
        )
        tb_audit = json.loads((logging_dir / "fa-agent-timeout.json").read_text())
        env = clean_env_all(
            FA_PROGRESS_EXTENSION="1",
            FA_AGENT_TIMEOUT_ABS_CEILING_SEC="3600",
            **{fa_agent_timeout.EXTERNAL_CAP_ENV: "1800"},
        )
        knobs = TimeoutKnobs.from_env(env)
        cap = fa_agent_timeout.resolve_cap(knobs, env)
        harbor_shaped = audit_dict(
            knobs, fa_agent_timeout.ProgressWatch(knobs), "completed",
            cap=cap, deadline_epoch_ms=42,
        )
        self.assertEqual(
            set(tb_audit["cap_resolution"]),
            set(harbor_shaped["cap_resolution"]),
        )
        self.assertEqual(
            set(tb_audit) - {"deadline_sec", "extensions",
                             "last_progress_sec", "last_output_bytes"},
            set(harbor_shaped) - {"deadline_sec", "extensions",
                                  "last_progress_sec", "last_output_bytes"},
        )

    def test_external_cap_only_stock_run_exports_and_audits(self):
        # No adapter knobs, external cap known: the stock single-exec path
        # still arms fa's clock (I1) and lands the audit (I2).
        logging_dir = Path(self.tmpdir.name)
        agent = self._agent()
        session = FakeTmuxSession()
        sentinel = types.SimpleNamespace(
            failure_mode=self.legacy_fa.FailureMode.NONE
        )
        env = clean_env_all(
            FA_PROVIDER_CONFIG="{}",
            **{fa_agent_timeout.EXTERNAL_CAP_ENV: "1800"},
        )
        with mock.patch.dict(os.environ, env), mock.patch.object(
            self.legacy_fa.AbstractInstalledAgent, "perform_task",
            side_effect=lambda *a, **k: sentinel,
        ) as stock:
            agent.perform_task("instr", session, logging_dir)
        stock.assert_called_once()
        commands = agent._run_agent_commands("instr")
        self.assertIn("FA_DEADLINE_EPOCH_MS=", commands[0].command)
        audit = json.loads((logging_dir / "fa-agent-timeout.json").read_text())
        self.assertEqual(audit["outcome"], "completed")
        self.assertEqual(audit["policy"], "external-cap")
        self.assertNotIn("knobs", audit)
        self.assertEqual(audit["cap_resolution"]["winning_cap_source"], "external")

    def test_harness_timeout_stock_run_audits_external_kill(self):
        # Review round 2: knobs=None means the adapter never supervises —
        # an agent_timeout classification is the HARNESS's own kill (it
        # came from outside the adapter), so the audit must say the
        # recognized verdict `external_kill`. The raw failure-mode string
        # is absent from both honesty-justified sets (summary.py /
        # post_mortem_usage.py) and reads as a false "killed while
        # progressing" contradiction (the gh-1556 lesson).
        logging_dir = Path(self.tmpdir.name)
        agent = self._agent()
        session = FakeTmuxSession()
        sentinel = types.SimpleNamespace(
            failure_mode=self.legacy_fa.FailureMode.AGENT_TIMEOUT
        )
        env = clean_env_all(
            FA_PROVIDER_CONFIG="{}",
            **{fa_agent_timeout.EXTERNAL_CAP_ENV: "1800"},
        )
        with mock.patch.dict(os.environ, env), mock.patch.object(
            self.legacy_fa.AbstractInstalledAgent, "perform_task",
            side_effect=lambda *a, **k: sentinel,
        ):
            agent.perform_task("instr", session, logging_dir)
        audit = json.loads((logging_dir / "fa-agent-timeout.json").read_text())
        self.assertEqual(audit["outcome"], "external_kill")
        self.assertEqual(audit["policy"], "external-cap")

    def test_other_failure_modes_stay_raw_in_the_stock_audit(self):
        # Only the harness-timeout class maps to a recognized verdict;
        # every other failure mode stays raw — the harness's own
        # classification IS the truthful outcome (those rows never pass
        # the agent_timeout honesty filter).
        logging_dir = Path(self.tmpdir.name)
        agent = self._agent()
        session = FakeTmuxSession()
        sentinel = types.SimpleNamespace(
            failure_mode=self.legacy_fa.FailureMode.UNKNOWN_AGENT_ERROR
        )
        env = clean_env_all(
            FA_PROVIDER_CONFIG="{}",
            **{fa_agent_timeout.EXTERNAL_CAP_ENV: "1800"},
        )
        with mock.patch.dict(os.environ, env), mock.patch.object(
            self.legacy_fa.AbstractInstalledAgent, "perform_task",
            side_effect=lambda *a, **k: sentinel,
        ):
            agent.perform_task("instr", session, logging_dir)
        audit = json.loads((logging_dir / "fa-agent-timeout.json").read_text())
        self.assertEqual(
            audit["outcome"], str(self.legacy_fa.FailureMode.UNKNOWN_AGENT_ERROR.value)
        )

    def test_no_cap_no_knobs_stock_run_stays_byte_identical(self):
        # AC5/REG-2: no cap, no knobs — no export, no audit.
        logging_dir = Path(self.tmpdir.name)
        agent = self._agent()
        session = FakeTmuxSession()
        sentinel = types.SimpleNamespace(
            failure_mode=self.legacy_fa.FailureMode.NONE
        )
        with mock.patch.dict(
            os.environ, clean_env_all(FA_PROVIDER_CONFIG="{}")
        ), mock.patch.object(
            self.legacy_fa.AbstractInstalledAgent, "perform_task",
            side_effect=lambda *a, **k: sentinel,
        ):
            agent.perform_task("instr", session, logging_dir)
        commands = agent._run_agent_commands("instr")
        self.assertNotIn("FA_DEADLINE_EPOCH_MS", commands[0].command)
        self.assertFalse((logging_dir / "fa-agent-timeout.json").exists())


NEW_KNOB_NAMES = (
    "FA_STALL_GAP_SEC",
    "FA_AGENT_TIMEOUT_ABS_CEILING_SEC",
)


class HarnessArtifactIsolationTest(unittest.TestCase):
    """Issue #1408 AC1: the bench adapters relocate fa's bash-job logs
    OUTSIDE the task workspace via FAH_JOB_LOG_DIR.

    The r3 autopsy (run 37736364517, sanitize-git-repo ×2): fa's
    .fah/bash_jobs/ logs sat inside the graded workspace, captured raw
    secret values from the agent's own greps, and the agent's cleanup of
    its own harness logs flipped test_no_other_files_changed. The session
    root was already relocated (--session-root); the job logs now follow.
    """

    def _load(self, name, relpath):
        import importlib.util

        root = Path(__file__).resolve().parents[2]
        spec = importlib.util.spec_from_file_location(name, root / relpath)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def _tarball(self):
        tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(tmpdir.cleanup)
        tarball = Path(tmpdir.name) / "fa-bundle.tar.gz"
        tarball.write_bytes(b"")
        return str(tarball)

    def test_terminal_bench_env_relocates_job_logs(self):
        if not TB_AVAILABLE:
            self.skipTest("terminal_bench not installed")
        legacy = self._load(
            "legacy_fa_agent_env", "bench/terminal_bench/fa_agent.py"
        )
        with mock.patch.dict(
            os.environ,
            clean_env(
                FA_BUNDLE_TARBALL=self._tarball(),
                FA_PROVIDER_CONFIG="{}",
            ),
        ):
            agent = legacy.FaAgent()
            self.assertEqual(
                agent._env.get("FAH_JOB_LOG_DIR"),
                "/tmp/fa-harness-artifacts/bash_jobs",
            )

    def test_harbor_provider_env_relocates_job_logs(self):
        if not HARBOR_AVAILABLE:
            self.skipTest("harbor not installed")
        harbor_fa = self._load(
            "harbor_fa_agent_env", "bench/harbor_fa/fa_agent.py"
        )
        with mock.patch.dict(
            os.environ,
            clean_env(
                FA_BUNDLE_TARBALL=self._tarball(),
                FA_PROVIDER_CONFIG="{}",
            ),
        ):
            agent = harbor_fa.FaAgent(Path(self._tarball()).parent / "logs")
            self.assertEqual(
                agent._provider_env.get("FAH_JOB_LOG_DIR"),
                "/tmp/fa-harness-artifacts/bash_jobs",
            )


def clean_env_all(**overrides):
    env = {
        name: value
        for name, value in os.environ.items()
        if name not in KNOB_NAMES + NEW_KNOB_NAMES + (EXTERNAL_CAP_NAME,)
    }
    env.update(overrides)
    return env


class ProgressWatchKnobTest(unittest.TestCase):
    """Round-3 knobs (issue #1392 AC1): stall gap + absolute ceiling."""

    def test_new_knobs_absent_means_legacy_ladder_mode(self):
        knobs = TimeoutKnobs.from_env(clean_env_all(FA_PROGRESS_EXTENSION="1"))
        self.assertIsNone(knobs.stall_gap_sec)
        self.assertIsNone(knobs.abs_ceiling_sec)
        self.assertFalse(knobs.progress_watch)

    def test_stall_gap_knob_activates_progress_watch_mode(self):
        knobs = TimeoutKnobs.from_env(clean_env_all(FA_STALL_GAP_SEC="240"))
        self.assertEqual(knobs.stall_gap_sec, 240.0)
        self.assertTrue(knobs.progress_watch)
        # The abs ceiling defaults to 3600s in watch mode (issue #1392
        # open question 1 default) — still overridable explicitly.
        self.assertEqual(knobs.watch_abs_ceiling_sec, 3600.0)

    def test_abs_ceiling_knob_activates_progress_watch_mode(self):
        knobs = TimeoutKnobs.from_env(
            clean_env_all(FA_AGENT_TIMEOUT_ABS_CEILING_SEC="5400")
        )
        self.assertTrue(knobs.progress_watch)
        self.assertEqual(knobs.abs_ceiling_sec, 5400.0)
        self.assertEqual(knobs.watch_abs_ceiling_sec, 5400.0)
        # The stall gap defaults to 360s in watch mode (gh-1430: fa's
        # 300s stream-idle watchdog + a 60s margin — the bench must never
        # arbitrate a stream fa itself considers live; the coupling REG
        # below pins it against the Dart source).
        self.assertEqual(knobs.watch_stall_gap_sec, 360.0)

    def test_stall_gap_default_stays_above_fa_stream_watchdog(self):
        # gh-1430 AC4 (REG-R3): the shipped FA_STALL_GAP_SEC default must
        # stay >= fa's effective providerStreamIdleTimeout + margin. This
        # reads the SHIPPED fa default straight from the Dart source, so
        # the REG fails if EITHER side drifts (a watchdog raise without a
        # gap raise would reintroduce the round-4 mid-thinking kills; a
        # gap drop below the watchdog would make the bench the premature
        # liveness arbiter again). Ordering invariant (fa_agent_timeout
        # docstring): fa's watchdog is the sole arbiter of stream death;
        # the bench gap only catches pane/process death.
        root = Path(__file__).resolve().parents[2]
        provider_common = root / "lib" / "src" / "providers" / "provider_common.dart"
        match = None
        for line in provider_common.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped.startswith("const providerStreamIdleTimeout ="):
                match = stripped
                break
        self.assertIsNotNone(
            match, "providerStreamIdleTimeout moved — update this REG"
        )
        watchdog_sec = _dart_duration_seconds(match)
        margin_sec = 60.0
        self.assertGreaterEqual(
            fa_agent_timeout._STALL_GAP_DEFAULT,
            watchdog_sec + margin_sec,
            f"FA_STALL_GAP_SEC default "
            f"({fa_agent_timeout._STALL_GAP_DEFAULT}s) dropped to/below fa's "
            f"stream-idle watchdog ({watchdog_sec}s) + margin — the bench "
            f"would SIGKILL streams fa itself considers live again "
            f"(gh-1430)",
        )
        # The env knob path resolves to the same shipped default.
        knobs = TimeoutKnobs.from_env(
            clean_env_all(FA_PROGRESS_EXTENSION="1")
        )
        self.assertEqual(knobs.watch_stall_gap_sec, 360.0)

    def test_garbage_new_knob_fails_loud(self):
        with self.assertRaises(ValueError):
            TimeoutKnobs.from_env(clean_env_all(FA_STALL_GAP_SEC="soon"))
        with self.assertRaises(ValueError):
            TimeoutKnobs.from_env(clean_env_all(FA_AGENT_TIMEOUT_ABS_CEILING_SEC="0"))


class ProgressWatchTest(unittest.TestCase):
    """UT-* (AC1): the gap-aware kill decision, fake clock via push samples.

    Semantics: while inter-record gaps stay < stall-gap the trial counts as
    progressing and the ONLY kill is the absolute ceiling (3600s + test
    budget default) — the ×4 ceiling no longer guillotines productive runs
    (play-zork, 72 productive minutes, run 37609468473). A gap >= the
    stall-gap threshold marks the trial stalled and the ladder resumes
    counting: the kill deadline is last progress + the idle window.
    """

    def _watch(self, **knob_overrides):
        env = clean_env_all(FA_PROGRESS_EXTENSION="1", **knob_overrides)
        return fa_agent_timeout.ProgressWatch(TimeoutKnobs.from_env(env))

    def test_progressing_trial_survives_past_legacy_ceiling(self):
        # AC1 synthetic: steady 60s gaps and a 4000s workload must NOT die
        # at the legacy ×4 ceiling (1440s at base 360) — only the abs
        # ceiling (3600) can kill a progressing trial.
        watch = self._watch()
        for t in range(0, 3540, 60):
            self.assertIsNone(watch.evaluate(float(t), t * 1000), f"died at {t}s")

    def test_progressing_trial_dies_at_abs_ceiling_distinct_reason(self):
        # E2: a legit 61+ min task dies with agent_timeout(abs_ceiling) —
        # a distinct failure-mode string separating cap-kill from stall.
        watch = self._watch()
        for t in range(0, 3600, 60):
            self.assertIsNone(watch.evaluate(float(t), t * 1000))
        self.assertEqual(watch.evaluate(3660.0, 3660 * 1000), "abs_ceiling")

    def test_single_stall_gap_gap_dies_at_ladder(self):
        # AC1: one 360s+ gap and no progress after it -> the ladder resumes
        # counting and the trial dies (last progress + idle window, which
        # a 360s gap has already exceeded).
        watch = self._watch()
        for t in range(0, 600, 60):
            self.assertIsNone(watch.evaluate(float(t), t * 1000))
        # 360s of silence after the last progress at 540s.
        self.assertEqual(watch.evaluate(900.0, None), "stall")
        self.assertEqual(watch.evaluate(960.0, None), "stall")

    def test_sub_watchdog_gap_stays_progressing(self):
        # gh-1430: the shipped gap (360s) sits ABOVE fa's stream-idle
        # watchdog (300s) — a mid-thinking gap fa itself tolerates must
        # never reach the bench's stall verdict (the round-4 kill class).
        watch = self._watch()
        self.assertIsNone(watch.evaluate(0.0, 10))
        self.assertIsNone(watch.evaluate(240.0, 10))
        self.assertIsNone(watch.evaluate(300.0, 10))
        self.assertIsNone(watch.evaluate(359.0, 10))
        self.assertEqual(watch.evaluate(360.0, 10), "stall")

    def test_gap_exactly_at_threshold_is_stall_no_flap(self):
        # E1: a gap exactly at the threshold counts as stalled (>=), and
        # the verdict is sticky: it does not flap back without new
        # progress bytes. Pinned on an explicit 240s gap so the boundary
        # semantics stay covered independent of the shipped default.
        env = clean_env_all(FA_PROGRESS_EXTENSION="1", FA_STALL_GAP_SEC="240")
        watch = fa_agent_timeout.ProgressWatch(TimeoutKnobs.from_env(env))
        self.assertIsNone(watch.evaluate(0.0, 10))
        self.assertEqual(watch.evaluate(240.0, 10), "stall")
        self.assertEqual(watch.evaluate(241.0, 10), "stall")

    def test_progress_after_stall_refreezes_ladder(self):
        # Hysteresis: new output after a stall detection re-enters
        # progressing mode — only the abs ceiling can kill again.
        watch = self._watch()
        self.assertIsNone(watch.evaluate(0.0, 10))
        self.assertEqual(watch.evaluate(400.0, 10), "stall")
        self.assertIsNone(watch.evaluate(420.0, 20))  # progress resumes
        self.assertIsNone(watch.evaluate(480.0, 30))
        self.assertEqual(watch.evaluate(840.0, 30), "stall")

    def test_extension_off_flat_cap_byte_identical(self):
        # REG: with the extension off the watch is the flat cap, exactly
        # the legacy ladder's regression pin.
        env = clean_env_all(FA_STALL_GAP_SEC="240", FA_PROGRESS_EXTENSION="0")
        watch = fa_agent_timeout.ProgressWatch(TimeoutKnobs.from_env(env))
        self.assertIsNone(watch.evaluate(359.0, 10**9))
        self.assertEqual(watch.evaluate(360.0, 10**9), "stall")

    def test_abs_ceiling_includes_test_budget(self):
        # test_budget_sec is a DECISION-OBJECT knob (generic ceiling math),
        # NOT an adapter behavior: the bench adapter constructs the watch
        # without it (flat 3600s) because tb enforces the verifier phase
        # separately. This pins the knob math only.
        env = clean_env_all(FA_PROGRESS_EXTENSION="1", FA_STALL_GAP_SEC="240")
        knobs = TimeoutKnobs.from_env(env)
        watch = fa_agent_timeout.ProgressWatch(knobs, test_budget_sec=240.0)
        for t in range(0, 3840, 60):
            self.assertIsNone(watch.evaluate(float(t), t * 1000), f"died at {t}s")
        self.assertEqual(watch.evaluate(3900.0, 3900 * 1000), "abs_ceiling")

    def test_watch_events_recorded_for_audit(self):
        watch = self._watch()
        watch.evaluate(0.0, 10)
        watch.evaluate(400.0, 10)  # stall detected (gap 400 >= 360)
        watch.evaluate(420.0, 20)  # progress resumes
        kinds = [event["kind"] for event in watch.events]
        self.assertIn("stall_detected", kinds)
        self.assertIn("progress_resumed", kinds)
        stall = next(e for e in watch.events if e["kind"] == "stall_detected")
        self.assertEqual(stall["gap_sec"], 400.0)


class ProgressWatchAuditTest(unittest.TestCase):
    def test_audit_names_progress_watch_policy_and_new_knobs(self):
        env = clean_env_all(FA_PROGRESS_EXTENSION="1", FA_STALL_GAP_SEC="240")
        knobs = TimeoutKnobs.from_env(env)
        watch = fa_agent_timeout.ProgressWatch(knobs)
        watch.evaluate(0.0, 10)
        record = audit_dict(knobs, watch, "abs_ceiling")
        self.assertEqual(record["policy"], "progress-watch")
        self.assertEqual(record["knobs"]["stall_gap_sec"], 240.0)
        self.assertEqual(record["knobs"]["abs_ceiling_sec"], 3600.0)
        self.assertEqual(record["outcome"], "abs_ceiling")

    def test_audit_keeps_flat_policy_for_legacy_ladder(self):
        knobs = TimeoutKnobs(base_sec=120.0)
        ladder = ProgressLadder(knobs)
        record = audit_dict(knobs, ladder, "stall")
        self.assertEqual(record["policy"], "flat-cap")


class DeadlineEnvTest(unittest.TestCase):
    """gh-1556 AC7: FA_DEADLINE_EPOCH_MS for fa's deadline awareness.

    The deadline comes ONLY from the adapter's own kill cap minus a
    wrap-up margin — never invented; with no adapter cap (no knobs) the
    export is absent and fa's deadline awareness stays off.
    """

    def test_no_knobs_means_no_deadline(self):
        self.assertIsNone(
            fa_agent_timeout.deadline_epoch_ms(None, 1_700_000_000_000)
        )
        self.assertEqual(fa_agent_timeout.deadline_env_from(clean_env_all()), {})

    def test_watch_mode_deadline_is_abs_ceiling_minus_margin(self):
        env = clean_env_all(
            FA_PROGRESS_EXTENSION="1", FA_STALL_GAP_SEC="360"
        )
        knobs = TimeoutKnobs.from_env(env)
        now_ms = 1_700_000_000_000
        # 3600s abs ceiling - 120s wrap-up margin.
        self.assertEqual(
            fa_agent_timeout.deadline_epoch_ms(knobs, now_ms),
            now_ms + 3480_000,
        )
        self.assertEqual(
            fa_agent_timeout.deadline_env_from(env, now_ms),
            {"FA_DEADLINE_EPOCH_MS": str(now_ms + 3480_000)},
        )

    def test_watch_mode_without_extension_deadline_is_base_minus_margin(self):
        # gh-1556 rework review (BLOCKING, AC7): with the extension off
        # ProgressWatch pins kill_at = base_sec (the flat legacy cap) —
        # so the exported deadline MUST derive from base_sec too.
        # Promising the 3600s abs ceiling would be a ~58-minute lie over
        # a 6-minute guillotine (workflow-reachable via an explicit
        # progress-extension: false dispatch, which unsets the step-env
        # extension while the watch knobs remain).
        env = clean_env_all(
            FA_STALL_GAP_SEC="360", FA_AGENT_TIMEOUT_ABS_CEILING_SEC="3600"
        )
        knobs = TimeoutKnobs.from_env(env)
        self.assertTrue(knobs.progress_watch)
        self.assertFalse(knobs.progress_extension)
        # The real guillotine — the deadline must not outlive it.
        self.assertEqual(
            fa_agent_timeout.ProgressWatch(knobs).kill_at, knobs.base_sec
        )
        now_ms = 1_700_000_000_000
        # base 360s - 120s wrap-up margin = 240s (NOT 3600 - 120).
        self.assertEqual(
            fa_agent_timeout.effective_cap_sec(knobs), knobs.base_sec
        )
        self.assertEqual(
            fa_agent_timeout.deadline_epoch_ms(knobs, now_ms),
            now_ms + 240_000,
        )
        self.assertEqual(
            fa_agent_timeout.deadline_env_from(env, now_ms),
            {"FA_DEADLINE_EPOCH_MS": str(now_ms + 240_000)},
        )

    def test_legacy_extension_deadline_is_hard_ceiling_minus_margin(self):
        env = clean_env_all(
            FA_AGENT_TIMEOUT_SEC="600", FA_PROGRESS_EXTENSION="1"
        )
        knobs = TimeoutKnobs.from_env(env)
        now_ms = 1_700_000_000_000
        # Hard ceiling = 600 * 4 = 2400s; minus 120s margin.
        self.assertEqual(
            fa_agent_timeout.deadline_epoch_ms(knobs, now_ms),
            now_ms + 2280_000,
        )

    def test_flat_cap_deadline_is_base_minus_margin(self):
        env = clean_env_all(FA_AGENT_TIMEOUT_SEC="600")
        knobs = TimeoutKnobs.from_env(env)
        now_ms = 1_700_000_000_000
        self.assertEqual(
            fa_agent_timeout.deadline_epoch_ms(knobs, now_ms),
            now_ms + 480_000,
        )

    def test_tiny_cap_clamps_to_a_remaining_window(self):
        # A 60s cap minus the 120s margin would land in the past — the
        # deadline clamps to a minimal wrap-up window instead of steering
        # fa into an already-expired clock.
        env = clean_env_all(FA_AGENT_TIMEOUT_SEC="60")
        knobs = TimeoutKnobs.from_env(env)
        now_ms = 1_700_000_000_000
        self.assertEqual(
            fa_agent_timeout.deadline_epoch_ms(knobs, now_ms),
            now_ms + 30_000,
        )

    def test_test_budget_folds_into_the_watch_cap(self):
        env = clean_env_all(
            FA_PROGRESS_EXTENSION="1", FA_STALL_GAP_SEC="360"
        )
        knobs = TimeoutKnobs.from_env(env)
        now_ms = 1_700_000_000_000
        self.assertEqual(
            fa_agent_timeout.deadline_epoch_ms(
                knobs, now_ms, test_budget_sec=300.0
            ),
            now_ms + 3780_000,
        )

    def test_audit_records_the_fa_visible_deadline(self):
        env = clean_env_all(
            FA_PROGRESS_EXTENSION="1", FA_STALL_GAP_SEC="360"
        )
        knobs = TimeoutKnobs.from_env(env)
        watch = fa_agent_timeout.ProgressWatch(knobs)
        record = audit_dict(knobs, watch, "abs_ceiling", deadline_epoch_ms=42)
        self.assertEqual(record["deadline_epoch_ms"], 42)

    def test_audit_omits_deadline_when_unset(self):
        # No-knob runs keep the pre-gh-1556 audit shape byte-for-byte.
        knobs = TimeoutKnobs(base_sec=120.0)
        ladder = ProgressLadder(knobs)
        record = audit_dict(knobs, ladder, "stall")
        self.assertNotIn("deadline_epoch_ms", record)


class ExternalCapParsingTest(unittest.TestCase):
    """UT-1/UT-3 (gh-1576): FA_EXTERNAL_CAP_SEC parsing — degrade, never crash.

    The cap is harness metadata injected by the workflow; a malformed value
    must fall back to knobs-only with a warning (AC8), never raise inside a
    running trial the way the knob knobs' fail-loud contract does.
    """

    def test_absent_or_blank_cap_is_unknown(self):
        # AC5/E1: no cap exported (the workflow leaves the env var empty
        # when a shard's tasks declare no timeout) => unknown, not a zero.
        self.assertEqual(fa_agent_timeout.external_cap_from_env(clean_env_all()), (None, "unknown"))
        self.assertEqual(
            fa_agent_timeout.external_cap_from_env(clean_env_all(**{EXTERNAL_CAP_NAME: "  "})),
            (None, "unknown"),
        )

    def test_integer_and_float_caps_are_known(self):
        self.assertEqual(
            fa_agent_timeout.external_cap_from_env(clean_env_all(**{EXTERNAL_CAP_NAME: "1800"})),
            (1800.0, "known"),
        )
        self.assertEqual(
            fa_agent_timeout.external_cap_from_env(clean_env_all(**{EXTERNAL_CAP_NAME: "1800.5"})),
            (1800.5, "known"),
        )

    def test_malformed_caps_are_rejected_with_a_warning(self):
        # AC8: non-numeric, <= 0, non-finite and absurdly large values are
        # all rejected — knobs-only fallback, warning logged, no exception.
        for bad in ("soon", "0", "-5", "inf", "nan", "-inf", "1e999", "1e13"):
            with self.subTest(bad=bad):
                with warnings.catch_warnings(record=True) as caught:
                    warnings.simplefilter("always")
                    parsed = fa_agent_timeout.external_cap_from_env(
                        clean_env_all(**{EXTERNAL_CAP_NAME: bad})
                    )
                self.assertEqual(parsed, (None, "rejected"))
                self.assertTrue(
                    any(issubclass(w.category, UserWarning) for w in caught),
                    f"{bad!r} rejection must warn",
                )
                joined = " ".join(str(w.message) for w in caught)
                self.assertIn("FA_EXTERNAL_CAP_SEC", joined)

    def test_rejection_is_silent_when_quiet_flag_set(self):
        # The resolve path warns once; callers that already log (the
        # adapters) pass quiet=True to avoid double-printing per trial.
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            parsed = fa_agent_timeout.external_cap_from_env(
                clean_env_all(**{EXTERNAL_CAP_NAME: "soon"}), quiet=True
            )
        self.assertEqual(parsed, (None, "rejected"))
        self.assertEqual(caught, [])


class CapResolutionTest(unittest.TestCase):
    """UT-1 (gh-1576): the min() composition — the heart of the card.

    effective_cap = min(external cap, knob cap); the winning source is
    recorded; a larger external cap can never widen the budget (I1/E4);
    equal caps tie-break to external (E5 — the harness is the stricter
    truth); malformed caps degrade to knobs-only (AC8).
    """

    @staticmethod
    def watch_env(**overrides):
        return clean_env_all(
            FA_PROGRESS_EXTENSION="1", FA_AGENT_TIMEOUT_ABS_CEILING_SEC="3600", **overrides
        )

    def test_external_smaller_than_knobs_wins(self):
        # AC1: the incident shape — harbor declares 1800s, the shipped knob
        # ceiling is 3600s; the effective cap MUST be 1800 (source external).
        env = self.watch_env(**{EXTERNAL_CAP_NAME: "1800"})
        cap = fa_agent_timeout.resolve_cap(TimeoutKnobs.from_env(env), env)
        self.assertEqual(cap.external_cap_sec, 1800.0)
        self.assertEqual(cap.external_cap_status, "known")
        self.assertEqual(cap.knob_cap_sec, 3600.0)
        self.assertEqual(cap.effective_cap_sec, 1800.0)
        self.assertEqual(cap.winning_cap_source, "external")

    def test_knobs_smaller_than_external_win(self):
        # AC6/E4: a bigger external cap never widens the budget.
        env = self.watch_env(**{EXTERNAL_CAP_NAME: "7200"})
        cap = fa_agent_timeout.resolve_cap(TimeoutKnobs.from_env(env), env)
        self.assertEqual(cap.effective_cap_sec, 3600.0)
        self.assertEqual(cap.winning_cap_source, "knobs")

    def test_equal_caps_tie_break_to_external(self):
        # E5: deterministic tie-break — the harness is the stricter truth.
        env = self.watch_env(**{EXTERNAL_CAP_NAME: "3600"})
        cap = fa_agent_timeout.resolve_cap(TimeoutKnobs.from_env(env), env)
        self.assertEqual(cap.effective_cap_sec, 3600.0)
        self.assertEqual(cap.winning_cap_source, "external")

    def test_no_knobs_with_known_external_resolves_external(self):
        # No adapter knobs but the harness cap is known: the effective cap
        # is the external truth alone (fa still learns the real budget).
        cap = fa_agent_timeout.resolve_cap(None, clean_env_all(**{EXTERNAL_CAP_NAME: "1800"}))
        self.assertIsNotNone(cap)
        self.assertIsNone(cap.knob_cap_sec)
        self.assertEqual(cap.effective_cap_sec, 1800.0)
        self.assertEqual(cap.winning_cap_source, "external")

    def test_no_external_cap_knobs_rule_alone(self):
        # AC5: knobs-only run — byte-identical resolution, status unknown.
        env = self.watch_env()
        cap = fa_agent_timeout.resolve_cap(TimeoutKnobs.from_env(env), env)
        self.assertEqual(cap.external_cap_sec, None)
        self.assertEqual(cap.external_cap_status, "unknown")
        self.assertEqual(cap.effective_cap_sec, 3600.0)
        self.assertEqual(cap.winning_cap_source, "knobs")

    def test_rejected_cap_degrades_to_knobs_only(self):
        # AC8: malformed cap — knobs-only fallback, status recorded.
        bad_env = self.watch_env(**{EXTERNAL_CAP_NAME: "soon"})
        cap = fa_agent_timeout.resolve_cap(
            TimeoutKnobs.from_env(bad_env), bad_env, quiet=True
        )
        self.assertEqual(cap.external_cap_status, "rejected")
        self.assertIsNone(cap.external_cap_sec)
        self.assertEqual(cap.effective_cap_sec, 3600.0)
        self.assertEqual(cap.winning_cap_source, "knobs")

    def test_rejected_cap_with_no_knobs_is_feature_off(self):
        # A rejected cap must not invent a clock where none existed.
        self.assertIsNone(
            fa_agent_timeout.resolve_cap(None, clean_env_all(**{EXTERNAL_CAP_NAME: "soon"}), quiet=True)
        )

    def test_flat_knob_cap_composes_with_external(self):
        # Legacy flat ladder (no watch): the knob cap is the base cap.
        env = clean_env_all(FA_AGENT_TIMEOUT_SEC="600", **{EXTERNAL_CAP_NAME: "1800"})
        cap = fa_agent_timeout.resolve_cap(TimeoutKnobs.from_env(env), env)
        self.assertEqual(cap.knob_cap_sec, 600.0)
        self.assertEqual(cap.effective_cap_sec, 600.0)
        self.assertEqual(cap.winning_cap_source, "knobs")

    def test_resolve_warns_once_on_rejection(self):
        bad_env = self.watch_env(**{EXTERNAL_CAP_NAME: "soon"})
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            fa_agent_timeout.resolve_cap(TimeoutKnobs.from_env(bad_env), bad_env)
        self.assertTrue(any("FA_EXTERNAL_CAP_SEC" in str(w.message) for w in caught))


class ExternalCapDeadlineTest(unittest.TestCase):
    """UT-1/IT-1 (gh-1576): the exported deadline derives from the min cap."""

    NOW_MS = 1_700_000_000_000

    @staticmethod
    def watch_env(**overrides):
        return clean_env_all(
            FA_PROGRESS_EXTENSION="1", FA_AGENT_TIMEOUT_ABS_CEILING_SEC="3600", **overrides
        )

    def test_external_cap_1800_caps_the_deadline_at_30_min(self):
        # AC1: first-request time-left projection <= 30 min under a 1800s
        # cap: 1800 - 120 (wrap-up margin) = 1680s.
        self.assertEqual(
            fa_agent_timeout.deadline_env_from(self.watch_env(**{EXTERNAL_CAP_NAME: "1800"}), self.NOW_MS),
            {"FA_DEADLINE_EPOCH_MS": str(self.NOW_MS + 1_680_000)},
        )

    def test_larger_external_cap_changes_nothing(self):
        # E4/REG-2: 7200s external over a 3600s ceiling is byte-identical
        # to the no-cap run.
        legacy = fa_agent_timeout.deadline_env_from(self.watch_env(), self.NOW_MS)
        bigger = fa_agent_timeout.deadline_env_from(
            self.watch_env(**{EXTERNAL_CAP_NAME: "7200"}), self.NOW_MS
        )
        self.assertEqual(legacy, bigger)

    def test_no_external_cap_byte_identical_to_legacy(self):
        # AC5/REG-2: without the env var the exported deadline is exactly
        # the pre-gh-1576 value.
        self.assertEqual(
            fa_agent_timeout.deadline_env_from(self.watch_env(), self.NOW_MS),
            {"FA_DEADLINE_EPOCH_MS": str(self.NOW_MS + 3_480_000)},
        )

    def test_external_cap_arms_the_deadline_without_knobs(self):
        # No adapter knobs, external 1800 known: fa still learns the true
        # budget (the harness kill is real even when we do not supervise).
        self.assertEqual(
            fa_agent_timeout.deadline_env_from(
                clean_env_all(**{EXTERNAL_CAP_NAME: "1800"}), self.NOW_MS
            ),
            {"FA_DEADLINE_EPOCH_MS": str(self.NOW_MS + 1_680_000)},
        )

    def test_rejected_cap_never_arms_a_clock(self):
        # AC8: no knobs + rejected cap => no export (never a made-up clock).
        self.assertEqual(
            fa_agent_timeout.deadline_env_from(
                clean_env_all(**{EXTERNAL_CAP_NAME: "soon"}), self.NOW_MS
            ),
            {},
        )

    def test_tiny_external_cap_clamps_to_the_cap_itself(self):
        # E7: a cap below the min-remaining window must never project a
        # deadline PAST the kill (the old clamp floor could): 10s cap =>
        # deadline == start + cap (zero margin), recorded as clamped.
        env = self.watch_env(**{EXTERNAL_CAP_NAME: "10"})
        cap, deadline = fa_agent_timeout.resolve_deadline(
            TimeoutKnobs.from_env(env), env, now_ms=self.NOW_MS
        )
        self.assertEqual(deadline, self.NOW_MS + 10_000)
        self.assertTrue(cap.deadline_clamped)

    def test_wrap_up_margin_grace_still_clamps(self):
        # E7 pinned shape: 60s cap — 120s margin would go negative; the
        # clamp lands on the 30s min-remaining window (inside the cap).
        env = self.watch_env(**{EXTERNAL_CAP_NAME: "60"})
        cap, deadline = fa_agent_timeout.resolve_deadline(
            TimeoutKnobs.from_env(env), env, now_ms=self.NOW_MS
        )
        self.assertEqual(deadline, self.NOW_MS + 30_000)
        self.assertTrue(cap.deadline_clamped)

    def test_no_clamp_on_a_healthy_cap(self):
        env = self.watch_env(**{EXTERNAL_CAP_NAME: "1800"})
        cap, _ = fa_agent_timeout.resolve_deadline(
            TimeoutKnobs.from_env(env), env, now_ms=self.NOW_MS
        )
        self.assertFalse(cap.deadline_clamped)

    def test_resolve_deadline_returns_none_when_fully_off(self):
        self.assertEqual(
            fa_agent_timeout.resolve_deadline(None, clean_env_all(), now_ms=self.NOW_MS),
            (None, None),
        )


class CappedDeciderTest(unittest.TestCase):
    """UT-1 (gh-1576): the kill decisions cap at the external truth.

    The external cap never widens a deadline (E4); when it binds (a
    smaller harness cap than the knob ceiling) the verdict names it —
    the audit's outcome must say which clock killed the trial.
    """

    @staticmethod
    def watch(knobs, external=None):
        return fa_agent_timeout.ProgressWatch(knobs, external_cap_sec=external)

    @staticmethod
    def watch_knobs(**overrides):
        env = clean_env_all(
            FA_PROGRESS_EXTENSION="1", FA_AGENT_TIMEOUT_ABS_CEILING_SEC="3600", **overrides
        )
        return TimeoutKnobs.from_env(env)

    def test_progressing_trial_dies_at_external_cap(self):
        # The incident shape: healthy progress, 1800s dataset cap under a
        # 3600s knob ceiling — the trial dies at 1800s, named.
        watch = self.watch(self.watch_knobs(), external=1800.0)
        for t in range(0, 1740, 60):
            self.assertIsNone(watch.evaluate(float(t), t * 1000), f"died at {t}s")
        self.assertEqual(watch.evaluate(1800.0, 1800 * 1000), "external_cap")

    def test_external_cap_below_ceiling_never_widens(self):
        # E4: external above the ceiling is inert — legacy verdict.
        watch = self.watch(self.watch_knobs(), external=7200.0)
        for t in range(0, 3600, 60):
            self.assertIsNone(watch.evaluate(float(t), t * 1000))
        self.assertEqual(watch.evaluate(3660.0, 3660 * 1000), "abs_ceiling")

    def test_equal_external_and_ceiling_ties_to_external(self):
        # E5: equal caps — the harness is the stricter truth.
        watch = self.watch(self.watch_knobs(), external=3600.0)
        for t in range(0, 3540, 60):
            self.assertIsNone(watch.evaluate(float(t), t * 1000))
        self.assertEqual(watch.evaluate(3600.0, 3600 * 1000), "external_cap")

    def test_stall_deadline_is_capped_by_external(self):
        # A stalled trial whose ladder deadline lands past the external
        # cap dies at the cap, named; one that stalls BEFORE the cap keeps
        # the legacy "stall" verdict (the knob clock was the binding one).
        watch = self.watch(self.watch_knobs(), external=300.0)
        self.assertIsNone(watch.evaluate(0.0, 10))
        self.assertEqual(watch.evaluate(300.0, 10), "external_cap")
        # Ladder verdict under the cap: an explicit 240s gap and progress
        # at 50s stalls at 290s (max(290, 50 + 120) = 290) — before the
        # 300s external cap, so the honest verdict is still "stall".
        watch2 = self.watch(
            self.watch_knobs(FA_STALL_GAP_SEC="240", idle_window=120.0),
            external=300.0,
        )
        self.assertIsNone(watch2.evaluate(0.0, 10))
        self.assertIsNone(watch2.evaluate(50.0, 10))
        self.assertEqual(watch2.evaluate(290.0, 10), "stall")

    def test_extension_off_flat_base_still_capped(self):
        # Extension off: flat base cap — the external cap only ever
        # shrinks it, never grows it.
        env = clean_env_all(
            FA_STALL_GAP_SEC="240",
            FA_AGENT_TIMEOUT_ABS_CEILING_SEC="3600",
            FA_PROGRESS_EXTENSION="0",
        )
        knobs = TimeoutKnobs.from_env(env)
        self.assertEqual(fa_agent_timeout.ProgressWatch(knobs).kill_at, knobs.base_sec)
        watch = fa_agent_timeout.ProgressWatch(knobs, external_cap_sec=120.0)
        self.assertEqual(watch.kill_at, 120.0)
        self.assertEqual(watch.evaluate(120.0, 10**9), "external_cap")

    def test_ladder_dies_at_external_cap(self):
        # Legacy ladder + smaller external cap: the flat base (3600s)
        # can never outlive a 1800s harness guillotine.
        env = clean_env_all(FA_AGENT_TIMEOUT_SEC="3600")
        ladder = fa_agent_timeout.ProgressLadder(
            TimeoutKnobs.from_env(env), external_cap_sec=1800.0
        )
        self.assertEqual(ladder.kill_at, 1800.0)
        self.assertIsNone(ladder.evaluate(1799.0, 0))
        self.assertEqual(ladder.evaluate(1800.0, 0), "external_cap")

    def test_ladder_knob_smaller_than_external_keeps_stall_verdict(self):
        # AC6: knob cap binds => byte-identical legacy verdict.
        env = clean_env_all(FA_AGENT_TIMEOUT_SEC="360")
        ladder = fa_agent_timeout.ProgressLadder(
            TimeoutKnobs.from_env(env), external_cap_sec=1800.0
        )
        self.assertEqual(ladder.evaluate(360.0, 0), "stall")

    def test_no_external_cap_deciders_are_byte_identical(self):
        # REG-2: default construction (no external) is today's behavior.
        watch = self.watch(self.watch_knobs())
        self.assertEqual(watch.external_cap_sec, None)
        for t in range(0, 3600, 60):
            self.assertIsNone(watch.evaluate(float(t), t * 1000))
        self.assertEqual(watch.evaluate(3660.0, 3660 * 1000), "abs_ceiling")


class CapAuditTest(unittest.TestCase):
    """UT-2 (gh-1576): the audit names the winning source and both inputs,
    and leaks no unrelated env values (byte-scan)."""

    @staticmethod
    def watch_env(**overrides):
        return clean_env_all(
            FA_PROGRESS_EXTENSION="1", FA_AGENT_TIMEOUT_ABS_CEILING_SEC="3600", **overrides
        )

    def test_audit_names_winning_source_and_both_inputs(self):
        # AC2: external won — the record says so, with both input values.
        env = self.watch_env(**{EXTERNAL_CAP_NAME: "1800"})
        cap = fa_agent_timeout.resolve_cap(TimeoutKnobs.from_env(env), env, quiet=True)
        watch = fa_agent_timeout.ProgressWatch(TimeoutKnobs.from_env(env))
        record = audit_dict(
            TimeoutKnobs.from_env(env), watch, "external_cap", cap=cap, deadline_epoch_ms=42
        )
        resolved = record["cap_resolution"]
        self.assertEqual(resolved["winning_cap_source"], "external")
        self.assertEqual(resolved["external_cap_sec"], 1800.0)
        self.assertEqual(resolved["external_cap_status"], "known")
        self.assertEqual(resolved["knob_cap_sec"], 3600.0)
        self.assertEqual(resolved["effective_cap_sec"], 1800.0)
        self.assertEqual(resolved["deadline_epoch_ms"], 42)
        self.assertFalse(resolved["deadline_clamped"])

    def test_audit_records_unknown_and_rejected_statuses(self):
        # AC5/E1: knobs-only run says external unknown; AC8: a rejected
        # cap is recorded, not silently dropped.
        env = self.watch_env()
        knobs = TimeoutKnobs.from_env(env)
        record = audit_dict(
            knobs, fa_agent_timeout.ProgressWatch(knobs), "completed", cap=fa_agent_timeout.resolve_cap(knobs, env)
        )
        self.assertEqual(record["cap_resolution"]["external_cap_status"], "unknown")
        self.assertNotIn("external_cap_sec", record["cap_resolution"])

        bad_env = self.watch_env(**{EXTERNAL_CAP_NAME: "soon"})
        bad_knobs = TimeoutKnobs.from_env(bad_env)
        bad_record = audit_dict(
            bad_knobs,
            fa_agent_timeout.ProgressWatch(bad_knobs),
            "completed",
            cap=fa_agent_timeout.resolve_cap(bad_knobs, bad_env, quiet=True),
        )
        self.assertEqual(bad_record["cap_resolution"]["external_cap_status"], "rejected")

    def test_audit_clamp_recorded_for_tiny_cap(self):
        # E7: the clamp is written down, not discovered by archaeology.
        env = self.watch_env(**{EXTERNAL_CAP_NAME: "60"})
        knobs = TimeoutKnobs.from_env(env)
        cap = fa_agent_timeout.resolve_cap(knobs, env, quiet=True)
        record = audit_dict(knobs, fa_agent_timeout.ProgressWatch(knobs), "completed", cap=cap)
        self.assertTrue(record["cap_resolution"]["deadline_clamped"])

    def test_audit_without_cap_keeps_legacy_shape(self):
        # REG-2: a no-cap audit is byte-identical — no cap_resolution key.
        knobs = TimeoutKnobs(base_sec=120.0)
        record = audit_dict(knobs, ProgressLadder(knobs), "stall")
        self.assertNotIn("cap_resolution", record)

    def test_audit_leaks_no_unrelated_env_values(self):
        # Byte-scan: the cap values are integers; no other env value (and
        # no other FA_* env NAME) may cross into the audit JSON, and the
        # cap_resolution block stays a fixed closed shape.
        env = self.watch_env(**{EXTERNAL_CAP_NAME: "1800"})
        env["FA_PROVIDER_CONFIG"] = '{"secret":"s3cr3t"}'
        cap = fa_agent_timeout.resolve_cap(TimeoutKnobs.from_env(env), env, quiet=True)
        watch = fa_agent_timeout.ProgressWatch(TimeoutKnobs.from_env(env))
        record = audit_dict(
            TimeoutKnobs.from_env(env), watch, "external_cap", cap=cap, deadline_epoch_ms=7
        )
        payload = json.dumps(record)
        self.assertNotIn("s3cr3t", payload)
        self.assertNotIn("FA_PROVIDER_CONFIG", payload)
        for name in env:
            if name.startswith("FA_") and name != EXTERNAL_CAP_NAME:
                self.assertNotIn(name, payload)
        self.assertEqual(
            set(record["cap_resolution"]),
            {
                "external_cap_status",
                "effective_cap_sec",
                "winning_cap_source",
                "deadline_clamped",
                "external_cap_sec",
                "knob_cap_sec",
                "deadline_epoch_ms",
            },
        )


class ExternalCapStaticRegTest(unittest.TestCase):
    """REG-1 (gh-1576, merge-blocking): the deadline can never exceed a
    known external cap — by construction, not by review.

    Static contract over the three sources: the shared module's deadline
    entry points must route through the external-cap min(), and neither
    adapter may compute FA_DEADLINE_EPOCH_MS from the knobs directly.
    """

    ROOT = Path(__file__).resolve().parents[2]
    MODULE = ROOT / "bench" / "fa_agent_timeout.py"
    ADAPTERS = (
        ROOT / "bench" / "harbor_fa" / "fa_agent.py",
        ROOT / "bench" / "terminal_bench" / "fa_agent.py",
    )

    @staticmethod
    def _function_body(source: str, name: str) -> str:
        """The source between `def <name>` and the next top-level def."""
        start = source.index(f"def {name}(")
        nxt = source.find("\ndef ", start + 1)
        return source[start : nxt if nxt != -1 else len(source)]

    def test_module_deadline_entry_points_route_through_the_min(self):
        source = self.MODULE.read_text(encoding="utf-8")
        env_from = self._function_body(source, "deadline_env_from")
        self.assertIn(
            "resolve_cap(",
            env_from,
            "deadline_env_from must resolve the cap through the external-cap min()",
        )
        epoch = self._function_body(source, "deadline_epoch_ms")
        self.assertIn(
            "external_cap_sec",
            epoch,
            "deadline_epoch_ms must accept and apply the external cap",
        )
        self.assertIn(
            "min(",
            epoch,
            "deadline_epoch_ms must compose the caps with min()",
        )
        resolve = self._function_body(source, "resolve_cap")
        self.assertIn(
            "min(",
            resolve,
            "resolve_cap must compose the caps with min()",
        )

    def test_adapters_never_compute_the_deadline_from_knobs(self):
        # Any line that touches the FA_DEADLINE_EPOCH_MS env name must be
        # a transport of an already-resolved stash value (dict key, env
        # assignment of the stash, launch-line export) — never arithmetic
        # over knobs/caps. The regexes below are the actual kill paths a
        # regression would take.
        danger = re.compile(
            r"FA_DEADLINE_EPOCH_MS.*"
            r"(effective_cap_sec\(|watch_abs_ceiling|ceiling_sec|base_sec"
            r"|stall_gap|deadline_from_cap|time\.time\(\)\s*\*|\bmonotonic\("
            r"|\bnow\s*\+|\+\s*\w*cap\w*\s*\*\s*1000)"
        )
        for path in self.ADAPTERS:
            with self.subTest(adapter=path.name):
                for lineno, line in enumerate(
                    path.read_text(encoding="utf-8").splitlines(), 1
                ):
                    stripped = line.strip()
                    if stripped.startswith("#"):
                        continue
                    self.assertFalse(
                        danger.search(line),
                        f"{path.name}:{lineno} computes FA_DEADLINE_EPOCH_MS "
                        f"outside the shared min(): {stripped!r}",
                    )

    def test_adapters_source_the_deadline_from_the_shared_module(self):
        # Positive pin: each adapter's only deadline source is the shared
        # helper (which applies the min()).
        harbor = (self.ROOT / "bench" / "harbor_fa" / "fa_agent.py").read_text(encoding="utf-8")
        self.assertTrue(
            "_timeout.deadline_epoch_ms(" in harbor or "_timeout.resolve_deadline(" in harbor,
            "harbor adapter must source its deadline from bench/fa_agent_timeout",
        )
        tb = (self.ROOT / "bench" / "terminal_bench" / "fa_agent.py").read_text(encoding="utf-8")
        self.assertTrue(
            "_timeout.deadline_env_from(" in tb or "_timeout.resolve_deadline(" in tb,
            "tb adapter must source its deadline from bench/fa_agent_timeout",
        )


if __name__ == "__main__":
    unittest.main()
