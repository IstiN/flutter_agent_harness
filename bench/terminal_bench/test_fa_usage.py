#!/usr/bin/env python3
"""Unit tests for issue #1123 token/cost accounting.

Run: python3 -m unittest discover -s bench/terminal_bench

UT-1 runs the SAME fixture through both adapters (legacy fa_agent.py and
harbor fa_agent.py) plus the shared extractor; UT-2 covers the
estimation/fail-soft paths; the pricing tests cover the cost math and the
missing-model n/a rule (E3). Minimal stub modules stand in for the two
adapter base classes wherever the real harbor/terminal_bench packages are
not installed — the code under test is the real fa_agent.py glue. The
harbor stub is conditional (gh-1535): clobbering a real harbor install
would break the parity tests in test_fa_agent_timeout loaded later by the
same `unittest discover` process.
"""
import enum
import importlib.metadata
import importlib.util
import json
import sys
import tempfile
import types
import unittest
import unittest.mock
from contextlib import redirect_stderr
from io import StringIO
from pathlib import Path

_BENCH = Path(__file__).resolve().parent.parent
if str(_BENCH) not in sys.path:
    sys.path.insert(0, str(_BENCH))

import fa_usage  # noqa: E402


def _module(name, **attrs):
    mod = types.ModuleType(name)
    for key, value in attrs.items():
        setattr(mod, key, value)
    sys.modules[name] = mod
    return mod


def _stub_terminal_bench():
    failure_mode = _module("terminal_bench.agents.failure_mode")
    # gh-1638: a REAL enum like the actual
    # terminal_bench.agents.failure_mode.FailureMode — members carry
    # .value (the gh-1576 raw-outcome audit reads it) and _NEVER_STARTED_
    # MODES membership works by identity. The former SimpleNamespace of
    # plain strings made the TB-gated tests in test_fa_agent_timeout (run
    # against this sys.modules stub in the shared discover process) crash
    # with "'str' object has no attribute 'value'" once the raw branch
    # became reachable.
    class FailureMode(enum.Enum):
        NONE = "none"
        AGENT_TIMEOUT = "agent_timeout"
        # gh-1209: the never-started modes fa_agent's fold-skip set names,
        # plus a ran-outcome mode outside them (PARSE_ERROR) that pins the
        # fold's default-on direction.
        UNKNOWN_AGENT_ERROR = "unknown_agent_error"
        AGENT_INSTALLATION_FAILED = "agent_installation_failed"
        PARSE_ERROR = "parse_error"

    failure_mode.FailureMode = FailureMode  # AGENT_TIMEOUT: fa_agent.py needs it (test_fa_agent_timeout LegacyWatcherTest loads fa_agent against this stub in the shared discover process)

    def installed_perform_task(self, instruction, session, logging_dir=None):
        # tb's AbstractInstalledAgent hardcodes zeros (the issue's bug).
        return FaAgentTest.AgentResult(
            total_input_tokens=0, total_output_tokens=0,
            failure_mode=FailureMode.NONE,
        )

    abstract = _module(
        "terminal_bench.agents.installed_agents.abstract_installed_agent",
        AbstractInstalledAgent=type(
            "AbstractInstalledAgent",
            (),
            {"perform_task": installed_perform_task},
        ),
    )

    class AgentResult:
        def __init__(
            self,
            total_input_tokens=0,
            total_output_tokens=0,
            failure_mode=None,
            timestamped_markers=None,
        ):
            self.total_input_tokens = total_input_tokens
            self.total_output_tokens = total_output_tokens
            self.failure_mode = failure_mode
            self.timestamped_markers = timestamped_markers or []

    # #1122's adapter imports AgentResult from this module.
    base_agent = _module("terminal_bench.agents.base_agent", AgentResult=AgentResult)
    _module("terminal_bench.terminal.models", TerminalCommand=type("TerminalCommand", (), {}))
    _module("terminal_bench.agents.installed_agents", abstract_installed_agent=abstract)
    _module("terminal_bench.agents", failure_mode=failure_mode, base_agent=base_agent)
    _module("terminal_bench.terminal", models=sys.modules["terminal_bench.terminal.models"])
    _module("terminal_bench")


