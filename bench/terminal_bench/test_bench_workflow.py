#!/usr/bin/env python3
"""Pins the knob/timeout shell logic of the bench.yml shard step (gh-1209).

The `run:` block decides, from two workflow_dispatch inputs, whether the
outer tb harness cap must sit above the progress ladder's ceiling and which
env vars reach fa_agent.py. This suite executes that exact block against a
`tb` stub and pins one behavior per input combination:

- REG-1 (issue #1122): both inputs absent → byte-for-byte stock delegation —
  no FA_AGENT_TIMEOUT_SEC, no FA_PROGRESS_EXTENSION, no --global-agent-
  timeout-sec.
- gh-1209: any active ladder (explicit agent-timeout, or progress-extension
  on with its 360s default base) pins the harness cap at 4x base + 180s so
  the ladder decides, never the flat harness wait_for.
- gh-1209 review: `agent-timeout=0` is rejected at step start — it used to
  pass validation, export FA_AGENT_TIMEOUT_SEC=0, and raise ValueError
  inside EVERY trial's perform_task hours into the shard.
- Invalid inputs (non-digit timeout, non-boolean extension) fail fast.

Issue #1406: the fa launch path must carry the ConnTrace env into the
tmux pane itself (string-level asserts on the generated TerminalCommand
— the exact bytes tb types into the pane), and a trial whose
bench_metrics.json folded zero requests despite real model usage must
fire a LOUD workflow warning, never ship an empty shell silently.

gh-1471: the setup-job provider resolve step maps the dispatch choice
(zai-glm-5.3-flash default / kimi-for-coding / custom) to the full
provider triple and preflights the selected secret BEFORE any shard
starts — each choice pins (type, baseUrl, model, apiKeyEnvVar), an
unmapped value fails hard, a missing secret fails fast naming the
secret, and a key value never reaches the log. The custom path (D1 /
AC 2a) validates the provider-config JSON (parseable object, non-empty
https:// baseUrl + model, no key-like fields case-insensitively) and
injects the fixed apiKeyEnvVar FA_KEY_BENCH_CUSTOM — the key comes only
from FA_BENCH_CUSTOM_KEY. REG-1: the default's provider_config is
byte-identical to the pre-gh-1471 3-field zai JSON.

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import importlib.util
import collections
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stderr
from io import StringIO
from pathlib import Path
from unittest import mock

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_BENCH_YML = _REPO_ROOT / ".github" / "workflows" / "bench.yml"
sys.path.insert(0, str(_REPO_ROOT / "bench"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import bench_metrics  # noqa: E402


def _shard_run_block() -> str:
    """Extracts the `run: |` block of the tb shard step from bench.yml.

    Text-slicing, not PyYAML: the block is a literal scalar and the suite
    must run anywhere python3 runs (the bench shards have no PyYAML). The
    block is identified by its `tb run -d` body, so unrelated `run:` blocks
    never match.
    """
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
        if "tb run -d" in block:
            start = True
            break
    else:
        raise AssertionError("tb shard step's run: | block not found in bench.yml")
    # Only expression the block may interpolate; anything else means the
    # workflow grew a new one and this harness needs the mapping extended.
    block = re.sub(r"\$\{\{\s*matrix\.i\s*\}\}", "0", block)
    leftover = re.findall(r"\$\{\{[^}]*\}\}", block)
    assert not leftover, f"unmapped GitHub expression(s) in run block: {leftover}"
    return block


def _resolve_run_block() -> str:
    """Extracts the `run: |` block of the gh-1471 provider resolve step.

    Same text-slicing contract as [_shard_run_block]: the block is
    identified by its body (the provider_config printf), so unrelated
    `run:` blocks never match. The block is env-driven (inputs/secrets
    arrive via the step env), so no GitHub expression may appear inside.
    """
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
            break
    else:
        raise AssertionError("provider resolve step's run: | block not found in bench.yml")
    leftover = re.findall(r"\$\{\{[^}]*\}\}", block)
    assert not leftover, f"unmapped GitHub expression(s) in resolve block: {leftover}"
    return block


# The resolve block runs with GITHUB_OUTPUT pointed at a temp file (the
# test reads the step outputs from it) and all three bench secrets in env
# (gh-1471 D1/AC 2a: the custom path preflights FA_BENCH_CUSTOM_KEY).
def _run_resolve(
    provider="",
    zai_key="zai-test-key",
    kimi_key="kimi-test-key",
    custom_key="custom-test-key",
    provider_config="",
):
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


# The tb stub records the exact argv the block computed plus the two env
# vars fa_agent.py's TimeoutKnobs reads, then exits 0 — the real tb never
# runs in tests.
_TB_STUB = r"""
tb() {
  echo "TB_BEGIN"
  local a
  for a in "$@"; do echo "arg:$a"; done
  echo "TB_END"
  echo "FA_AGENT_TIMEOUT_SEC=${FA_AGENT_TIMEOUT_SEC-__unset__}"
  echo "FA_PROGRESS_EXTENSION=${FA_PROGRESS_EXTENSION-__unset__}"
  echo "FA_AGENT_TIMEOUT_ABS_CEILING_SEC=${FA_AGENT_TIMEOUT_ABS_CEILING_SEC-__unset__}"
}
"""

_DRIVER = "#!/usr/bin/env bash\n" + _TB_STUB + "\n" + _shard_run_block() + "\n"


def _run_shard(agent_timeout="", progress_extension=""):
    env = dict(os.environ)
    env.update(
        {
            "DATASET": "/tmp/fa-bench-workflow-test-dataset",
            "SHARD_TASKS": "task-0 task-1",
            "FA_KEY_API_Z_AI_Z_AI": "test-key",
            # gh-1471: the resolve step (setup job) names the key env var
            # for the run block's indirection; the zai default names the
            # zai var.
            "FA_PROVIDER_KEY_ENV": "FA_KEY_API_Z_AI_Z_AI",
            "AGENT_TIMEOUT": agent_timeout,
            "PROGRESS_EXTENSION": progress_extension,
        }
    )
    with tempfile.TemporaryDirectory() as tmp:
        driver = Path(tmp) / "shard_step.sh"
        driver.write_text(_DRIVER)
        proc = subprocess.run(
            ["bash", str(driver)],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
    return proc


def _tb_args(stdout):
    args = []
    inside = False
    for line in stdout.splitlines():
        if line == "TB_BEGIN":
            inside = True
        elif line == "TB_END":
            inside = False
        elif inside and line.startswith("arg:"):
            args.append(line[len("arg:") :])
    return args


def _env_value(stdout, name):
    for line in stdout.splitlines():
        if line.startswith(name + "="):
            return line[len(name) + 1 :]
    return None


def _flag_value(args, flag):
    return args[args.index(flag) + 1] if flag in args else None


@unittest.skipUnless(
    _BENCH_YML.exists(), "bench.yml not found (standalone bench checkout)"
)
@unittest.skipUnless(shutil.which("bash"), "bash not available")
class BenchWorkflowShardStepTest(unittest.TestCase):
    maxDiff = None

    def test_reg1_both_inputs_absent_keep_stock_delegation(self):
        # Issue #1122 REG-1: absent inputs leave both env vars unset and no
        # harness cap is passed — the adapter delegates to the stock flat
        # cap. Must stay byte-for-byte.
        proc = _run_shard()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(_env_value(proc.stdout, "FA_AGENT_TIMEOUT_SEC"), "__unset__")
        self.assertEqual(_env_value(proc.stdout, "FA_PROGRESS_EXTENSION"), "__unset__")
        self.assertIsNone(_flag_value(_tb_args(proc.stdout), "--global-agent-timeout-sec"))

    def test_explicit_timeout_pins_harness_cap_above_ladder(self):
        proc = _run_shard(agent_timeout="300")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(_env_value(proc.stdout, "FA_AGENT_TIMEOUT_SEC"), "300")
        self.assertEqual(_env_value(proc.stdout, "FA_PROGRESS_EXTENSION"), "__unset__")
        args = _tb_args(proc.stdout)
        self.assertEqual(_flag_value(args, "--global-agent-timeout-sec"), "1380")  # 300*4+180

    def test_leading_zero_timeout_is_base10_not_octal(self):
        # '010' must mean 10 (the $((10#...)) guard), not octal 8.
        proc = _run_shard(agent_timeout="010")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(_env_value(proc.stdout, "FA_AGENT_TIMEOUT_SEC"), "010")
        args = _tb_args(proc.stdout)
        self.assertEqual(_flag_value(args, "--global-agent-timeout-sec"), "220")  # 10*4+180

    def test_extension_without_timeout_pins_default_base_360(self):
        # gh-1209: extension on with no explicit base runs the ladder at its
        # 360s default — the base must still be pinned explicitly so the
        # ladder and the (round-3, abs-ceiling) harness cap agree on it.
        proc = _run_shard(progress_extension="true")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(_env_value(proc.stdout, "FA_AGENT_TIMEOUT_SEC"), "360")
        self.assertEqual(_env_value(proc.stdout, "FA_PROGRESS_EXTENSION"), "1")

    def test_extension_off_leaves_everything_stock(self):
        proc = _run_shard(progress_extension="false")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(_env_value(proc.stdout, "FA_AGENT_TIMEOUT_SEC"), "__unset__")
        self.assertEqual(_env_value(proc.stdout, "FA_PROGRESS_EXTENSION"), "__unset__")
        self.assertIsNone(_flag_value(_tb_args(proc.stdout), "--global-agent-timeout-sec"))

    def test_extension_on_alias_exports_progress_var(self):
        proc = _run_shard(progress_extension="on")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(_env_value(proc.stdout, "FA_PROGRESS_EXTENSION"), "1")

    def test_timeout_with_extension_off_still_pins_cap(self):
        # The cap pin keys on the ladder being active (an exported
        # FA_AGENT_TIMEOUT_SEC), not on the extension flag.
        proc = _run_shard(agent_timeout="300", progress_extension="false")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        args = _tb_args(proc.stdout)
        self.assertEqual(_flag_value(args, "--global-agent-timeout-sec"), "1380")
        self.assertEqual(_env_value(proc.stdout, "FA_PROGRESS_EXTENSION"), "__unset__")

    def test_zero_timeout_rejected_before_any_trial_starts(self):
        # gh-1209 review: 0 passes the digit check, then
        # TimeoutKnobs.from_env → _number raises ValueError inside EVERY
        # trial's perform_task — a whole multi-hour shard wasted. The step
        # must fail fast instead, before tb (and so any trial) runs.
        proc = _run_shard(agent_timeout="0")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("positive integer", proc.stdout + proc.stderr)
        self.assertNotIn("TB_BEGIN", proc.stdout)

    def test_non_integer_timeout_rejected(self):
        proc = _run_shard(agent_timeout="12a")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("integer seconds", proc.stdout + proc.stderr)
        self.assertNotIn("TB_BEGIN", proc.stdout)

    def test_invalid_progress_extension_rejected(self):
        proc = _run_shard(progress_extension="maybe")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("boolean", proc.stdout + proc.stderr)
        self.assertNotIn("TB_BEGIN", proc.stdout)


@unittest.skipUnless(
    _BENCH_YML.exists(), "bench.yml not found (standalone bench checkout)"
)
@unittest.skipUnless(shutil.which("bash"), "bash not available")
class ProviderResolveStepTest(unittest.TestCase):
    """gh-1471: the setup-job resolve step maps the provider choice to
    the full triple and preflights the selected secret BEFORE any shard
    starts. Each choice pins (type, baseUrl, model, apiKeyEnvVar); an
    unmapped value fails hard (never a silent fallthrough to the zai
    default); a missing secret fails fast naming the secret; the key
    value never reaches the log (presence only, plus the base64 mask
    line)."""

    maxDiff = None

    # REG-1: the default must reproduce today's exact 3-field zai config
    # (the value the shard env carried before gh-1471).
    LEGACY_ZAI_CONFIG = (
        '{"baseUrl":"https://api.z.ai/api/coding/paas/v4",'
        '"model":"glm-5.3-flash","apiKeyEnvVar":"FA_KEY_API_Z_AI_Z_AI"}'
    )

    def test_default_provider_is_byte_identical_to_today(self):
        for provider in ("", "zai-glm-5.3-flash"):
            proc = _run_resolve(provider=provider)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            outputs = _resolve_outputs(proc)
            self.assertEqual(outputs["provider_type"], "zai")
            self.assertEqual(outputs["provider_config"], self.LEGACY_ZAI_CONFIG)
            self.assertEqual(outputs["provider_key_env"], "FA_KEY_API_Z_AI_Z_AI")
            self.assertEqual(outputs["bench_model"], "glm-5.3-flash")
            # D5: one spelling everywhere — the run label derives from
            # the dispatch choice id, matching run-name.
            self.assertEqual(outputs["run_label"], "zai-glm-5.3-flash (glm-5.3-flash)")

    def test_default_config_has_no_capability_fields(self):
        # REG-1's sharpened form: the zai JSON must stay the 3-field
        # legacy shape — no contextWindow/maxTokens keys.
        proc = _run_resolve()
        outputs = _resolve_outputs(proc)
        config = json.loads(outputs["provider_config"])
        self.assertEqual(
            set(config), {"baseUrl", "model", "apiKeyEnvVar"}
        )

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
        # D4: the capability fields ride the config explicitly.
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
        # Presence only: the raw key must not appear in stdout/stderr
        # (the ::add-mask:: line carries the base64 form, like the shard
        # step's long-standing contract).
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

    # gh-1471 D1 / AC 2a: the custom escape hatch — a new provider
    # tomorrow needs zero workflow edits. The key NEVER rides the
    # dispatch input (inputs are visible in run metadata): it comes only
    # from the FA_BENCH_CUSTOM_KEY secret, injected as the fixed
    # apiKeyEnvVar FA_KEY_BENCH_CUSTOM.
    CUSTOM_CONFIG = (
        '{"type":"openai","baseUrl":"https://api.example.com/v1",'
        '"model":"m-1","contextWindow":128000,"maxTokens":8192}'
    )

    def test_custom_provider_config_flows_verbatim_with_fixed_key_env(self):
        proc = _run_resolve(provider="custom", provider_config=self.CUSTOM_CONFIG)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        outputs = _resolve_outputs(proc)
        config = json.loads(outputs["provider_config"])
        # Every declared field rides FA_PROVIDER_CONFIG verbatim…
        declared = json.loads(self.CUSTOM_CONFIG)
        for key, value in declared.items():
            self.assertEqual(config[key], value)
        # …plus the fixed key env injection — the only key path.
        self.assertEqual(config["apiKeyEnvVar"], "FA_KEY_BENCH_CUSTOM")
        self.assertEqual(outputs["provider_type"], "openai")
        self.assertEqual(outputs["provider_key_env"], "FA_KEY_BENCH_CUSTOM")
        self.assertEqual(outputs["bench_model"], "m-1")
        self.assertEqual(outputs["run_label"], "custom (m-1)")

    def test_custom_type_defaults_to_openai_compatible(self):
        proc = _run_resolve(
            provider="custom",
            provider_config='{"baseUrl":"https://api.example.com/v1","model":"m-1"}',
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        outputs = _resolve_outputs(proc)
        self.assertEqual(outputs["provider_type"], "openai")
        config = json.loads(outputs["provider_config"])
        self.assertEqual(config["model"], "m-1")

    def test_custom_rejects_non_json(self):
        proc = _run_resolve(provider="custom", provider_config="not json {")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("provider-config", proc.stdout + proc.stderr)
        self.assertEqual(_resolve_outputs(proc), {})

    def test_custom_rejects_non_object_json(self):
        proc = _run_resolve(provider="custom", provider_config='["baseUrl"]')
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(_resolve_outputs(proc), {})

    def test_custom_rejects_missing_base_url_or_model(self):
        for config in (
            '{"model":"m-1"}',
            '{"baseUrl":"https://api.example.com/v1"}',
            '{"baseUrl":"","model":"m-1"}',
        ):
            proc = _run_resolve(provider="custom", provider_config=config)
            self.assertNotEqual(proc.returncode, 0, config)
            message = proc.stdout + proc.stderr
            self.assertIn("baseUrl", message)
            self.assertIn("model", message)
            self.assertEqual(_resolve_outputs(proc), {})

    def test_custom_rejects_non_https_base_url(self):
        proc = _run_resolve(
            provider="custom",
            provider_config='{"baseUrl":"http://api.example.com/v1","model":"m-1"}',
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("https://", proc.stdout + proc.stderr)
        self.assertEqual(_resolve_outputs(proc), {})

    def test_custom_rejects_key_like_fields_case_insensitive(self):
        # The key must never ride a dispatch input — run metadata is
        # visible. apiKey/key/token/secret (any case) hard-fail.
        for field in ("apiKey", "APIKEY", "key", "Key", "token", "SECRET",
                      "api_key", "accessToken"):
            with self.subTest(field=field):
                config = (
                    '{"baseUrl":"https://api.example.com/v1","model":"m-1",'
                    f'"{field}":"sk-leaked"}}'
                )
                proc = _run_resolve(provider="custom", provider_config=config)
                self.assertNotEqual(proc.returncode, 0, field)
                message = proc.stdout + proc.stderr
                self.assertIn(field.lower(), message.lower())
                self.assertNotIn("sk-leaked", message)
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


def _yml_text() -> str:
    return _BENCH_YML.read_text()


@unittest.skipUnless(
    _BENCH_YML.exists(), "bench.yml not found (standalone bench checkout)"
)
class BenchWorkflowRound3ShapeTest(unittest.TestCase):
    """Issue #1392 AC5: split 8 / run at most 2 concurrently / pack to
    cap-15min. The 'at most N in_progress' property IS GHA's
    strategy.max-parallel semantics (the other shard jobs sit in queued
    until a slot frees), so the workflow-level assertion pins that wiring
    plus the packing argument the setup step feeds shard_tasks.py.
    """

    def test_inputs_split_eight_run_two(self):
        text = _yml_text()
        self.assertRegex(text, r"shards:\n(?:[^\n]*\n){1,4}\s+default: '8'")
        self.assertRegex(
            text, r"max-concurrent:\n(?:[^\n]*\n){1,4}\s+default: '2'"
        )

    def test_shard_matrix_capped_at_max_concurrent(self):
        text = _yml_text()
        self.assertIn(
            "max-parallel: ${{ fromJSON(inputs.max-concurrent) }}", text
        )
        self.assertNotIn("max-parallel: 5", text)

    def test_shard_packing_wired_to_raw_cap(self):
        # 355-min job cap passed RAW: shard_tasks.check_cap subtracts its
        # own 15-min headroom (355 - 15 = 340 min usable — the AC5
        # contract; round 2 lost shard-0 by ~1 min with zero headroom).
        text = _yml_text()
        self.assertIn("--job-cap-seconds", text)
        self.assertIn('--job-cap-seconds "$((355 * 60))"', text)

    def test_merge_report_tags_concurrency(self):
        text = _yml_text()
        self.assertIn("BENCH_CONCURRENCY", text)

    def test_merge_runs_post_mortem_before_summary(self):
        # AC4/AC7/AC8 at run level: the post-mortem attribution pass folds
        # session usage into results.json (and names export gaps /
        # honesty violations) BEFORE the report prices the rows.
        text = _yml_text()
        self.assertIn("bench/post_mortem_usage.py tb-runs", text)
        self.assertLess(
            text.index("Post-mortem attribution pass"),
            text.index("Accuracy summary & verdict"),
        )

    def test_merged_artifact_uploads_the_patched_rows(self):
        # Review: the post-mortem pass patches results.json in place — the
        # durable tb-runs-merged artifact must carry the PATCHED rows, so
        # the upload step runs after the pass.
        text = _yml_text()
        self.assertLess(
            text.index("Post-mortem attribution pass"),
            text.index("Upload merged tb runs"),
        )

    def test_bench_step_enables_the_conn_forensics(self):
        # The dispatched run IS the instrumented experiment: without these
        # exports the adapter forwards nothing into the container and
        # bench_metrics.json ships requests: [] with hang payloads null.
        run_block = _shard_run_block()
        text = _yml_text()
        for var in (
            "FA_CONN_DEBUG",
            "FA_CONN_TRACE_FILE",
            "FA_CONN_PAYLOAD_SNAPSHOT",
            "FA_BENCH_CONCURRENCY",
        ):
            self.assertIn(f"{var}:", text)
        self.assertIn("FA_BENCH_CONCURRENCY: ${{ inputs.max-concurrent }}", text)
        # The run block itself must not unset them.
        self.assertNotIn("unset FA_CONN_DEBUG", run_block)

    def test_extension_on_pins_harness_cap_above_abs_ceiling(self):
        # Round 3: with the progress watch on, the ladder ceiling is the
        # abs ceiling (default 3600s) — the 4x+180 pin would guillotine
        # an extended-but-progressing trial below our own decision point.
        self.assertIn("${FA_AGENT_TIMEOUT_ABS_CEILING_SEC:-3600}", _yml_text())


@unittest.skipUnless(
    _BENCH_YML.exists(), "bench.yml not found (standalone bench checkout)"
)
class ProviderSelectionShapeTest(unittest.TestCase):
    """gh-1471 wiring: the provider choice input, the resolved env in the
    shard step, the provider+model in the run identity, and the secret
    preflight before any shard starts."""

    def test_provider_choice_input_live_with_zai_default(self):
        text = _yml_text()
        self.assertRegex(
            text,
            r"provider:\n(?:[^\n]*\n){1,5}\s+default: 'zai-glm-5.3-flash'",
        )
        self.assertIn("type: choice", text)
        self.assertIn("- 'kimi-for-coding'", text)
        # gh-1471 D1 / AC 2a: the custom escape hatch is a dispatch
        # choice, fed by the free-text provider-config input.
        self.assertIn("- 'custom'", text)
        self.assertRegex(
            text,
            r"provider-config:\n(?:[^\n]*\n){1,4}\s+default: ''",
        )

    def test_setup_job_exports_the_resolved_provider(self):
        text = _yml_text()
        for output in (
            "provider_type: ${{ steps.provider.outputs.provider_type }}",
            "provider_config: ${{ steps.provider.outputs.provider_config }}",
            "provider_key_env: ${{ steps.provider.outputs.provider_key_env }}",
            "bench_model: ${{ steps.provider.outputs.bench_model }}",
            "run_label: ${{ steps.provider.outputs.run_label }}",
        ):
            self.assertIn(output, text)

    def test_resolve_step_preflights_both_bench_secrets(self):
        # The preflight reads both secrets via env (presence only) and
        # runs in the setup job — before the bundle builds or any shard
        # starts.
        text = _yml_text()
        resolve_env = text.split('id: provider', 1)[1].split('run: |', 1)[0]
        self.assertIn("FA_BENCH_ZAI_KEY: ${{ secrets.FA_BENCH_ZAI_KEY }}", resolve_env)
        self.assertIn("FA_BENCH_KIMI_KEY: ${{ secrets.FA_BENCH_KIMI_KEY }}", resolve_env)
        # AC 2a: the custom path preflights FA_BENCH_CUSTOM_KEY and
        # receives the provider-config input via env (the run block must
        # stay free of GitHub expressions for the UT harness).
        self.assertIn("FA_BENCH_CUSTOM_KEY: ${{ secrets.FA_BENCH_CUSTOM_KEY }}", resolve_env)
        self.assertIn("PROVIDER_CONFIG: ${{ inputs.provider-config }}", resolve_env)

    def test_shard_env_consumes_the_resolved_provider(self):
        text = _yml_text()
        self.assertIn(
            "FA_PROVIDER_TYPE: ${{ needs.setup.outputs.provider_type }}", text
        )
        self.assertIn(
            "FA_PROVIDER_CONFIG: ${{ needs.setup.outputs.provider_config }}", text
        )
        self.assertIn(
            "FA_PROVIDER_KEY_ENV: ${{ needs.setup.outputs.provider_key_env }}", text
        )
        # The zai hardcode is gone from the shard env.
        self.assertNotIn('FA_PROVIDER_TYPE: zai', text)
        self.assertNotIn('{"baseUrl":"https://api.z.ai/api/coding/paas/v4","model":"${{ env.BENCH_MODEL }}"', text)
        # Both bench keys are mapped; the run block picks by name. The
        # custom path adds its fixed key env (AC 2a: key only from
        # FA_BENCH_CUSTOM_KEY).
        self.assertIn("FA_KEY_API_Z_AI_Z_AI: ${{ secrets.FA_BENCH_ZAI_KEY }}", text)
        self.assertIn("FA_KEY_API_KIMI_COM_BENCH: ${{ secrets.FA_BENCH_KIMI_KEY }}", text)
        self.assertIn("FA_KEY_BENCH_CUSTOM: ${{ secrets.FA_BENCH_CUSTOM_KEY }}", text)

    def test_shard_run_block_resolves_the_key_by_name(self):
        block = _shard_run_block()
        self.assertIn('provider_key="${FA_PROVIDER_KEY_ENV', block)
        self.assertIn('provider_key_value="${!provider_key}"', block)

    def test_shard_job_name_carries_provider_and_model(self):
        text = _yml_text()
        self.assertIn(
            "name: fa on terminal-bench · ${{ needs.setup.outputs.run_label }},"
            " shard ${{ matrix.i }}",
            text,
        )

    def test_summary_steps_pin_the_resolved_model_and_label(self):
        text = _yml_text()
        self.assertGreaterEqual(text.count("MODEL: ${{ needs.setup.outputs.bench_model }}"), 2)
        self.assertEqual(text.count("BENCH_RUN_LABEL: ${{ needs.setup.outputs.run_label }}"), 2)

    def test_run_name_names_the_provider_choice(self):
        self.assertIn(
            "run-name: fa bench · ${{ inputs.provider }} · ${{ inputs.tasks }}",
            _yml_text(),
        )


@unittest.skipUnless(
    _BENCH_YML.exists(), "bench.yml not found (standalone bench checkout)"
)
@unittest.skipUnless(shutil.which("bash"), "bash not available")
class AbsCeilingHarnessCapTest(unittest.TestCase):
    """The run-block contract when the progress watch is on."""

    def _run(self, agent_timeout="", progress_extension="", abs_ceiling=""):
        env = dict(os.environ)
        env.pop("FA_AGENT_TIMEOUT_ABS_CEILING_SEC", None)
        env.update(
            {
                "DATASET": "/tmp/fa-bench-workflow-test-dataset",
                "SHARD_TASKS": "task-0 task-1",
                "FA_KEY_API_Z_AI_Z_AI": "test-key",
                "FA_PROVIDER_KEY_ENV": "FA_KEY_API_Z_AI_Z_AI",
                "AGENT_TIMEOUT": agent_timeout,
                "PROGRESS_EXTENSION": progress_extension,
            }
        )
        if abs_ceiling:
            env["FA_AGENT_TIMEOUT_ABS_CEILING_SEC"] = abs_ceiling
        with tempfile.TemporaryDirectory() as tmp:
            driver = Path(tmp) / "shard_step.sh"
            driver.write_text(
                "#!/usr/bin/env bash\n" + _TB_STUB + "\n" + _shard_run_block() + "\n"
            )
            proc = subprocess.run(
                ["bash", str(driver)],
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
            )
        return proc

    def test_extension_on_caps_at_abs_ceiling_plus_slack(self):
        proc = self._run(progress_extension="true")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            _flag_value(_tb_args(proc.stdout), "--global-agent-timeout-sec"),
            "3780",  # 3600 abs ceiling + 180 slack
        )
        self.assertEqual(_env_value(proc.stdout, "FA_PROGRESS_EXTENSION"), "1")

    def test_extension_on_exports_the_watch_knob(self):
        # Round-3 review blocker: FA_PROGRESS_EXTENSION alone leaves the
        # LEGACY x4 ladder deciding (watch_active needs a watch knob) —
        # extension on must export the abs-ceiling knob so the watch,
        # not the ladder, decides every kill.
        proc = self._run(progress_extension="true")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            _env_value(proc.stdout, "FA_AGENT_TIMEOUT_ABS_CEILING_SEC"), "3600"
        )
        # An override moves BOTH the exported knob and the harness cap,
        # so they can never drift apart.
        proc2 = self._run(progress_extension="true", abs_ceiling="5400")
        self.assertEqual(
            _env_value(proc2.stdout, "FA_AGENT_TIMEOUT_ABS_CEILING_SEC"), "5400"
        )
        self.assertEqual(
            _flag_value(_tb_args(proc2.stdout), "--global-agent-timeout-sec"),
            "5580",
        )

    def test_extension_on_honors_abs_ceiling_override(self):
        proc = self._run(progress_extension="true", abs_ceiling="5400")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            _flag_value(_tb_args(proc.stdout), "--global-agent-timeout-sec"),
            "5580",
        )

    def test_extension_off_keeps_the_4x_pin(self):
        # REG (gh-1209): without the watch, the outer cap stays 4x+180.
        proc = self._run(agent_timeout="300")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            _flag_value(_tb_args(proc.stdout), "--global-agent-timeout-sec"),
            "1380",
        )
        self.assertEqual(_env_value(proc.stdout, "FA_PROGRESS_EXTENSION"), "__unset__")


def _load_fa_agent_1406():
    """fa_agent.py under the stdlib tb stub (anywhere python3 runs).

    Mirrors test_progress_watch_adapter's loader; its installer is a
    no-op when the real terminal_bench is importable. Under full-suite
    discovery test_fa_usage installs a bare `TerminalCommand` (no
    kwargs) whose importability then makes the availability check pass
    and blocks that installer — so the resident stub is probed with the
    adapter's actual constructor kwargs and replaced when hostile (a
    dataclass-based real terminal_bench passes the probe untouched).
    """
    from test_progress_watch_adapter import _install_tb_stubs

    _install_tb_stubs()
    models_mod = sys.modules.get("terminal_bench.terminal.models")
    probe = getattr(models_mod, "TerminalCommand", None)
    if probe is not None:
        try:
            probe(
                command="x",
                min_timeout_sec=0.0,
                max_timeout_sec=0.0,
                block=True,
                append_enter=True,
            )
        except TypeError:
            class TerminalCommand:
                def __init__(self, **kwargs):
                    self.__dict__.update(kwargs)

            models_mod.TerminalCommand = TerminalCommand
    spec = importlib.util.spec_from_file_location(
        "fa_agent_1406", _REPO_ROOT / "bench" / "terminal_bench" / "fa_agent.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FaPaneLaunchEnvTest(unittest.TestCase):
    """Issue #1406 AC1/AC3: the fa launch line carries FA_CONN_* itself.

    Round-3 bench ran ConnTrace-dark (29/29 empty bench_metrics.json):
    FA_CONN_DEBUG reached the container only through setup-env.sh,
    sourced once at install time — a tmux pane's environment belongs to
    the pane shell's history, not to the step env that typed a later
    command, so shell-state loss between install and launch drops the
    vars silently. These tests pin the generated TerminalCommand at
    string level: the non-secret diagnostic env is exported on the SAME
    line that launches fa, and the launch-time `env | grep FA_CONN`
    capture (folded into agent-logs as fa-conn-env.txt) proves what fa
    actually inherited.
    """

    maxDiff = None

    @classmethod
    def setUpClass(cls):
        cls.fa_agent = _load_fa_agent_1406()

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self._tarball = str(Path(self.tmpdir.name) / "fa-bundle.tar.gz")
        Path(self._tarball).write_bytes(b"")

    def _launch_command(self, **env):
        full_env = {"FA_BUNDLE_TARBALL": self._tarball}
        full_env.update(env)
        with mock.patch.dict(os.environ, full_env, clear=True):
            agent = self.fa_agent.FaAgent()
            return agent._run_agent_commands("do the thing")[0].command

    def test_conn_debug_reaches_the_launch_line_before_fa(self):
        cmd = self._launch_command(FA_CONN_DEBUG="1")
        self.assertIn("export FA_CONN_DEBUG=1", cmd)
        # Same line, BEFORE the launch: the export must be in effect when
        # fa execs, not typed into a pane whose shell state may reset.
        self.assertLess(
            cmd.index("FA_CONN_DEBUG=1"), cmd.index("fa --session-root")
        )

    def test_conn_trace_files_and_concurrency_ride_the_launch_line(self):
        cmd = self._launch_command(
            FA_CONN_DEBUG="1",
            FA_CONN_TRACE_FILE="/tmp/fa-conn-trace.jsonl",
            FA_CONN_PAYLOAD_SNAPSHOT="/tmp/fa-conn-snapshot.json",
            FA_BENCH_CONCURRENCY="2",
        )
        self.assertIn("FA_CONN_TRACE_FILE=/tmp/fa-conn-trace.jsonl", cmd)
        self.assertIn("FA_CONN_PAYLOAD_SNAPSHOT=/tmp/fa-conn-snapshot.json", cmd)
        self.assertIn("FA_BENCH_CONCURRENCY=2", cmd)

    def test_unset_conn_debug_is_not_forced_but_proof_still_captured(self):
        # Forward-when-set (bench.yml owns the opt-in); the grep capture
        # fires either way — an inherited-DARK env is exactly what the
        # proof file must show (issue #1406: never silent).
        cmd = self._launch_command()
        self.assertNotIn("FA_CONN_DEBUG", cmd)
        self.assertIn("env | grep FA_CONN", cmd)

    def test_launch_time_env_grep_proof_is_captured(self):
        cmd = self._launch_command(FA_CONN_DEBUG="1")
        self.assertIn(
            f"env | grep FA_CONN > "
            f"{self.fa_agent._CONTAINER_ENV_PROOF} 2>&1;",
            cmd,
        )

    def test_provider_secrets_stay_off_the_pane_line(self):
        # The pane stream is captured (pipe-pane, agent.cast): the launch
        # line carries only the non-secret diagnostic vars — provider
        # config/keys keep their base64 setup-env.sh transport.
        cmd = self._launch_command(
            FA_CONN_DEBUG="1",
            FA_PROVIDER_CONFIG='{"baseUrl":"https://x","apiKeyEnvVar":"K"}',
            K="sk-supersecret",
        )
        self.assertNotIn("sk-supersecret", cmd)
        self.assertNotIn("FA_PROVIDER_CONFIG", cmd)
        self.assertNotIn("BASE64", cmd)

    def test_launch_contract_unchanged_behind_the_env_prefix(self):
        # AC4: pure instrumentation — the fa invocation tb runs must stay
        # byte-for-byte (session root + shlex-quoted instruction).
        expected_launch = (
            "fa --session-root /agent-logs/fah-sessions -p 'do the thing'"
        )
        self.assertTrue(self._launch_command(FA_CONN_DEBUG="1").endswith(expected_launch))
        self.assertTrue(self._launch_command().endswith(expected_launch))


class LoudEmptyGuardTest(unittest.TestCase):
    """Issue #1406 AC2: requests == [] on a trial with real usage is an
    instrumentation outage — the guard names it loudly (stderr warning +
    a ::warning:: GitHub annotation + a conn-guard.json row), never
    silently ships the empty shell."""

    maxDiff = None

    @classmethod
    def setUpClass(cls):
        cls.fa_agent = _load_fa_agent_1406()

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.logging_dir = Path(self.tmpdir.name) / "t0"
        self.logging_dir.mkdir(parents=True)

    def _guarded(self, requests, usage_tokens):
        (self.logging_dir / "bench_metrics.json").write_text(
            json.dumps({"trial": "t0", "requests": requests})
        )
        err = StringIO()
        with redirect_stderr(err):
            self.fa_agent.FaAgent._guard_loud_empty(self.logging_dir, usage_tokens)
        return err.getvalue()

    def test_empty_requests_with_usage_fires_the_loud_warning(self):
        stderr = self._guarded([], 4321)
        self.assertIn("BENCH METRICS GUARD", stderr)
        self.assertIn("::warning::", stderr)
        self.assertIn("4321", stderr)
        guard = json.loads((self.logging_dir / "conn-guard.json").read_text())
        self.assertFalse(guard["ok"])
        self.assertEqual(guard["usage_tokens"], 4321)
        self.assertEqual(guard["requests"], 0)
        self.assertEqual(guard["guard"], "loud_empty")

    def test_nonempty_requests_pass_quietly(self):
        stderr = self._guarded([{"seq": 1, "first_byte_sec": 7.5}], 4321)
        self.assertEqual(stderr, "")
        guard = json.loads((self.logging_dir / "conn-guard.json").read_text())
        self.assertTrue(guard["ok"])

    def test_zero_usage_never_fires(self):
        # A trial that made no model request cannot be "dark" — its empty
        # shell is the honest shape.
        self.assertEqual(self._guarded([], 0), "")

    def test_none_logging_dir_no_ops_both_guards(self):
        # Stock-path trials without a logging dir never trip the guard.
        self.assertIsNone(self.fa_agent.FaAgent._guard_loud_empty(None, 5))
        self.assertIsNone(
            self.fa_agent.FaAgent._write_conn_env_proof(None, None)
        )

    def test_missing_metrics_file_is_not_a_violation(self):
        err = StringIO()
        with redirect_stderr(err):
            self.fa_agent.FaAgent._guard_loud_empty(self.logging_dir, 500)
        self.assertEqual(err.getvalue(), "")
        self.assertFalse((self.logging_dir / "conn-guard.json").exists())

    def test_corrupt_metrics_file_is_not_a_violation(self):
        (self.logging_dir / "bench_metrics.json").write_text("{not json")
        err = StringIO()
        with redirect_stderr(err):
            self.fa_agent.FaAgent._guard_loud_empty(self.logging_dir, 500)
        self.assertEqual(err.getvalue(), "")

    def test_predicate_is_pure(self):
        self.assertTrue(bench_metrics.loud_empty_violation({"requests": []}, 1))
        self.assertFalse(
            bench_metrics.loud_empty_violation({"requests": [{"seq": 1}]}, 1)
        )
        self.assertFalse(bench_metrics.loud_empty_violation({"requests": []}, 0))
        self.assertFalse(bench_metrics.loud_empty_violation({"requests": []}, None))
        self.assertFalse(bench_metrics.loud_empty_violation({}, 5))
        self.assertFalse(bench_metrics.loud_empty_violation(None, 5))


class _FakeFoldContainer:
    """exec_run surface for the fold: session JSONL + the env-proof cat.

    Returns a namedtuple like docker's ExecResult — fa_agent consumes
    exec_run both as a tuple (fold) and by attribute (pane taps).
    """

    _Exec = collections.namedtuple("_Exec", ["exit_code", "output"])

    def __init__(self, session_jsonl, env_proof):
        self._session_jsonl = session_jsonl
        self._env_proof = env_proof

    def exec_run(self, cmd, **kwargs):
        joined = " ".join(cmd)
        if "find" in joined and "-exec cat" in joined:
            return self._Exec(0, self._session_jsonl.encode())
        if "cat /tmp/fa-conn-env.txt" in joined:
            return self._Exec(0, self._env_proof)
        return self._Exec(0, b"")

    def get_archive(self, path):
        return ([b""], "unused.tar")


class _FakeFoldSession:
    """Minimal TmuxSession surface: just the container the fold touches."""

    def __init__(self, container):
        self.container = container


class FoldWiringTest(unittest.TestCase):
    """The usage fold is the common terminal path of BOTH adapter modes
    (stock and deadline) — the env-proof fold and the loud-empty guard
    must hang off it, so every bench trial gets them."""

    maxDiff = None

    @classmethod
    def setUpClass(cls):
        cls.fa_agent = _load_fa_agent_1406()

    def test_fold_writes_env_proof_and_fires_the_guard(self):
        tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(tmpdir.cleanup)
        logging_dir = Path(tmpdir.name) / "t0"
        logging_dir.mkdir(parents=True)
        (logging_dir / "bench_metrics.json").write_text(
            json.dumps({"trial": "t0", "requests": []})
        )
        session = _FakeFoldSession(
            _FakeFoldContainer(
                session_jsonl=(
                    '{"timestamp":"2025-01-01T00:00:00Z","message":{"role":"assistant",'
                    '"model":"m","usage":{"input":10,"output":5}}}\n'
                ),
                env_proof=(
                    b"FA_CONN_DEBUG=1\n"
                    b"FA_CONN_TRACE_FILE=/tmp/fa-conn-trace.jsonl\n"
                ),
            )
        )
        result = self.fa_agent.AgentResult(total_input_tokens=0, total_output_tokens=0)
        err = StringIO()
        with redirect_stderr(err):
            self.fa_agent.FaAgent._fold_session_usage(session, result, logging_dir)
        # Usage folded from the session records...
        self.assertEqual(result.total_input_tokens, 10)
        self.assertEqual(result.total_output_tokens, 5)
        # ...the launch-time env proof landed in agent-logs (AC1)...
        proof = (logging_dir / "fa-conn-env.txt").read_text()
        self.assertIn("FA_CONN_DEBUG=1", proof)
        # ...and the dark-ConnTrace trial fired the loud-empty guard (AC2).
        self.assertIn("BENCH METRICS GUARD", err.getvalue())
        guard = json.loads((logging_dir / "conn-guard.json").read_text())
        self.assertFalse(guard["ok"])
        self.assertEqual(guard["usage_tokens"], 15)

    def test_env_proof_fold_is_fail_soft(self):
        # A broken/wedged container must never fail the trial over a
        # proof artifact (same contract as every other fold step).
        class _BoomContainer:
            def exec_run(self, cmd, **kwargs):
                raise RuntimeError("container gone")

        err = StringIO()
        with redirect_stderr(err):
            self.fa_agent.FaAgent._write_conn_env_proof(
                _FakeFoldSession(_BoomContainer()), Path(tmp_dir := tempfile.mkdtemp())
            )
        self.assertIn("conn env proof not written", err.getvalue())
        self.assertFalse((Path(tmp_dir) / "fa-conn-env.txt").exists())


if __name__ == "__main__":
    unittest.main()
