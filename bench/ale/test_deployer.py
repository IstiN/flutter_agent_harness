"""FaDeployer unit tests (issue #1686) — offline, stdlib-only.

deployer.py imports ale_run.base_interface at module load (its runtime).
The bench CI gate is stdlib-only, so these tests register a minimal
stub of that module FIRST — with the exact constructor surface the
deployer consumes. What the stub pins is the mapping contract (which
FIELD NAMES the deployer sets on each model); the real pydantic models
are cross-validated upstream-side (bench/harbor_fa/test_atif_contract.py
against the same fixture + live runs).
"""
import json
import sys
import time
import types
import unittest
from pathlib import Path

_BENCH_DIR = Path(__file__).resolve().parents[1]


def _install_ale_stub() -> None:
    if "ale_run.base_interface" in sys.modules:
        return
    ale_pkg = types.ModuleType("ale_run")
    bi = types.ModuleType("ale_run.base_interface")

    class BaseAgentDeployer:  # minimal runtime surface used by tests
        def __init__(self, executor):
            self.executor = executor
            self.config = executor.config

    class AgentRunResult:
        def __init__(self, status, **kwargs):
            self.status = status
            for key, value in kwargs.items():
                setattr(self, key, value)

    class _Fields:
        _FIELDS: tuple[str, ...] = ()

        def __init__(self, **kwargs):
            unknown = set(kwargs) - set(self._FIELDS)
            if unknown:
                raise TypeError(f"unexpected fields: {sorted(unknown)}")
            for field in self._FIELDS:
                setattr(self, field, kwargs.get(field))

    class ContentPart(_Fields):
        _FIELDS = ("type", "text", "image")

    class ImageSource(_Fields):
        _FIELDS = ("type", "path", "url", "data", "media_type", "alt_text")

    class ToolCall(_Fields):
        _FIELDS = ("id", "name", "arguments")

    class ToolResult(_Fields):
        _FIELDS = ("tool_call_id", "content", "is_error")

    class Observation(_Fields):
        _FIELDS = ("results", "error")

    class StepMetrics(_Fields):
        _FIELDS = (
            "input_tokens",
            "output_tokens",
            "cache_read_tokens",
            "cache_creation_tokens",
            "cost_usd",
            "duration_ms",
        )

    class TrajectoryBuilder:  # only a parse_artifacts type hint
        pass

    for name, obj in (
        ("AgentRunResult", AgentRunResult),
        ("BaseAgentDeployer", BaseAgentDeployer),
        ("ContentPart", ContentPart),
        ("ImageSource", ImageSource),
        ("ToolCall", ToolCall),
        ("ToolResult", ToolResult),
        ("Observation", Observation),
        ("StepMetrics", StepMetrics),
        ("TrajectoryBuilder", TrajectoryBuilder),
    ):
        setattr(bi, name, obj)
    ale_pkg.base_interface = bi
    sys.modules["ale_run"] = ale_pkg
    sys.modules["ale_run.base_interface"] = bi


_install_ale_stub()

# bench/ale/test_deployer.py → parents: [0]=bench/ale, [1]=bench, [2]=root.
_ROOT = str(Path(__file__).resolve().parents[2])
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from bench.ale import config as fa_config  # noqa: E402
from bench.ale import deployer as fa_deployer  # noqa: E402
from fa_agent_timeout import TimeoutKnobs, resolve_deadline  # noqa: E402

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "atif_sample.json"


class DeployerClassAttrsTest(unittest.TestCase):
    def test_sandbox_executor_only(self):
        # The semantic pin: fa's native bash/file tools must run ON the
        # task machine — only the sandbox executor places the deployer
        # inside the VM. local/docker would aim fa's tools at the wrong
        # host.
        self.assertEqual(fa_deployer.FaDeployer.default_executor, "sandbox")
        self.assertEqual(
            fa_deployer.FaDeployer.supported_executors, frozenset({"sandbox"})
        )

    def test_hot_artifacts_tail_the_streams(self):
        self.assertEqual(
            fa_deployer.FaDeployer.hot_artifacts,
            ("fa-stdout.log", "stderr.log"),
        )


