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
import sys
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

    def _step_env(self, name: str):
        """One `NAME: 'value'` entry from a step env block (quoted)."""
        m = re.search(rf"^          {re.escape(name)}: '([^']*)'", self.text, re.M)
        return m.group(1) if m else None

    def test_progress_watch_is_the_shard_default(self):
        # gh-1556 AC2: progress-watch (#1392/#1430) is the bench default —
        # every shard exports the watch knobs and the extension flag, so
        # the adapter's kill decision is the gap-aware ProgressWatch.
        # Removing these exports is the only way back to the legacy
        # byte-growth ladder (its round-2 REG stays green).
        self.assertEqual(self._step_env("FA_STALL_GAP_SEC"), "360")
        self.assertEqual(self._step_env("FA_AGENT_TIMEOUT_ABS_CEILING_SEC"), "3600")
        self.assertEqual(self._step_env("FA_PROGRESS_EXTENSION"), "1")

    def test_external_cap_flows_from_the_split_matrix(self):
        # gh-1576: the shard's external harness cap arrives from the setup
        # split (min declared per-task agent timeout across the shard) and
        # rides the shard step env. An absent matrix key renders an EMPTY
        # env var — unknown, the knobs rule alone (AC5/E1); a declared cap
        # is folded into the deadline via min() in bench/fa_agent_timeout.py.
        self.assertIn("FA_EXTERNAL_CAP_SEC: ${{ matrix.external_cap }}", self.text)
        # and the setup split emits the key: the split script's own unit
        # tests (test_split_tasks.py) pin the emission logic — here we pin
        # the workflow wiring (the expression must reference the matrix).
        self.assertIn("external_cap", self.text.split("matrix:", 1)[-1])

    def test_watch_knobs_resolve_to_progress_watch_mode(self):
        # The exported values must actually arm the watch: same env
        # contract the adapter consumes (shared bench/fa_agent_timeout.py).
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
        try:
            import fa_agent_timeout
        finally:
            sys.path.remove(str(Path(__file__).resolve().parent.parent))
        knobs = fa_agent_timeout.TimeoutKnobs.from_env(
            {
                "FA_STALL_GAP_SEC": self._step_env("FA_STALL_GAP_SEC"),
                "FA_AGENT_TIMEOUT_ABS_CEILING_SEC": self._step_env(
                    "FA_AGENT_TIMEOUT_ABS_CEILING_SEC"
                ),
                "FA_PROGRESS_EXTENSION": self._step_env("FA_PROGRESS_EXTENSION"),
            }
        )
        self.assertIsNotNone(knobs)
        self.assertTrue(knobs.progress_watch)
        self.assertTrue(knobs.progress_extension)

    def test_stall_gap_never_drops_below_the_watchdog_invariant(self):
        # gh-1430 invariant: the bench stall-gap must stay above fa's
        # stream-idle watchdog (300s) + margin — the workflow value can
        # never drift below the shipped default (the Dart-source REG in
        # test_fa_agent_timeout.py pins the other side).
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
        try:
            import fa_agent_timeout
        finally:
            sys.path.remove(str(Path(__file__).resolve().parent.parent))
        gap = float(self._step_env("FA_STALL_GAP_SEC"))
        self.assertGreaterEqual(gap, fa_agent_timeout._STALL_GAP_DEFAULT)

    def _shard_run_block(self):
        """The harbor shard step's `run: |` body."""
        run_block = self.text.split("Run harbor (fa agent", 1)[1]
        return run_block.split("run: |", 1)[1].split("Upload harbor job", 1)[0]

    def test_agent_timeout_input_clips_the_watch_ceiling(self):
        # gh-1556 rework review: under the watch the abs ceiling is the
        # cap that actually kills a progressing trial, so an explicit
        # agent-timeout input must clip it to base x4 (pre-PR the legacy
        # ladder did exactly this) — otherwise the tighter cap the
        # operator asked for is silently ignored in favor of the flat
        # 3600s step-env default.
        self.assertIn(
            "FA_AGENT_TIMEOUT_ABS_CEILING_SEC < AGENT_TIMEOUT * 4",
            self._shard_run_block(),
        )

    def test_agent_timeout_clip_defaults_the_ceiling_when_export_removed(self):
        # gh-1556 rework re-review (suggestion): the escape hatch is
        # "remove the watch exports to restore the legacy ladder" — but
        # the exports are load-bearing individually: unsetting ONLY
        # FA_AGENT_TIMEOUT_ABS_CEILING_SEC (keeping agent-timeout set)
        # must not die on an unbound variable under `set -euo pipefail`;
        # the ceiling defaults to base x4 (exactly what the legacy
        # ladder would have used) before the clip runs.
        run_block = self._shard_run_block()
        self.assertIn(
            '${FA_AGENT_TIMEOUT_ABS_CEILING_SEC:-$((AGENT_TIMEOUT * 4))}',
            run_block,
        )

    def test_progress_extension_input_can_still_turn_the_extension_off(self):
        # gh-1556 rework review: the step env exports FA_PROGRESS_EXTENSION=1
        # (the watch default, AC2) — an explicit progress-extension: false
        # dispatch must still win by unsetting it, otherwise the input is
        # a silent no-op while the comment claims otherwise.
        self.assertRegex(
            self._shard_run_block(),
            r"false\|FALSE\|False\|no\|off\) unset FA_PROGRESS_EXTENSION",
        )

    def test_watch_comment_does_not_claim_inputs_win_silently(self):
        # gh-1556 rework review: the old comment claimed the input-derived
        # exports "still win where they are set" while the step env made
        # both inputs no-ops — the wording must describe the real
        # precedence (clip for agent-timeout, unset for the extension).
        self.assertNotIn("still win where they are set", self.text)


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
    # try/finally: the no-output early return used to leak proc._tmp
    # (ResourceWarning on GC) — same hygiene class as the gh-1592
    # test_error_classifier review thread.
    try:
        if not proc.github_output.exists():
            return {}
        result = {}
        for line in proc.github_output.read_text().splitlines():
            if "=" in line:
                key, _, value = line.partition("=")
                result[key] = value
        return result
    finally:
        proc._tmp.cleanup()


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
        self.assertEqual(outputs["bench_model"], "kimi-for-coding")
        self.assertEqual(outputs["run_label"], "kimi-for-coding")
        config = json.loads(outputs["provider_config"])
        self.assertEqual(config["baseUrl"], "https://api.kimi.com/coding/v1")
        self.assertEqual(config["model"], "kimi-for-coding")
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


