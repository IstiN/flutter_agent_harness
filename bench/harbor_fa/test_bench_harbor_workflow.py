#!/usr/bin/env python3
"""Pins the Bench Harbor dispatch defaults (issue #1316).

AC-first: these fail on the pre-#1316 workflow (4.0 dataset / modal env /
self-hosted runner) and pass after the migration flips the defaults to
Terminal-Bench 2.1 on the default Harbor `docker` sandbox, on ubuntu-latest.
Also pins the legacy `bench.yml` 0.1.1 default (issue #1316 req 6: the tb
1.x path stays untouched) and the adapter wiring the docker default rides
on (env type reaches `harbor run -e`; the #1122 timeout knob contract).

Run: python3 -m unittest discover -s bench/harbor_fa

gh-1503: the provider-selection port of bench.yml's gh-1471 design —
the setup-job resolve step is a BYTE-CONSISTENT copy of bench.yml's
(mirrored suite below executes the block extracted from
bench-harbor.yml), the shard env consumes the resolved triple, the
run identity (run-name / job name / summary) carries provider+model,
and the free-text `model` input is replaced by the resolved
bench_model output (REG-1: the default still resolves the exact
3-field zai JSON the workflow hardcoded pre-gh-1503).
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from families import FAMILIES

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_HARBOR_YML = _REPO_ROOT / ".github" / "workflows" / "bench-harbor.yml"
_BENCH_YML = _REPO_ROOT / ".github" / "workflows" / "bench.yml"


def _input_default(workflow_text: str, name: str):
    """Reads `default:` from one workflow_dispatch input block (stdlib)."""
    m = re.search(
        rf"^      {re.escape(name)}:\n((?:        .*\n)+)", workflow_text, re.M
    )
    if not m:
        return None
    d = re.search(r"^\s+default: (.+)$", m.group(1), re.M)
    if not d:
        return None
    return d.group(1).strip().strip("'")


def _workflow_input(workflow_text: str, name: str):
    value = _input_default(workflow_text, name)
    if value is None:
        raise AssertionError(f"input `{name}` has no default in the workflow")
    return value


@unittest.skipUnless(
    _HARBOR_YML.exists(), "bench-harbor.yml not found (standalone bench checkout)"
)
class BenchHarborDefaultsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = _HARBOR_YML.read_text()

    def test_default_dataset_is_terminal_bench_2_1(self):
        # Issue #1316 req 4: default dataset is the 2.1 family; 2.0 (and
        # every other family) stays reachable via the same input.
        self.assertEqual(
            _workflow_input(self.text, "dataset"), FAMILIES["2.1"]
        )

    def test_default_cpu_env_is_docker(self):
        # Issue #1316 req 1: local docker is the default sandbox — no
        # Modal/cloud dependency for the default dispatch.
        self.assertEqual(_workflow_input(self.text, "cpu-env"), "docker")

    def test_default_cpu_runner_is_ubuntu_latest(self):
        # Issue #1316 req 1: GH runners already have docker.
        self.assertEqual(_workflow_input(self.text, "cpu-runner"), "ubuntu-latest")

    def test_adapter_and_timeout_wiring_intact(self):
        # The docker default must actually reach the harbor invocation and
        # the #1122 env contract must stay wired (issue #1316 reqs 2+5).
        self.assertIn('-e "$ENV_TYPE"', self.text)
        self.assertIn("export FA_AGENT_TIMEOUT_SEC", self.text)
        # gh-1503: the zai hardcode is gone — the provider triple arrives
        # from the setup resolve step (same wiring as bench.yml gh-1471).
        self.assertIn(
            "FA_PROVIDER_TYPE: ${{ needs.setup.outputs.provider_type }}",
            self.text,
        )
        self.assertNotIn("FA_PROVIDER_TYPE: zai", self.text)

    def test_n_concurrent_default_stays_one_with_kimi_documented(self):
        # gh-1503 req 6: 1 stays the default (z.ai rate-limit safe); the
        # kimi-safe guidance lives in the input description so the owner
        # picks the level at dispatch time.
        self.assertEqual(_workflow_input(self.text, "n-concurrent"), "1")
        description = self.text.split("n-concurrent:", 1)[1].split("\n", 2)[1]
        self.assertIn("kimi", description)


@unittest.skipUnless(
    _BENCH_YML.exists(), "bench.yml not found (standalone bench checkout)"
)
class LegacyBenchUntouchedTest(unittest.TestCase):
    def test_legacy_default_dataset_still_core_0_1_1(self):
        # Issue #1316 req 6: the tb 1.x path keeps running until a separate
        # decision retires it.
        self.assertEqual(
            _workflow_input(_BENCH_YML.read_text(), "dataset"),
            "terminal-bench-core==0.1.1",
        )


def _resolve_run_block() -> str:
    """Extracts the `run: |` block of the provider resolve step.

    Same text-slicing contract as bench/terminal_bench/test_bench_workflow.py
    (_resolve_run_block): the block is identified by its body (the
    provider_config printf), so unrelated `run:` blocks never match. The
    block is env-driven (inputs/secrets arrive via the step env), so no
    GitHub expression may appear inside.
    """
    lines = _HARBOR_YML.read_text().splitlines()
    for i, line in enumerate(lines):
        if line.strip() != "run: |":
            continue
        indent = len(line) - len(line.lstrip())
        body = []
        for candidate in lines[i + 1 :]:
            if candidate.strip() and (len(candidate) - len(candidate.lstrip())) <= indent:
                break
            body.append(candidate)
        while body and not body[-1].strip():
            body.pop()
        block = "\n".join(body)
        if "provider_config=$(printf" in block:
            break
    else:
        raise AssertionError("provider resolve step's run: | block not found in bench-harbor.yml")
    leftover = re.findall(r"\$\{\{[^}]*\}\}", block)
    assert not leftover, f"unmapped GitHub expression(s) in resolve block: {leftover}"
    return block


def _bench_yml_resolve_block() -> str:
    """bench.yml's resolve block — the byte-consistency sync contract."""
    lines = _BENCH_YML.read_text().splitlines()
    for i, line in enumerate(lines):
        if line.strip() != "run: |":
            continue
        indent = len(line) - len(line.lstrip())
        body = []
        for candidate in lines[i + 1 :]:
            if candidate.strip() and (len(candidate) - len(candidate.lstrip())) <= indent:
                break
            body.append(candidate)
        while body and not body[-1].strip():
            body.pop()
        block = "\n".join(body)
        if "provider_config=$(printf" in block:
            return block
    raise AssertionError("provider resolve step's run: | block not found in bench.yml")


