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

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_BENCH_YML = _REPO_ROOT / ".github" / "workflows" / "bench.yml"


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

    def test_shard_packing_wired_to_cap_minus_headroom(self):
        # 355-min job cap − 15 min headroom = 340 (issue #1392 ShardPacker;
        # round 2 lost shard-0 by ~1 min with zero headroom).
        text = _yml_text()
        self.assertIn("--job-cap-seconds", text)
        self.assertIn("--job-cap-seconds 340", text)

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

    def test_extension_on_pins_harness_cap_above_abs_ceiling(self):
        # Round 3: with the progress watch on, the ladder ceiling is the
        # abs ceiling (default 3600s) — the 4x+180 pin would guillotine
        # an extended-but-progressing trial below our own decision point.
        self.assertIn("${FA_AGENT_TIMEOUT_ABS_CEILING_SEC:-3600}", _yml_text())


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


if __name__ == "__main__":
    unittest.main()