def _stub_harbor():
    class AgentContext:
        def __init__(self):
            self.n_input_tokens = None
            self.n_cache_tokens = None
            self.n_output_tokens = None
            self.cost_usd = None
            self.metadata = None

    base = _module("harbor.agents.installed.base", BaseInstalledAgent=type("BaseInstalledAgent", (), {}))
    env_base = _module("harbor.environments.base", BaseEnvironment=type("BaseEnvironment", (), {}))
    context = _module("harbor.models.agent.context", AgentContext=AgentContext)
    _module("harbor.agents.installed", base=base)
    _module("harbor.environments", base=env_base)
    _module("harbor.models.agent", context=context)
    _module("harbor.models", agent=sys.modules["harbor.models.agent"])
    _module("harbor")


def _real_harbor_available() -> bool:
    """True when the REAL harbor package is importable.

    gh-1535: the stub below must NOT clobber a real harbor install.
    `unittest discover` imports every test module in this directory
    before running any test, so an unconditional _stub_harbor() parks a
    synthetic BaseInstalledAgent (a bare type with no __init__) in
    sys.modules; HarborParityTest / HarnessArtifactIsolationTest in
    test_fa_agent_timeout then load bench/harbor_fa/fa_agent.py against
    that stub and `FaAgent(logs_dir)` dies with "takes no arguments".
    The stub modules built by _module() are bare types.ModuleType objects
    with no __file__; the real harbor package always has one.
    """
    try:
        module = importlib.import_module("harbor.agents.installed.base")
    except ImportError as e:
        # gh-1535 rework: a missing TRANSITIVE dep (e.g. pydantic with a
        # --no-deps harbor install) means harbor is present but broken —
        # fail loudly rather than silently stubbing over it and
        # recreating the original "FaAgent() takes no arguments" CI shape.
        if e.name is not None and not e.name.startswith("harbor"):
            raise
        return False
    return getattr(module, "__file__", None) is not None


def _harbor_distribution_present() -> bool:
    """True when a `harbor` distribution is installed, importable or not.

    Distinguishes "harbor not installed" (tests may skip) from "harbor
    installed but the sys.modules stub is bound" — the gh-1535 regression,
    which must FAIL loudly. Distribution metadata is the signal (not
    find_spec: a parked stub module has __spec__ None, so find_spec raises
    ValueError and cannot answer the question).
    """
    try:
        return importlib.metadata.distribution("harbor") is not None
    except importlib.metadata.PackageNotFoundError:
        return False


_stub_terminal_bench()
# gh-1638: the shared alias the sentinel builders below use — the stub's
# FailureMode is what fa_agent.py binds in this discover process.
TB_FAILURE_MODE = sys.modules["terminal_bench.agents.failure_mode"].FailureMode
# Stub ONLY when the real package is absent: with real harbor installed
# (bench-harbor setup job) fa_agent.py must import the real
# BaseInstalledAgent so the parity tests can construct FaAgent(logs_dir).
if not _real_harbor_available():
    _stub_harbor()


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


legacy_fa_agent = _load("fa_agent_legacy", Path(__file__).resolve().parent / "fa_agent.py")
harbor_fa_agent = _load("fa_agent_harbor", _BENCH / "harbor_fa" / "fa_agent.py")

MODEL = "glm-5.3-flash"


def assistant_rec(request_id, inp, out, cache_read, cache_write, model=MODEL, content=None):
    message = {
        "role": "assistant",
        "provider": "zai",
        "model": model,
        "content": content if content is not None else [{"type": "text", "text": "ok"}],
        "usage": {
            "input": inp,
            "output": out,
            "cacheRead": cache_read,
            "cacheWrite": cache_write,
            "totalTokens": inp + out + cache_read + cache_write,
            "cost": {"input": 0.0, "output": 0.0, "cacheRead": 0.0, "cacheWrite": 0.0, "total": 0.0},
        },
        "stopReason": "stop",
    }
    return {"type": "message", "id": request_id, "message": message}