def _run_resolve(
    provider="",
    zai_key="zai-test-key",
    kimi_key="kimi-test-key",
    custom_key="custom-test-key",
    provider_config="",
):
    """Runs the extracted resolve block with GITHUB_OUTPUT in a temp dir
    and all three bench secrets in env (presence-only preflight)."""
    env = dict(os.environ)
    env.update(
        {
            "PROVIDER": provider,
            "BENCH_MODEL": "glm-5.3-flash",
            "PROVIDER_CONFIG": provider_config,
            "FA_BENCH_ZAI_KEY": zai_key,
            "FA_BENCH_KIMI_KEY": kimi_key,
            "FA_BENCH_CUSTOM_KEY": custom_key,
        }
    )
    tmp = tempfile.TemporaryDirectory()
    output = Path(tmp.name) / "github_output"
    env["GITHUB_OUTPUT"] = str(output)
    driver = Path(tmp.name) / "resolve_step.sh"
    driver.write_text("#!/usr/bin/env bash\n" + _resolve_run_block() + "\n")
    proc = subprocess.run(
        ["bash", str(driver)],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    proc._tmp = tmp  # caller cleans up after reading the outputs
    proc.github_output = output
    return proc


def _resolve_outputs(proc) -> dict:
    if not proc.github_output.exists():
        return {}
    result = {}
    for line in proc.github_output.read_text().splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            result[key] = value
    proc._tmp.cleanup()
    return result


@unittest.skipUnless(
    _HARBOR_YML.exists(), "bench-harbor.yml not found (standalone bench checkout)"
)
@unittest.skipUnless(shutil.which("bash"), "bash not available")
class HarborProviderResolveStepTest(unittest.TestCase):
    """gh-1503: the setup-job resolve step is a byte-consistent copy of
    bench.yml's gh-1471 step and maps the provider choice to the full
    triple, preflighting the selected secret BEFORE any shard starts.
    Mirrors bench/terminal_bench/test_bench_workflow.py's
    ProviderResolveStepTest against the harbor copy."""

    maxDiff = None

    # REG-1 (gh-1503): the default must reproduce the exact 3-field zai
    # config the harbor shard env hardcoded pre-gh-1503.
    LEGACY_ZAI_CONFIG = (
        '{"baseUrl":"https://api.z.ai/api/coding/paas/v4",'
        '"model":"glm-5.3-flash","apiKeyEnvVar":"FA_KEY_API_Z_AI_Z_AI"}'
    )

    def test_resolve_block_is_byte_consistent_with_bench_yml(self):
        # The sync contract (cross-reference comments in both files): a
        # drifted copy would silently diverge the two bench paths.
        self.assertEqual(_resolve_run_block(), _bench_yml_resolve_block())

    def test_default_provider_is_byte_identical_to_pre_gh1503_wiring(self):
        for provider in ("", "zai-glm-5.3-flash"):
            proc = _run_resolve(provider=provider)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            outputs = _resolve_outputs(proc)
            self.assertEqual(outputs["provider_type"], "zai")
            self.assertEqual(outputs["provider_config"], self.LEGACY_ZAI_CONFIG)
            self.assertEqual(outputs["provider_key_env"], "FA_KEY_API_Z_AI_Z_AI")
            self.assertEqual(outputs["bench_model"], "glm-5.3-flash")
            self.assertEqual(outputs["run_label"], "zai-glm-5.3-flash (glm-5.3-flash)")

    def test_kimi_for_coding_resolves_the_full_triple(self):
        proc = _run_resolve(provider="kimi-for-coding")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        outputs = _resolve_outputs(proc)
        self.assertEqual(outputs["provider_type"], "kimi")
        self.assertEqual(outputs["provider_key_env"], "FA_KEY_API_KIMI_COM_BENCH")
        self.assertEqual(outputs["bench_model"], "k3-256k")
        self.assertEqual(outputs["run_label"], "kimi-for-coding (k3-256k)")
        config = json.loads(outputs["provider_config"])
        self.assertEqual(config["baseUrl"], "https://api.kimi.com/coding/v1")
        self.assertEqual(config["model"], "k3-256k")
        self.assertEqual(config["apiKeyEnvVar"], "FA_KEY_API_KIMI_COM_BENCH")
        # gh-1471 D4: the capability fields ride the config explicitly.
        self.assertEqual(config["contextWindow"], 200000)
        self.assertEqual(config["maxTokens"], 16384)

    def test_unknown_provider_fails_hard_with_no_outputs(self):
        proc = _run_resolve(provider="gpt-5")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("unknown provider", proc.stdout + proc.stderr)
        self.assertEqual(_resolve_outputs(proc), {})

    def test_missing_kimi_secret_fails_naming_the_secret(self):
        proc = _run_resolve(provider="kimi-for-coding", kimi_key="")
        self.assertNotEqual(proc.returncode, 0)
        message = proc.stdout + proc.stderr
        self.assertIn("FA_BENCH_KIMI_KEY", message)
        self.assertIn("kimi-for-coding", message)
        self.assertEqual(_resolve_outputs(proc), {})

    def test_missing_zai_secret_fails_naming_the_secret(self):
        proc = _run_resolve(provider="", zai_key="")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("FA_BENCH_ZAI_KEY", proc.stdout + proc.stderr)
        self.assertEqual(_resolve_outputs(proc), {})

    def test_key_values_never_reach_the_log(self):
        for provider in ("", "kimi-for-coding", "custom"):
            provider_config = (
                '{"baseUrl":"https://api.example.com/v1","model":"m-1"}'
                if provider == "custom"
                else ""
            )
            proc = _run_resolve(provider=provider, provider_config=provider_config)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertNotIn("zai-test-key", proc.stdout + proc.stderr)
            self.assertNotIn("kimi-test-key", proc.stdout + proc.stderr)
            self.assertNotIn("custom-test-key", proc.stdout + proc.stderr)
            _resolve_outputs(proc)

    # gh-1471 D1 / AC 2a, mirrored: the custom escape hatch — validated
    # provider-config JSON, fixed apiKeyEnvVar injection, key only from
    # FA_BENCH_CUSTOM_KEY.
    CUSTOM_CONFIG = (
        '{"type":"openai","baseUrl":"https://api.example.com/v1",'
        '"model":"m-1","contextWindow":128000,"maxTokens":8192}'
    )

    def test_custom_provider_config_flows_verbatim_with_fixed_key_env(self):
        proc = _run_resolve(provider="custom", provider_config=self.CUSTOM_CONFIG)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        outputs = _resolve_outputs(proc)
        config = json.loads(outputs["provider_config"])
        declared = json.loads(self.CUSTOM_CONFIG)
        for key, value in declared.items():
            if key == "type":
                # "type" rides the dedicated FA_PROVIDER_TYPE output, not
                # the config (the Dart preconfig whitelist rejects it).
                self.assertNotIn(key, config)
            else:
                self.assertEqual(config[key], value)
        self.assertEqual(config["apiKeyEnvVar"], "FA_KEY_BENCH_CUSTOM")
        self.assertEqual(outputs["provider_type"], "openai")
        self.assertEqual(outputs["provider_key_env"], "FA_KEY_BENCH_CUSTOM")
        self.assertEqual(outputs["bench_model"], "m-1")
        self.assertEqual(outputs["run_label"], "custom (m-1)")

    def test_custom_rejects_non_https_base_url(self):
        proc = _run_resolve(
            provider="custom",
            provider_config='{"baseUrl":"http://api.example.com/v1","model":"m-1"}',
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("https://", proc.stdout + proc.stderr)
        self.assertEqual(_resolve_outputs(proc), {})

    def test_custom_rejects_key_like_fields(self):
        # The key must never ride a dispatch input — run metadata is
        # visible. apiKey/key/token/secret (any case, any depth) hard-fail.
        for config in (
            '{"baseUrl":"https://api.example.com/v1","model":"m-1","apiKey":"sk-leaked"}',
            '{"baseUrl":"https://api.example.com/v1","model":"m-1",'
            '"headers":{"accessToken":"sk-leaked"}}',
        ):
            with self.subTest(config=config):
                proc = _run_resolve(provider="custom", provider_config=config)
                self.assertNotEqual(proc.returncode, 0, config)
                self.assertNotIn("sk-leaked", proc.stdout + proc.stderr)
                self.assertEqual(_resolve_outputs(proc), {})

    def test_custom_rejects_invalid_json_and_missing_fields(self):
        for config in (
            "not json {",
            '["baseUrl"]',
            '{"model":"m-1"}',
            '{"baseUrl":"https://api.example.com/v1"}',
        ):
            with self.subTest(config=config):
                proc = _run_resolve(provider="custom", provider_config=config)
                self.assertNotEqual(proc.returncode, 0, config)
                self.assertIn("provider-config", proc.stdout + proc.stderr)
                self.assertEqual(_resolve_outputs(proc), {})

    def test_custom_missing_secret_fails_naming_the_secret(self):
        proc = _run_resolve(
            provider="custom", provider_config=self.CUSTOM_CONFIG, custom_key=""
        )
        self.assertNotEqual(proc.returncode, 0)
        message = proc.stdout + proc.stderr
        self.assertIn("FA_BENCH_CUSTOM_KEY", message)
        self.assertIn("custom", message)
        self.assertEqual(_resolve_outputs(proc), {})


@unittest.skipUnless(
    _HARBOR_YML.exists(), "bench-harbor.yml not found (standalone bench checkout)"
)
class HarborProviderSelectionShapeTest(unittest.TestCase):
    """gh-1503 wiring: the provider choice input, the resolved env in the
    shard step, the provider+model in the run identity, and the secret
    preflight before any shard starts (mirror of #1475's shape tests)."""

    @classmethod
    def setUpClass(cls):
        cls.text = _HARBOR_YML.read_text()

    def test_provider_choice_input_live_with_zai_default(self):
        self.assertRegex(
            self.text,
            r"provider:\n(?:[^\n]*\n){1,5}\s+default: 'zai-glm-5.3-flash'",
        )
        self.assertIn("type: choice", self.text)
        self.assertIn("- 'kimi-for-coding'", self.text)
        self.assertIn("- 'custom'", self.text)
        self.assertRegex(
            self.text,
            r"provider-config:\n(?:[^\n]*\n){1,4}\s+default: ''",
        )

    def test_free_text_model_input_is_gone(self):
        # gh-1503 req 4: the model is derived from the provider (the
        # custom provider-config declares it), so the free-text input —
        # a silent mislabeling footgun — is dropped entirely.
        self.assertNotIn("inputs.model", self.text)
        self.assertIsNone(_input_default(self.text, "model"))

    def test_setup_job_exports_the_resolved_provider(self):
        for output in (
            "provider_type: ${{ steps.provider.outputs.provider_type }}",
            "provider_config: ${{ steps.provider.outputs.provider_config }}",
            "provider_key_env: ${{ steps.provider.outputs.provider_key_env }}",
            "bench_model: ${{ steps.provider.outputs.bench_model }}",
            "run_label: ${{ steps.provider.outputs.run_label }}",
        ):
            self.assertIn(output, self.text)

    def test_resolve_step_preflights_all_three_bench_secrets(self):
        # The preflight reads all three secrets via env (presence only)
        # and runs in the setup job — before the bundle builds or any
        # shard starts.
        resolve_env = self.text.split('id: provider', 1)[1].split('run: |', 1)[0]
        self.assertIn("FA_BENCH_ZAI_KEY: ${{ secrets.FA_BENCH_ZAI_KEY }}", resolve_env)
        self.assertIn("FA_BENCH_KIMI_KEY: ${{ secrets.FA_BENCH_KIMI_KEY }}", resolve_env)
        self.assertIn("FA_BENCH_CUSTOM_KEY: ${{ secrets.FA_BENCH_CUSTOM_KEY }}", resolve_env)
        self.assertIn("PROVIDER_CONFIG: ${{ inputs.provider-config }}", resolve_env)
        setup_head = self.text.split("jobs:", 1)[1].split("Build fa CLI bundle", 1)[0]
        self.assertIn("id: provider", setup_head)

    def test_shard_env_consumes_the_resolved_provider(self):
        self.assertIn(
            "FA_PROVIDER_TYPE: ${{ needs.setup.outputs.provider_type }}", self.text
        )
        self.assertIn(
            "FA_PROVIDER_CONFIG: ${{ needs.setup.outputs.provider_config }}", self.text
        )
        self.assertIn(
            "FA_PROVIDER_KEY_ENV: ${{ needs.setup.outputs.provider_key_env }}", self.text
        )
        # The pre-gh-1503 zai hardcode is gone from the shard env.
        self.assertNotIn(
            'FA_PROVIDER_CONFIG: \'{"baseUrl":"https://api.z.ai/api/coding/paas/v4",'
            '"model":"glm-5.3-flash","apiKeyEnvVar":"FA_KEY_API_Z_AI_Z_AI"}\'',
            self.text,
        )
        # All three bench keys are mapped; the run block picks by name.
        self.assertIn("FA_KEY_API_Z_AI_Z_AI: ${{ secrets.FA_BENCH_ZAI_KEY }}", self.text)
        self.assertIn("FA_KEY_API_KIMI_COM_BENCH: ${{ secrets.FA_BENCH_KIMI_KEY }}", self.text)
        self.assertIn("FA_KEY_BENCH_CUSTOM: ${{ secrets.FA_BENCH_CUSTOM_KEY }}", self.text)

    def test_shard_run_block_resolves_the_key_by_name(self):
        run_block = self.text.split("Run harbor (fa agent", 1)[1]
        run_block = run_block.split("run: |", 1)[1].split("Upload harbor job", 1)[0]
        self.assertIn('provider_key="${FA_PROVIDER_KEY_ENV', run_block)
        self.assertIn('provider_key_value="${!provider_key}"', run_block)

    def test_run_identity_carries_provider_and_model(self):
        # run-name names the dispatch choice (same pattern as bench.yml);
        # the shard job name and the summary pin the resolved run_label /
        # bench_model — glm and kimi runs never blend in the history.
        self.assertIn(
            "run-name: fa bench-harbor · ${{ inputs.provider }} · ${{ inputs.tasks }}",
            self.text,
        )
        self.assertIn(
            "name: fa on tbench ${{ needs.setup.outputs.family }}, shard ${{ matrix.i }}"
            " (${{ matrix.env }}, ${{ needs.setup.outputs.run_label }})",
            self.text,
        )
        self.assertIn("MODEL: ${{ needs.setup.outputs.bench_model }}", self.text)
        self.assertIn("BENCH_RUN_LABEL: ${{ needs.setup.outputs.run_label }}", self.text)


if __name__ == "__main__":
    unittest.main()