@unittest.skipUnless(
    _HARBOR_YML.exists(), "bench-harbor.yml not found (standalone bench checkout)"
)
class ShardDatasetEnvRegTest(unittest.TestCase):
    """REG (run 38126875911): the bench shard job's harbor step overrode
    DATASET with `${{ steps.family.outputs.dataset }}` — a `steps.*` ref
    to a step in ANOTHER job always evaluates empty, so every shard died
    with harbor's `Dataset  not found` (empty name). The dataset id must
    cross jobs via `needs.setup.outputs.dataset` (the `steps.family`
    ref is only valid inside the setup job itself)."""

    @classmethod
    def setUpClass(cls):
        cls.text = _HARBOR_YML.read_text()

    @staticmethod
    def _slice_job(text: str, start_marker: str, end_marker: str) -> str:
        # Slice a job body between two literal markers. Assert the markers
        # exist FIRST so a workflow re-indent or a stray `summary:` string
        # fails with a message naming the YAML-shape assumption, not an
        # opaque IndexError from a bare str.split.
        start = text.find(start_marker)
        if start == -1:
            raise AssertionError(
                f"bench-harbor.yml shape changed: marker {start_marker!r} not found"
            )
        end = text.find(end_marker, start + len(start_marker))
        if end == -1:
            raise AssertionError(
                f"bench-harbor.yml shape changed: end marker {end_marker!r}"
                f" not found after {start_marker!r}"
            )
        return text[start:end]

    def setUp(self):
        # Fail loudly (naming the missing marker) before any test slices.
        for marker in ("\n  bench:", "\n  summary:"):
            self.assertIn(
                marker,
                self.text,
                f"bench-harbor.yml shape changed: {marker!r} marker gone",
            )

    def _bench_job(self) -> str:
        # The bench (shard) job body: from its `needs: setup` marker to
        # the summary job boundary.
        return self._slice_job(self.text, "\n  bench:", "\n  summary:")

    def _harbor_run_step_env(self) -> str:
        # The Run harbor step header + env block (up to its `run:` block) —
        # exactly the region where a step-level env key could re-declare
        # (and override) the job env.
        return self._slice_job(self._bench_job(), "- name: Run harbor", "\n        run:")

    def test_no_cross_job_step_refs_in_the_bench_job(self):
        self.assertNotIn("steps.family.outputs", self._bench_job())

    def test_harbor_run_step_takes_dataset_from_setup_outputs(self):
        # The dataset reaches the shard via the JOB-level env
        # (`env:` under `jobs.bench`); the step must not re-declare it.
        self.assertIn(
            "DATASET: ${{ needs.setup.outputs.dataset }}", self._bench_job()
        )

    def test_harbor_step_does_not_redeclare_dataset(self):
        # A step env OVERRIDES the job env — that override class is what
        # killed run 38126875911. The step must inherit DATASET from the
        # job env instead of re-declaring the key.
        self.assertNotIn("DATASET:", self._harbor_run_step_env())

    def test_slicing_failure_names_the_missing_marker(self):
        # Structural-change guard (review thread): a missing marker must
        # raise AssertionError naming the marker, not an opaque IndexError.
        with self.assertRaises(AssertionError) as ctx:
            self._slice_job("jobs:\n  other:\n    x: 1", "\n  bench:", "\n  summary:")
        self.assertIn("\\n  bench:", str(ctx.exception))

    def test_setup_job_internal_family_ref_stays(self):
        # The setup job's shard step legitimately reads its OWN family
        # step (same job) — that one must not be "fixed" away.
        setup_job = self.text.split("\n  bench:", 1)[0]
        self.assertIn("DATASET: ${{ steps.family.outputs.dataset }}", setup_job)


if __name__ == "__main__":
    unittest.main()