def _jsonl(*records):
    return "\n".join(json.dumps(r) for r in records) + "\n"


# UT-1 fixture: two requests in the main session plus a subagent session
# (E2) and a retry session file (E1) — every record counts exactly once.
MAIN_SESSION = _jsonl(
    {"type": "custom", "id": "c0", "customType": "model_request_summary", "data": {"messageCount": 3}},
    {"type": "message", "id": "u0", "message": {"role": "user", "content": [{"type": "text", "text": "hi"}]}},
    assistant_rec("a0", 100, 50, 30, 10),
    assistant_rec("a1", 200, 25, 0, 0),
)
SUBAGENT_SESSION = _jsonl(assistant_rec("a2", 10, 5, 0, 0))
EXPECTED_IN, EXPECTED_OUT, EXPECTED_CR, EXPECTED_CW = 310, 80, 30, 10
# (310*0.15 + 80*0.50 + 30*0.03 + 10*0.0) / 1e6 — bench/pricing.json, glm-5.3-flash.
EXPECTED_COST = 8.74e-05


def make_sessions(root: Path) -> Path:
    sessions = root / "agent-logs" / "fah-sessions"
    (sessions / "subagents").mkdir(parents=True)
    (sessions / "trial-session.jsonl").write_text(MAIN_SESSION)
    (sessions / "subagents" / "sub.jsonl").write_text(SUBAGENT_SESSION)
    return sessions


def no_exec_session(mode):
    """A session double for never-started trials: exec_run must never be
    reached, so reaching it names the outcome that should have skipped the
    fold. Shared by the installation-failure and unknown-agent-error pins
    (gh-1209 review nit — the two doubles differed only in that name)."""

    class NoExecSession:
        class Container:
            def exec_run(self, cmd):  # pragma: no cover — must not be reached
                raise AssertionError(f"exec_run called after {mode}")

        def copy_to_container(self, *args, **kwargs):
            pass

    return NoExecSession()