class KnobEnvTest(unittest.TestCase):
    """Config knobs → bench/fa_agent_timeout.py env contract."""

    def test_defaults_export_no_clock(self):
        self.assertEqual(fa_deployer.FaDeployer._knob_env(None, fa_config.FaConfig()), {})

    def test_declared_knobs_map_onto_the_contract_names(self):
        cfg = fa_config.FaConfig(
            progress_extension=True,
            stall_gap_sec=240.0,
            abs_ceiling_sec=18000.0,
            external_cap_sec=17500.0,
        )
        env = fa_deployer.FaDeployer._knob_env(None, cfg)
        self.assertEqual(
            env,
            {
                "FA_PROGRESS_EXTENSION": "1",
                "FA_STALL_GAP_SEC": "240.0",
                "FA_AGENT_TIMEOUT_ABS_CEILING_SEC": "18000.0",
                "FA_EXTERNAL_CAP_SEC": "17500.0",
            },
        )

    def test_resolve_deadline_folds_min_external_and_knobs(self):
        # AGENTS.md round-3: effective cap = min(external, knobs),
        # external wins ties, no inputs = no deadline at all. The knob
        # side only participates with the progress extension ON (see
        # the coherence guard test below).
        cfg = fa_config.FaConfig(
            progress_extension=True,
            abs_ceiling_sec=1000.0,
            external_cap_sec=500.0,
        )
        knob_env = fa_deployer.FaDeployer._knob_env(None, cfg)
        cap, deadline = resolve_deadline(
            TimeoutKnobs.from_env(knob_env), env=knob_env
        )
        self.assertIsNotNone(cap)
        self.assertEqual(cap.effective_cap_sec, 500.0)
        self.assertEqual(cap.winning_cap_source, "external")
        self.assertIsNotNone(deadline)

        bare_env = fa_deployer.FaDeployer._knob_env(None, fa_config.FaConfig())
        cap2, deadline2 = resolve_deadline(
            TimeoutKnobs.from_env(bare_env), env=bare_env
        )
        self.assertIsNone(cap2)
        self.assertIsNone(deadline2)

    def test_watch_knobs_without_extension_fail_loud(self):
        # Without FA_PROGRESS_EXTENSION the knob module pins the
        # effective cap to the flat 360s base — a half-declared watch
        # would hand fa a surprise clock. The deployer must refuse.
        cfg = fa_config.FaConfig(abs_ceiling_sec=18000.0)
        with self.assertRaises(RuntimeError):
            _bare_deployer()._child_env(cfg)
        cfg = fa_config.FaConfig(stall_gap_sec=240.0)
        with self.assertRaises(RuntimeError):
            _bare_deployer()._child_env(cfg)

    def test_external_cap_alone_is_a_valid_clock(self):
        # A dispatch-level external cap needs no extension: the knob
        # module folds it directly (winning source = external).
        cfg = fa_config.FaConfig(external_cap_sec=17500.0)
        env, cap, deadline = _bare_deployer()._child_env(cfg)
        self.assertIsNotNone(cap)
        self.assertEqual(cap.effective_cap_sec, 17500.0)
        self.assertEqual(cap.winning_cap_source, "external")
        self.assertIsNotNone(deadline)


class _FakeExecutor:
    def __init__(self):
        self.env = {"PASSTHROUGH": "1"}
        self.config = None

    def cua_bridge_url(self):
        return "http://127.0.0.1:5000"


def _bare_deployer():
    deployer = fa_deployer.FaDeployer.__new__(fa_deployer.FaDeployer)
    deployer.executor = _FakeExecutor()
    return deployer


