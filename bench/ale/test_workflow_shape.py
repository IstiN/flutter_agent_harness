#!/usr/bin/env python3
"""Workflow-shape pins for bench-ale.yml (issue #1686, review gh-2081).

bench-harbor pins its own workflow in Python (test_bench_harbor_workflow);
this suite mirrors that minimally for the ALE workflow. Every pin here
guards a finding from the gh-2081 machine review (stdlib text pins — the
bench-ale plan job runs this suite WITHOUT pip installs, so no yaml dep):

  * the summary job runs even when a shard fails (`if: always()`) and
    carries job-level `permissions: contents: write` for the gh-1682
    ledger push (workflow default stays contents: read),
  * no step-level `permissions:` key (GitHub's push-time validator
    rejects it — repo lesson, PR #1566),
  * dispatch inputs / secrets never interpolate into `run:` shell —
    they ride `env:` blocks (the plan job's discipline),
  * the canonical bench secret env (config.py FA_BENCH_ZAI_KEY
    constant) is what the run step writes into secret/.env,
  * the task-data cache lives OUTSIDE the checkout (actions/checkout
    clean:true wipes anything inside ale/ before the fetch step runs),
  * umask 077 precedes `mkdir -p secret` (dir mode 0700, not just the
    credential file),
  * no --api-key-env flag anywhere (CodeQL round 3: the env-var NAME
    is a build-time constant, never a CLI arg).

Run: python3 -m unittest discover -s bench/ale
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_ALE_YML = _REPO_ROOT / ".github" / "workflows" / "bench-ale.yml"


def _workflow_text() -> str:
    return _ALE_YML.read_text(encoding="utf-8")


def _job_block(text: str, job: str) -> str:
    """Lines of one top-level job (4-space indent) until the next job."""
    m = re.search(rf"(?m)^  {re.escape(job)}:\n", text)
    if not m:
        raise AssertionError(f"job `{job}` missing from bench-ale.yml")
    lines = [m.group(0)]
    for line in text[m.end():].splitlines(keepends=True):
        if re.match(r"^  \S", line):
            break
        lines.append(line)
    return "".join(lines)


def _run_blocks(block: str) -> list[str]:
    """Every `run: |` block body inside a job block."""
    bodies: list[str] = []
    lines = block.splitlines()
    for i, line in enumerate(lines):
        if not re.match(r"^\s+run: \|", line):
            continue
        indent = len(line) - len(line.lstrip())
        body: list[str] = []
        for follow in lines[i + 1:]:
            if follow.strip() and (len(follow) - len(follow.lstrip())) <= indent:
                break
            body.append(follow)
        bodies.append("\n".join(body))
    return bodies


@unittest.skipUnless(
    _ALE_YML.exists(), "bench-ale.yml not found (standalone bench checkout)"
)
class WorkflowShapeTest(unittest.TestCase):
    def setUp(self):
        self.text = _workflow_text()
        self.summary = _job_block(self.text, "summary")
        self.agent = _job_block(self.text, "agent")

    # ── review BLOCKING 1+2: verdicts when shards fail; ledger perms ──
    def test_summary_job_runs_even_when_shards_fail(self):
        # `if: always()` sits in the job header (before `steps:`), so a
        # failed `agent` need no longer skips the verdict/bundle job.
        header = self.summary.split("steps:")[0]
        self.assertIn("    if: always()\n", header)

    def test_summary_job_has_job_level_contents_write(self):
        # Job-level = exactly 4-space indent under the job key.
        self.assertRegex(self.summary, r"(?m)^    permissions:\n      contents: write\n")
        # The workflow default stays least-privilege.
        self.assertRegex(self.text, r"(?m)^permissions:\n  contents: read\n")

    def test_summary_job_needs_plan_and_agent(self):
        self.assertRegex(self.summary, r"(?m)^    needs: \[plan, agent\]\n")

    # ── validator-proven shapes (repo lesson PR #1566) ────────────────
    def test_no_step_level_permissions_key(self):
        for i, line in enumerate(self.text.splitlines(), 1):
            if re.match(r"^\s{6,}permissions:", line):
                self.fail(f"step-level permissions: at line {i} — the GitHub "
                          "push-time validator rejects step-level permissions keys")

    def test_no_api_key_env_flag_anywhere(self):
        self.assertNotIn("--api-key-env", self.text)

    # ── env-ify discipline: inputs/secrets never hit run: shell ──────
    def test_no_inputs_or_secrets_interpolated_into_run_blocks(self):
        for job in ("plan", "agent", "summary"):
            block = _job_block(self.text, job)
            for run_body in _run_blocks(block):
                for pattern in ("${{ inputs.", "${{ secrets."):
                    self.assertNotIn(pattern, run_body)

    # ── canonical secret env written into the experiment env file ────
    def test_run_step_writes_canonical_secret_env_name(self):
        self.assertIn("printf 'FA_BENCH_ZAI_KEY=%s", self.agent)

    def test_umask_precedes_secret_mkdir(self):
        run_bodies = _run_blocks(self.agent)
        self.assertTrue(run_bodies, "agent job has no run blocks")
        for body in run_bodies:
            mkdir_i = body.find("mkdir -p secret")
            if mkdir_i == -1:
                continue
            umask_i = body.find("umask 077")
            self.assertNotEqual(umask_i, -1, "umask 077 missing where secret/ is created")
            self.assertLess(umask_i, mkdir_i, "umask must precede mkdir -p secret (dir mode 0700)")

    # ── task-data cache outside the checkout (review gh-2081) ────────
    def test_task_data_cache_marker_lives_outside_the_checkout(self):
        self.assertIn("$cache/task-data-v1.1/.fetched-revision", self.agent)
        self.assertIn("ln -sfn \"$cache/task-data-v1.1\" task-data-v1.1", self.agent)
        # No checkout-internal marker: any bare occurrence (not prefixed
        # with $cache) would be wiped by actions/checkout clean:true.
        for line in self.agent.splitlines():
            if ".fetched-revision" in line:
                self.assertIn("$cache/task-data-v1.1/.fetched-revision", line, line.strip())


if __name__ == "__main__":
    unittest.main()