class FaAgentTest(unittest.TestCase):
    class AgentResult:
        def __init__(self, total_input_tokens=0, total_output_tokens=0,
                     failure_mode=TB_FAILURE_MODE.NONE):
            self.total_input_tokens = total_input_tokens
            self.total_output_tokens = total_output_tokens
            self.failure_mode = failure_mode

    class FakeSession:
        class Container:
            def __init__(self, text):
                self.text = text

            def exec_run(self, cmd):
                return 0, self.text.encode()

        def __init__(self, text):
            self.copy_calls = 0
            self.container = self.Container(text)

        def copy_to_container(self, *args, **kwargs):
            self.copy_calls += 1

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.sessions = make_sessions(Path(self.tmp.name))
        self.addCleanup(self.tmp.cleanup)

    def legacy_agent(self):
        agent = legacy_fa_agent.FaAgent.__new__(legacy_fa_agent.FaAgent)
        agent._bundle_tarball = Path("unused.tar.gz")  # __new__ skips __init__
        return agent

    def legacy_result(self, text):
        agent = self.legacy_agent()
        return agent.perform_task("do it", self.FakeSession(text)), agent

    def test_ut1_legacy_adapter_sums_known_usage(self):
        result, _ = self.legacy_result(MAIN_SESSION + SUBAGENT_SESSION)
        self.assertEqual(result.total_input_tokens, EXPECTED_IN)
        self.assertEqual(result.total_output_tokens, EXPECTED_OUT)

    def test_ut1_legacy_adapter_reads_container_via_find(self):
        session = self.FakeSession(MAIN_SESSION)
        agent = self.legacy_agent()
        agent.perform_task("do it", session)
        self.assertEqual(session.copy_calls, 1)

    def test_ut1_harbor_adapter_sums_known_usage_and_cost(self):
        agent = harbor_fa_agent.FaAgent.__new__(harbor_fa_agent.FaAgent)
        agent.logs_dir = self.sessions.parent
        context = harbor_fa_agent.AgentContext()
        agent.populate_context_post_run(context)
        # Harbor semantics: n_input_tokens includes cache.
        self.assertEqual(context.n_input_tokens, EXPECTED_IN + EXPECTED_CR + EXPECTED_CW)
        self.assertEqual(context.n_output_tokens, EXPECTED_OUT)
        self.assertEqual(context.n_cache_tokens, EXPECTED_CR + EXPECTED_CW)
        self.assertAlmostEqual(context.cost_usd, EXPECTED_COST, places=11)

    def test_zero_token_trial_stays_zero_with_no_fake_cost(self):
        # Legacy: no session output → tb's zeros survive untouched.
        result, _ = self.legacy_result("")
        self.assertEqual(result.total_input_tokens, 0)
        self.assertEqual(result.total_output_tokens, 0)
        # Harbor: empty session dir → nothing to fold → context untouched.
        agent = harbor_fa_agent.FaAgent.__new__(harbor_fa_agent.FaAgent)
        empty = Path(self.tmp.name) / "empty" / "fah-sessions"
        empty.mkdir(parents=True)
        agent.logs_dir = empty.parent
        context = harbor_fa_agent.AgentContext()
        agent.populate_context_post_run(context)
        self.assertIsNone(context.n_input_tokens)
        self.assertIsNone(context.cost_usd)

    def test_fail_soft_on_container_errors(self):
        class BrokenSession:
            def copy_to_container(self, *args, **kwargs):
                pass

            class Container:
                def exec_run(self, cmd):
                    return 1, b""

        agent = self.legacy_agent()
        # gh-1638 AC2: the fail-soft warning is pinned AND captured — the
        # suite's own log stays warning-clean while the test still proves
        # the fold degrades to zeros instead of failing the trial.
        stderr = StringIO()
        with redirect_stderr(stderr):
            result = agent.perform_task("do it", BrokenSession())
        self.assertEqual(result.total_input_tokens, 0)
        self.assertEqual(result.total_output_tokens, 0)
        self.assertIn("session usage extraction failed", stderr.getvalue())

    def test_installation_failure_result_untouched(self):
        original = self.AgentResult(
            failure_mode=TB_FAILURE_MODE.AGENT_INSTALLATION_FAILED
        )
        agent = self.legacy_agent()
        monkey = unittest.mock.patch.object(
            legacy_fa_agent.AbstractInstalledAgent,
            "perform_task",
            return_value=original,
        )
        with monkey:
            result = agent.perform_task("do it", no_exec_session("agent_installation_failed"))
        self.assertIs(result, original)

    def test_timeout_result_folds_session_usage(self):
        # gh-1209: a timed-out run is the EXPENSIVE run — the session usage
        # fold must run for any outcome where fa actually ran, not only for
        # healthy results. tb's harness discards the adapter's result on its
        # own timeout and records its own zeros, so whenever a timeout
        # result does round-trip through perform_task, it must carry the
        # session's real numbers.
        original = self.AgentResult(failure_mode=TB_FAILURE_MODE.AGENT_TIMEOUT)
        agent = self.legacy_agent()
        session = self.FakeSession(MAIN_SESSION + SUBAGENT_SESSION)
        monkey = unittest.mock.patch.object(
            legacy_fa_agent.AbstractInstalledAgent,
            "perform_task",
            return_value=original,
        )
        with monkey:
            result = agent.perform_task("do it", session)
        self.assertEqual(result.total_input_tokens, EXPECTED_IN)
        self.assertEqual(result.total_output_tokens, EXPECTED_OUT)

    def test_unknown_agent_error_result_untouched(self):
        # gh-1209: unknown_agent_error is a true never-started trial — the
        # harness never got the agent going, so there is nothing to fold
        # and the result passes through byte-for-byte.
        original = self.AgentResult(
            failure_mode=TB_FAILURE_MODE.UNKNOWN_AGENT_ERROR
        )
        agent = self.legacy_agent()
        monkey = unittest.mock.patch.object(
            legacy_fa_agent.AbstractInstalledAgent,
            "perform_task",
            return_value=original,
        )
        with monkey:
            result = agent.perform_task("do it", no_exec_session("unknown_agent_error"))
        self.assertIs(result, original)

    def test_other_ran_failure_mode_folds_session_usage(self):
        # gh-1209 review: pins the DEFAULT-FOLD direction. agent_timeout
        # alone cannot distinguish "fold for any ran outcome" from a future
        # accidental fold-whitelist (mode in _FOLD_MODES); a ran-outcome
        # mode outside the stub's named set must fold too.
        original = self.AgentResult(failure_mode=TB_FAILURE_MODE.PARSE_ERROR)
        agent = self.legacy_agent()
        session = self.FakeSession(MAIN_SESSION + SUBAGENT_SESSION)
        monkey = unittest.mock.patch.object(
            legacy_fa_agent.AbstractInstalledAgent,
            "perform_task",
            return_value=original,
        )
        with monkey:
            result = agent.perform_task("do it", session)
        self.assertEqual(result.total_input_tokens, EXPECTED_IN)
        self.assertEqual(result.total_output_tokens, EXPECTED_OUT)


class ExtractorTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_ut1_extractor_sums_fixture_exactly(self):
        usage = fa_usage.extract_from_dir(make_sessions(Path(self.tmp.name)))
        self.assertEqual(usage.input_tokens, EXPECTED_IN)
        self.assertEqual(usage.output_tokens, EXPECTED_OUT)
        self.assertEqual(usage.cache_read_tokens, EXPECTED_CR)
        self.assertEqual(usage.cache_write_tokens, EXPECTED_CW)
        self.assertEqual(usage.estimated_tokens, 0)
        self.assertEqual(usage.models[MODEL]["input"], EXPECTED_IN)

    def test_ut2_estimated_share_marked_when_usage_omitted(self):
        text = _jsonl(
            assistant_rec("a0", 100, 50, 0, 0),
            # Provider omitted usage (all-zero): chars/4 estimate, marked.
            assistant_rec(
                "a1", 0, 0, 0, 0,
                content=[{"type": "text", "text": "x" * 11}],  # ceil(11/4) = 3
            ),
        )
        usage = fa_usage.extract_from_text(text)
        self.assertEqual(usage.input_tokens, 100)
        self.assertEqual(usage.output_tokens, 50)
        self.assertEqual(usage.estimated_output_tokens, 3)

    def test_ut2_missing_session_dir_warns_and_stays_zero(self):
        usage = fa_usage.extract_from_dir(Path(self.tmp.name) / "nope")
        self.assertEqual(usage.total_tokens(), 0)
        self.assertTrue(usage.warnings)

    def test_ut2_corrupt_lines_fail_soft(self):
        text = "{not json\n" + _jsonl(assistant_rec("a0", 7, 3, 0, 0))
        usage = fa_usage.extract_from_text(text)
        self.assertEqual((usage.input_tokens, usage.output_tokens), (7, 3))
        self.assertEqual(usage.warnings, [])


    def test_float_usage_parsed_not_estimated(self):
        # Some providers emit floats (310.0); they are real usage and must
        # not silently become 0 and reroute into the estimate path.
        rec = {"type": "message", "message": {
            "role": "assistant", "model": "m",
            "content": [{"type": "text", "text": "hello"}],
            "usage": {"input": 310.0, "output": 80.5}}}
        usage = fa_usage.extract_from_text(json.dumps(rec))
        self.assertEqual(usage.input_tokens, 310)
        self.assertEqual(usage.output_tokens, 81)
        self.assertEqual(usage.estimated_tokens, 0)
        self.assertEqual(usage.warnings, [])

    def test_malformed_usage_warns_and_estimates(self):
        # A record that LOOKS like it carries usage but has no numeric
        # token fields: loud warning + chars/4 estimate, not a silent zero.
        rec = {"type": "message", "message": {
            "role": "assistant", "model": "m",
            "content": [{"type": "text", "text": "hello world"}],
            "usage": {"input": "many", "output": None}}}
        usage = fa_usage.extract_from_text(json.dumps(rec))
        self.assertTrue(any("malformed usage" in w for w in usage.warnings))
        self.assertEqual(usage.estimated_tokens, 3)  # ceil(11/4)