class ChildEnvTest(unittest.TestCase):
    """The child env dict carries the provider preconfig + key verbatim
    (dict transport — no shell lines, so no base64 twins) and a missing
    key stays ABSENT, never empty."""

    def test_provider_and_key_injected_from_config(self):
        cfg = fa_config.FaConfig(api_key="sk-test-value")
        env, cap, deadline = _bare_deployer()._child_env(cfg)
        self.assertEqual(env["FA_PROVIDER_TYPE"], "zai")
        self.assertEqual(env["FA_PROVIDER_CONFIG"], cfg.provider_config)
        self.assertEqual(env["FA_KEY_API_Z_AI_Z_AI"], "sk-test-value")
        self.assertEqual(env["FAH_JOB_LOG_DIR"], "/tmp/fa-harness-artifacts/bash_jobs")
        self.assertEqual(env["PASSTHROUGH"], "1")
        self.assertIsNone(cap)
        self.assertIsNone(deadline)

    def test_missing_key_leaves_env_var_absent_not_empty(self):
        env, _, _ = _bare_deployer()._child_env(fa_config.FaConfig(api_key=None))
        self.assertNotIn("FA_KEY_API_Z_AI_Z_AI", env)

    def test_deadline_exported_only_when_knobs_declared(self):
        env, _, _ = _bare_deployer()._child_env(
            fa_config.FaConfig(progress_extension=True, abs_ceiling_sec=3600.0)
        )
        self.assertIn("FA_DEADLINE_EPOCH_MS", env)


class AtifMappingTest(unittest.TestCase):
    """ATIF-v1.7 → builder kwargs (harbor-contract fixture)."""

    @classmethod
    def setUpClass(cls):
        cls.data = json.loads(FIXTURE.read_text())

    def _step(self, step_id):
        return next(s for s in self.data["steps"] if s["step_id"] == step_id)

    def test_agent_step_with_tool_call_and_observation(self):
        kwargs = fa_deployer.atif_step_kwargs(self._step(3))
        self.assertEqual(kwargs["source"], "agent")
        self.assertEqual(kwargs["tool_calls"][0].id, "c1")
        self.assertEqual(kwargs["tool_calls"][0].name, "bash")
        self.assertEqual(kwargs["tool_calls"][0].arguments, {"cmd": "ls"})
        result = kwargs["observation"].results[0]
        self.assertEqual(result.tool_call_id, "c1")
        self.assertEqual(result.content[0].text, "files listing result")
        self.assertFalse(result.is_error)

    def test_agent_step_with_metrics_and_reasoning(self):
        kwargs = fa_deployer.atif_step_kwargs(self._step(2))
        self.assertEqual(kwargs["source"], "agent")
        self.assertEqual(kwargs["message"], "The answer")
        self.assertEqual(kwargs["reasoning"], "let me think")
        m = kwargs["metrics"]
        self.assertEqual(m.input_tokens, 100)
        self.assertEqual(m.output_tokens, 20)
        self.assertEqual(m.cache_read_tokens, 30)
        self.assertEqual(m.cost_usd, 0.5)

    def test_user_and_system_steps_carry_no_agent_only_fields(self):
        user_kwargs = fa_deployer.atif_step_kwargs(self._step(1))
        self.assertEqual(user_kwargs, {"source": "user", "message": "list files"})
        sys_kwargs = fa_deployer.atif_step_kwargs(self._step(5))
        self.assertEqual(sys_kwargs["source"], "system")
        self.assertNotIn("tool_calls", sys_kwargs)
        self.assertNotIn("metrics", sys_kwargs)

    def test_non_json_tool_arguments_fall_back_to_empty_dict(self):
        # fixture step 4: arguments absent (extra.raw_arguments carries
        # the unparsable string) — the mapping must not raise.
        kwargs = fa_deployer.atif_step_kwargs(self._step(4))
        self.assertEqual(kwargs["tool_calls"][0].arguments, {})

    def test_unknown_source_maps_to_system(self):
        kwargs = fa_deployer.atif_step_kwargs({"source": "martian", "message": "hi"})
        self.assertEqual(kwargs["source"], "system")


