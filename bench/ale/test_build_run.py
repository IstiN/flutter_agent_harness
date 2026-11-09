"""build_run.py tests (issue #1686) — stage/plan/check-env/command.

The pins these tests enforce are the gh-1686 recon's AC1 output: a
drifted --ale-sha must fail the plan in one setup minute (sha256 check
on the docker allowlist), and the quota discipline (≤3 shards,
confirm-gate on the full allowlist, allowlist membership) is enforced
by the planner, not by operator discipline.
"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_run  # noqa: E402


def _write_allowlist(root: Path, tasks: list[str]) -> None:
    allow = root / "selected_tasks" / "docker_support.txt"
    allow.parent.mkdir(parents=True, exist_ok=True)
    allow.write_text(
        "# allowlist header comment\n" + "\n".join(tasks) + "\n", encoding="utf-8"
    )
    # plan --check-pins compares against the v1.1 pin; tests use
    # --no-check-pins except the dedicated drift test.


def _allowlist_bytes(tasks: list[str]) -> bytes:
    return (
        "# allowlist header comment\n" + "\n".join(tasks) + "\n"
    ).encode()


class PlanTest(unittest.TestCase):
    TASKS = [
        "computing_math/cost_optimization_1",  # the declared smoke task
        "a/t2",
        "b/t3",
        "b/t4",
        "c/t5",
    ]

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ale = Path(self.tmp.name) / "ale"
        _write_allowlist(self.ale, self.TASKS)
        self.out = Path(self.tmp.name) / "github_output.txt"
        self.rc = Path(self.tmp.name) / "run-config.json"

    def tearDown(self):
        self.tmp.cleanup()

    def _plan(self, **overrides):
        args = {
            "subset": "tasks",
            "tasks": ",".join(self.TASKS),
            "ale_root": str(self.ale),
            "shards": 2,
            "max_attempts": 1,
            "confirm_full": "",
            "fa_commit": "abc1234",
            "provider": "zai-glm-5.3-flash",
            "model": "glm-5.3-flash",
            "bundle_url": "https://example.com/fa.tar.gz",
            "bundle_sha256": "deadbeef",
            "check_pins": False,
            "ale_sha": build_run.DEFAULT_ALE_SHA,
            "out": str(self.out),
            "run_config_out": str(self.rc),
            "cmd": "plan",
            "func": build_run.cmd_plan,
        }
        args.update(overrides)

        class _Ns:
            pass

        ns = _Ns()
        for key, value in args.items():
            setattr(ns, key, value)
        return build_run.cmd_plan(ns)

    def _outputs(self):
        return dict(
            line.split("=", 1)
            for line in self.out.read_text().splitlines()
            if "=" in line
        )

    def test_plan_slices_all_tasks_and_writes_shard_files(self):
        self._plan(shards=2)
        outputs = self._outputs()
        self.assertEqual(outputs["count"], "5")
        matrix = json.loads(outputs["matrix"])["include"]
        self.assertEqual(len(matrix), 2)
        self.assertEqual(matrix[0]["count"] + matrix[1]["count"], 5)
        # Slice files land in the checkout, experiments reference them.
        self.assertTrue((self.ale / "selected_tasks" / "fa-shard-0.txt").is_file())
        exp = (self.ale / "exp-fa-shard-0.yaml").read_text()
        self.assertIn("configs/agents/fa.yaml", exp)
        self.assertIn("configs/environments/docker.yaml", exp)
        self.assertIn("selected_tasks/fa-shard-0.txt", exp)
        self.assertIn("output:", exp)
        self.assertIn(".logs/ale-shard-0", exp)
        self.assertIn("max_attempts: 1", exp)

    def test_plan_omits_wall_time_budget_fidelity(self):
        # The builder never emits a wall_time_s override — task-card
        # budgets (18000s-class) govern (mls precedent).
        self._plan(shards=1)
        exp = (self.ale / "exp-fa-shard-0.yaml").read_text()
        self.assertNotIn("wall_time_s", exp)

    def test_shards_capped_at_quota_limit(self):
        with self.assertRaises(SystemExit):
            self._plan(shards=build_run.MAX_PARALLEL_SHARDS + 1)

    def test_unknown_task_fails_loud_naming_it(self):
        with self.assertRaises(SystemExit):
            self._plan(tasks="a/t1,does_not_exist/x")

    def test_full_docker_run_requires_confirm_yes(self):
        with self.assertRaises(SystemExit):
            self._plan(subset="docker", tasks="")
        # And with the gate satisfied it plans the whole allowlist.
        self._plan(subset="docker", tasks="", confirm_full="yes")
        self.assertEqual(self._outputs()["count"], "5")

    def test_smoke_uses_the_declared_smoke_task(self):
        self._plan(subset="smoke", tasks="")
        self.assertEqual(
            self._outputs()["count"], str(len(build_run.SMOKE_TASKS))
        )

    def test_pin_drift_fails_the_plan(self):
        # A different allowlist content than the v1.1 pin = the ale-sha
        # no longer matches the assets — must fail WITH --check-pins.
        with self.assertRaises(SystemExit):
            self._plan(check_pins=True)

    def test_identity_bundle_carries_every_pin(self):
        self._plan()
        identity = json.loads(self.rc.read_text())
        self.assertEqual(identity["ale_sha"], build_run.DEFAULT_ALE_SHA)
        self.assertEqual(identity["docker_image_digest"], build_run.DOCKER_IMAGE_DIGEST)
        self.assertEqual(
            identity["task_data_archive_revision"],
            build_run.TASK_DATA_ARCHIVE_REVISION,
        )
        self.assertIn("budget", identity)
        self.assertEqual(identity["shards"], 2)


class StageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ale = Path(self.tmp.name) / "ale"
        (self.ale / "ale_run" / "orchestration").mkdir(parents=True)
        (self.ale / "ale_run" / "orchestration" / "factory.py").write_text("")

    def tearDown(self):
        self.tmp.cleanup()

    def _stage(self, **overrides):
        args = {
            "ale_root": str(self.ale),
            "provider_type": "zai",
            "provider_config": '{"baseUrl":"https://x","model":"m","apiKeyEnvVar":"FA_KEY_API_Z_AI_Z_AI"}',
            "model": "glm-5.3-flash",
            "bundle_url": "https://example.com/fa-linux-x64.tar.gz",
            "bundle_sha256": "cafe" * 16,
            "tool_call_timeout_ms": 120000,
            "progress_extension": False,
            "stall_gap_sec": None,
            "abs_ceiling_sec": None,
            "external_cap_sec": None,
            "cmd": "stage",
            "func": build_run.cmd_stage,
        }
        args.update(overrides)

        class _Ns:
            pass

        ns = _Ns()
        for key, value in args.items():
            setattr(ns, key, value)
        return build_run.cmd_stage(ns)

    def test_stage_vendors_package_files_verbatim(self):
        self._stage()
        pkg = self.ale / "ale_run" / "agents" / "fa_code"
        for name in build_run.PKG_FILES + ("fa_agent_timeout.py",):
            self.assertTrue((pkg / name).is_file(), name)
        src = Path(build_run.__file__).resolve().parent
        for name in build_run.PKG_FILES:
            self.assertEqual(
                (pkg / name).read_bytes(), (src / name).read_bytes(), name
            )
        # The staged copy lands NEXT TO deployer.py — the relative-import
        # route deployer.py tries first.
        self.assertTrue((pkg / "fa_agent_timeout.py").is_file())

    def test_stage_writes_preset_with_fqn_and_env_key_ref(self):
        self._stage()
        preset = (self.ale / "configs" / "agents" / "fa.yaml").read_text()
        self.assertIn("harness: ale_run.agents.fa_code.deployer.FaDeployer", preset)
        self.assertIn('api_key: "${env:FA_BENCH_ZAI_KEY}"', preset)
        # Key material never rides the preset — only the env var NAME.
        self.assertNotIn("sk-", preset)
        self.assertIn("bundle_url: https://example.com/fa-linux-x64.tar.gz", preset)
        self.assertIn("bundle_sha256: " + "cafe" * 16, preset)

    def test_stage_knobs_landed_in_preset(self):
        self._stage(
            progress_extension=True, stall_gap_sec=240.0, abs_ceiling_sec=18000.0
        )
        preset = (self.ale / "configs" / "agents" / "fa.yaml").read_text()
        self.assertIn("progress_extension: true", preset)
        self.assertIn("stall_gap_sec: 240.0", preset)
        self.assertIn("abs_ceiling_sec: 18000.0", preset)

    def test_stage_refuses_non_ale_root(self):
        with self.assertRaises(SystemExit):
            self._stage(ale_root=str(self.tmp.name))

    # ── CodeQL taint barriers (gh-1686 review) ────────────────────────
    # A password-shaped value supplied where an env var NAME belongs is
    # refused BEFORE it can reach the ::error log line or the preset
    # file — and nothing key-shaped ever reaches the preset.

    def test_stage_rejects_removed_api_key_env_flag(self):
        # CodeQL round 3: the env-var NAME is a config.py constant — the
        # flag no longer exists, so a caller passing it dies at argparse
        # (fail-loud) before any code runs.
        with self.assertRaises(SystemExit):
            build_run.main([
                "stage", "--ale-root", str(self.ale),
                "--provider-config", '{"baseUrl":"https://x","model":"m"}',
                "--api-key-env", "FA_BENCH_ZAI_KEY",
                "--bundle-url", "https://x/y.tar.gz",
            ])
        self.assertFalse(
            (self.ale / "configs" / "agents" / "fa.yaml").exists()
        )

    def test_stage_refuses_keylike_field_in_provider_config(self):
        for hostile in (
            '{"baseUrl":"https://x","model":"m","apiKey":"sk-123"}',
            '{"baseUrl":"https://x","model":"m","token":"tok-123"}',
            '{"baseUrl":"https://x","model":"m","apiKeyEnvVar":"sk-123"}',
            '{"baseUrl":"http://x","model":"m"}',
            '{"baseUrl":"https://x","model":"m","mystery":"v"}',
        ):
            with self.subTest(hostile=hostile):
                with self.assertRaises(SystemExit):
                    self._stage(provider_config=hostile)
        self.assertFalse(
            (self.ale / "configs" / "agents" / "fa.yaml").exists()
        )

    def test_valid_provider_config_rebuilt_keyfree_into_preset(self):
        self._stage(provider_config='{"baseUrl":"https://api.z.ai/v4","model":"glm-5.3-flash","apiKeyEnvVar":"FA_KEY_API_Z_AI_Z_AI","contextWindow":200000,"maxTokens":16384}')
        preset = (self.ale / "configs" / "agents" / "fa.yaml").read_text()
        # The api-key line is the ${env:NAME} reference — never a value.
        self.assertIn('api_key: "${env:FA_BENCH_ZAI_KEY}"', preset)
        self.assertNotIn("sk-", preset)
        # The rebuilt, key-free config fields (escaped JSON in the YAML).
        self.assertIn("FA_KEY_API_Z_AI_Z_AI", preset)
        self.assertIn("https://api.z.ai/v4", preset)
        self.assertIn("200000", preset)


class CheckEnvTest(unittest.TestCase):
    def _check(self, env, stage="plan"):
        old = {k: os.environ.get(k) for k in ("FA_BENCH_ZAI_KEY", "HF_TOKEN")}
        try:
            for key, value in old.items():
                os.environ.pop(key, None)
            os.environ.update({k: v for k, v in env.items() if v is not None})

            class _Ns:
                pass

            ns = _Ns()
            ns.stage = stage
            ns.func = build_run.cmd_check_env
            ns.cmd = "check-env"
            return build_run.cmd_check_env(ns)
        finally:
            for key, value in old.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    def test_plan_stage_needs_only_the_provider_key(self):
        self.assertEqual(self._check({"FA_BENCH_ZAI_KEY": "x"}), 0)
        with self.assertRaises(SystemExit):
            self._check({})

    def test_check_env_rejects_removed_api_key_env_flag(self):
        with self.assertRaises(SystemExit):
            build_run.main(["check-env", "--api-key-env", "FA_BENCH_ZAI_KEY"])

    def test_agent_stage_also_needs_hf_token(self):
        self.assertEqual(
            self._check({"FA_BENCH_ZAI_KEY": "x", "HF_TOKEN": "hf_x"}, stage="agent"), 0
        )
        with self.assertRaises(SystemExit):
            self._check({"FA_BENCH_ZAI_KEY": "x"}, stage="agent")


class CommandTest(unittest.TestCase):
    def test_command_emits_cd_and_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            exp = Path(tmp) / "ale" / "exp-fa-shard-0.yaml"
            exp.parent.mkdir(parents=True)
            exp.write_text("")

            class _Ns:
                pass

            ns = _Ns()
            ns.ale_root = str(Path(tmp) / "ale")
            ns.exp = str(exp)
            ns.func = build_run.cmd_command
            ns.cmd = "command"
            # capture stdout
            import contextlib
            import io

            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                build_run.cmd_command(ns)
            out = buf.getvalue().strip()
        self.assertIn("uv run python -m ale_run run exp-fa-shard-0.yaml", out)
        self.assertTrue(out.startswith("cd "))


class PinsTest(unittest.TestCase):
    def test_pinned_digests_match_the_v1_1_manifest(self):
        # Byte-pins from releases/v1.1/assets.json @ DEFAULT_ALE_SHA —
        # verified live 2026-11-09. A change here must be a deliberate
        # re-pin, never a silent drift.
        self.assertEqual(build_run.DEFAULT_ALE_SHA, "2e91edd3cd26baa35a38127c90c8e5241dfbe62f")
        self.assertTrue(build_run.DOCKER_IMAGE_DIGEST.startswith("sha256:0b223c50"))
        self.assertEqual(build_run.TASK_DATA_ARCHIVE_REVISION, "46225f1caa4f43c275cc06a5da47d886f64feb6c")
        self.assertEqual(build_run.MAX_PARALLEL_SHARDS, 3)


if __name__ == "__main__":
    unittest.main()