class PricingTest(unittest.TestCase):
    def setUp(self):
        self.pricing = fa_usage.load_pricing(_BENCH / "pricing.json")
        self.assertTrue(self.pricing, "bench/pricing.json must load")

    def test_ut3_cost_math_input_output_cache(self):
        entry = fa_usage.price_entry(self.pricing, MODEL)
        cost = fa_usage.cost_usd(entry, EXPECTED_IN, EXPECTED_OUT, EXPECTED_CR, EXPECTED_CW)
        self.assertAlmostEqual(cost, EXPECTED_COST, places=11)

    def test_ut3_price_lookup_is_case_insensitive(self):
        self.assertIsNotNone(fa_usage.price_entry(self.pricing, "GLM-5.3-Flash"))

    def test_e3_unknown_model_prices_none_never_zero(self):
        self.assertIsNone(fa_usage.price_entry(self.pricing, "mystery-model"))
        self.assertIsNone(fa_usage.price_entry(self.pricing, ""))
        self.assertIsNone(
            fa_usage.cost_usd(fa_usage.price_entry(self.pricing, "mystery-model"), 100, 100)
        )

    def test_harbor_unpriced_model_sets_cost_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            sessions = Path(tmp) / "fah-sessions"
            sessions.mkdir()
            (sessions / "s.jsonl").write_text(_jsonl(assistant_rec("a0", 10, 5, 0, 0, model="mystery-model")))
            agent = harbor_fa_agent.FaAgent.__new__(harbor_fa_agent.FaAgent)
            agent.logs_dir = Path(tmp)
            context = harbor_fa_agent.AgentContext()
            agent.populate_context_post_run(context)
            # 10 input + 5 output, unpriced model: tokens exact, cost n/a.
            self.assertEqual(context.n_input_tokens, 10)
            self.assertEqual(context.n_output_tokens, 5)
            self.assertIsNone(context.cost_usd)


class HarborStubHygieneTest(unittest.TestCase):
    """gh-1535 regression: the harbor sys.modules stub in this module must
    not poison tests loaded later in the same `unittest discover` process.

    HarborParityTest / HarnessArtifactIsolationTest (test_fa_agent_timeout)
    exec bench/harbor_fa/fa_agent.py and construct FaAgent(logs_dir); when
    real harbor is installed they need the REAL BaseInstalledAgent with its
    (logs_dir, ...) constructor — the bare-stub base raises
    "FaAgent() takes no arguments". When harbor is absent this module's
    own ITs still run against the stub, so nothing is skipped there.
    """

    def test_fa_agent_binds_real_base_when_harbor_installed(self):
        if not _real_harbor_available():
            # gh-1535 rework: never silently disengage in the regressed
            # state. An installed harbor distribution whose import resolves
            # to the stub parked in sys.modules IS the bug — fail with the
            # exact signal the parity tests would hit.
            if _harbor_distribution_present():
                self.fail(
                    "harbor is installed but the sys.modules stub is bound"
                    " (gh-1535 regression: FaAgent(logs_dir) would raise"
                    " 'takes no arguments' in test_fa_agent_timeout)"
                )
            self.skipTest("real harbor not installed")
        import harbor.agents.installed.base as real_base

        self.assertIs(
            harbor_fa_agent.BaseInstalledAgent, real_base.BaseInstalledAgent
        )
        # gh-1535: exercise the REAL constructor shape the parity suite
        # uses — FaAgent(logs_dir). __new__ + attribute assignment would
        # pass even against the bare-stub base (no __init__), masking the
        # regression this test exists to catch.
        agent = harbor_fa_agent.FaAgent(Path("/nonexistent/logs"))
        self.assertEqual(agent.logs_dir, Path("/nonexistent/logs"))


if __name__ == "__main__":
    unittest.main()