class AuditTest(unittest.TestCase):
    def test_audit_records_cap_resolution_without_key_material(self):
        import tempfile

        cfg = fa_config.FaConfig(
            api_key="sk-test-value",
            progress_extension=True,
            abs_ceiling_sec=3600.0,
        )
        knob_env = fa_deployer.FaDeployer._knob_env(None, cfg)
        cap, _ = resolve_deadline(TimeoutKnobs.from_env(knob_env), env=knob_env)

        deployer = _bare_deployer()

        class _Proc:
            returncode = 0

            def poll(self):
                return 0

        with tempfile.TemporaryDirectory() as tmp:
            deployer._write_audit(
                Path(tmp), cfg, cap, "completed", _Proc(),
                t0=time.monotonic() - 5, cancelled=False,
            )
            audit = json.loads(
                (Path(tmp) / "fa-timeout-metadata.json").read_text()
            )
        self.assertEqual(audit["outcome"], "completed")
        self.assertEqual(audit["cap_resolution"]["effective_cap_sec"], 3600.0)
        self.assertEqual(audit["cap_resolution"]["winning_cap_source"], "knobs")
        blob = json.dumps(audit)
        self.assertNotIn("sk-test-value", blob)
        self.assertNotIn("FA_KEY_API_Z_AI_Z_AI", blob)

    def test_audit_without_cap_records_null_resolution(self):
        import tempfile

        cfg = fa_config.FaConfig()
        deployer = _bare_deployer()

        class _Proc:
            returncode = None

            def poll(self):
                return None

        with tempfile.TemporaryDirectory() as tmp:
            deployer._write_audit(
                Path(tmp), cfg, None, "external_kill", _Proc(),
                t0=time.monotonic(), cancelled=True,
            )
            audit = json.loads(
                (Path(tmp) / "fa-timeout-metadata.json").read_text()
            )
        self.assertEqual(audit["outcome"], "external_kill")
        self.assertTrue(audit["cancelled"])
        self.assertIsNone(audit["cap_resolution"])


class FahConfigTest(unittest.TestCase):
    def test_written_config_is_valid_yaml_with_bridge_fields(self):
        import tempfile

        cfg = fa_config.FaConfig()
        deployer = _bare_deployer()

        class _Sandbox:
            is_linux = True
            node = "/usr/bin/node"
            mcp_server_dir = "/opt/cua_mcp_server"

        # _write_fah_config imports cua_bridge_env from ale_run.agents —
        # stub the one function it consumes (CUA_SERVER_URL contract).
        agents_pkg = types.ModuleType("ale_run.agents")
        boot = types.ModuleType("ale_run.agents._bootstrap")

        def cua_bridge_env(executor):
            return {
                "CUA_SERVER_URL": executor.cua_bridge_url(),
                "CUA_SERVER_PLATFORM": "linux",
            }

        boot.cua_bridge_env = cua_bridge_env
        agents_pkg._bootstrap = boot
        sys.modules["ale_run.agents"] = agents_pkg
        sys.modules["ale_run.agents._bootstrap"] = boot

        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            original_home = Path.home
            Path.home = staticmethod(lambda: home)  # type: ignore[attr-defined]
            try:
                deployer._write_fah_config(cfg, _Sandbox())
            finally:
                Path.home = original_home  # type: ignore[attr-defined]
            text = (home / ".fah" / "config.yaml").read_text()

        # Strict-parsable by fa's config parser: check the structural
        # facts the deployer is responsible for (approve + bridge wiring
        # read from the sandbox handle, never hardcoded).
        self.assertIn("approvalMode: autopilot", text)
        self.assertIn('command: "/usr/bin/node"', text)
        self.assertIn('"/opt/cua_mcp_server/src/index.js"', text)
        self.assertIn('"CUA_SERVER_URL": "http://127.0.0.1:5000"', text)
        self.assertIn('"CUA_SERVER_PLATFORM": "linux"', text)
        self.assertIn("toolCallTimeoutMs: 120000", text)


if __name__ == "__main__":
    unittest.main()
