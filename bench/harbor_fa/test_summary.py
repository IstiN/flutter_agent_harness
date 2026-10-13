#!/usr/bin/env python3
"""Unit tests for summary.py (issue #1124). Run: python3 -m unittest discover -s bench/harbor_fa"""
import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

from summary import main


def make_jobs(root: Path, name: str, trials: list[dict]) -> None:
    """trials: [{'resolved': bool} | {'exception': 'TimeoutError'}, ...]"""
    job = root / name
    for i, trial in enumerate(trials):
        d = job / f"trial-{i}"
        d.mkdir(parents=True)
        if "exception" in trial:
            data = {"exception_info": {"exception_type": trial["exception"]}}
        else:
            score = 1.0 if trial["resolved"] else 0.0
            data = {"verifier_result": {"rewards": {"r": score}}}
        (d / "result.json").write_text(json.dumps(data))


class SummaryTest(unittest.TestCase):
    def setUp(self):
        # Hermetic: CI exports GITHUB_STEP_SUMMARY for EVERY step, and
        # summary.py prefers that sink over stdout when set — the first
        # revision of these tests failed on real Actions runners. Pop it
        # by default; the sink test below re-points it at a temp file.
        # BENCH_RUN_LABEL (gh-1503) gets the same treatment so a runner
        # exporting it cannot leak into the label-absence test.
        self._summary_bak = os.environ.pop("GITHUB_STEP_SUMMARY", None)
        self._label_bak = os.environ.pop("BENCH_RUN_LABEL", None)
        self.addCleanup(self._restore_summary)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.jobs = Path(tmp.name)

    def _restore_summary(self):
        if self._summary_bak is not None:
            os.environ["GITHUB_STEP_SUMMARY"] = self._summary_bak
        if self._label_bak is not None:
            os.environ["BENCH_RUN_LABEL"] = self._label_bak
    def _run(self, *argv) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = main(list(argv))
        return rc, out.getvalue()

    def test_step_summary_sink(self):
        # The sink CI actually uses: with GITHUB_STEP_SUMMARY set, the
        # report must land in the file (stdout stays quiet).
        sink = self.jobs / "step-summary.md"
        make_jobs(self.jobs, "fa-3.0-modal-cpu-0", [{"resolved": True}])
        os.environ["GITHUB_STEP_SUMMARY"] = str(sink)
        rc, out = self._run(
            str(self.jobs), "--family", "3.0", "--model", "glm-5.3-flash",
            "--fa-ref", "abc1234", "--run-url", "https://ci/run/1",
        )
        self.assertEqual(rc, 0)
        self.assertEqual(out, "")
        report = sink.read_text()
        self.assertIn("### fa on Terminal-Bench 3.0", report)
        self.assertIn("Ledger row", report)

    def test_run_label_names_the_provider_when_set(self):
        # gh-1503: the report names the provider+model (BENCH_RUN_LABEL,
        # set by bench-harbor.yml's resolve step) — glm and kimi runs
        # never blend in the ledger/cost views. Same env contract as
        # bench.yml's gh-1471 summary.
        make_jobs(self.jobs, "fa-2.1-modal-cpu-0", [{"resolved": True}])
        os.environ["BENCH_RUN_LABEL"] = "kimi-for-coding"
        self.addCleanup(os.environ.pop, "BENCH_RUN_LABEL", None)
        rc, out = self._run(
            str(self.jobs), "--family", "2.1", "--model", "kimi-for-coding",
            "--fa-ref", "abc1234", "--run-url", "https://ci/run/1",
        )
        self.assertEqual(rc, 0)
        self.assertIn("Provider: kimi-for-coding (gh-1503).", out)

    def test_run_label_absent_stays_silent(self):
        # Runs without the env (CLI/manual invocations) keep the
        # pre-gh-1503 report shape byte-for-byte.
        make_jobs(self.jobs, "fa-2.1-modal-cpu-0", [{"resolved": True}])
        rc, out = self._run(
            str(self.jobs), "--family", "2.1", "--model", "glm-5.3-flash",
            "--fa-ref", "abc1234", "--run-url", "https://ci/run/1",
        )
        self.assertEqual(rc, 0)
        self.assertNotIn("Provider:", out)

    def test_ledger_separation_across_versions(self):
        # A merged jobs dir carrying two dataset versions: the 2.1 report
        # must count ONLY the fa-2.1-* jobs (no cross-contamination).
        make_jobs(self.jobs, "fa-2.1-modal-cpu-0", [{"resolved": True}, {"resolved": False}])
        make_jobs(self.jobs, "fa-2.1-modal-gpu-0", [{"resolved": True}])
        make_jobs(self.jobs, "fa-4.0-modal-cpu-0", [{"resolved": True}, {"resolved": True}])
        rc, out = self._run(
            str(self.jobs), "--family", "2.1", "--model", "glm-5.3-flash",
            "--fa-ref", "abc1234", "--run-url", "https://ci/run/1",
        )
        self.assertEqual(rc, 0)
        self.assertIn("### fa on Terminal-Bench 2.1 (terminal-bench/terminal-bench-2-1@latest)", out)
        self.assertIn("**Resolution: 2/3 scored trials**", out)
        self.assertIn("| CPU shards | 1/2 | 50.0% |", out)
        self.assertIn("| GPU shards | 1/1 | 100.0% |", out)
        # The foreign 4.0 trials are filtered out, not merged in (4/5).
        self.assertNotIn("4/5", out)
        # Paste-ready ledger row, keyed per version. Trials here carry no
        # token usage → the #1123 accounting renders the cost n/a, never
        # a made-up price.
        self.assertIn("| terminal-bench/terminal-bench-2-1@latest | glm-5.3-flash | abc1234 |", out)
        self.assertIn("| 2/3 trials (66.7%) |", out)
        self.assertIn("| n/a | https://ci/run/1 |", out)

    def test_ledger_row_carries_real_cost(self):
        # Composition #1123 + #1124: priced trials flow their cost total
        # into the ledger row's cost cell.
        job = self.jobs / "fa-2.1-modal-cpu-0"
        for i, (resolved, tin, tout, cost) in enumerate([
            (True, 310, 80, 8.74e-05),
            (False, 50, 10, None),
        ]):
            d = job / f"trial-{i}"
            d.mkdir(parents=True)
            data = {
                "verifier_result": {"rewards": {"r": 1.0 if resolved else 0.0}},
                "agent_result": {
                    "n_input_tokens": tin,
                    "n_output_tokens": tout,
                    "cost_usd": cost,
                    "metadata": {},
                },
            }
            (d / "result.json").write_text(json.dumps(data))
        rc, out = self._run(
            str(self.jobs), "--family", "2.1", "--model", "glm-5.3-flash",
            "--fa-ref", "abc1234", "--run-url", "https://ci/run/1",
        )
        self.assertEqual(rc, 0)
        self.assertIn("**Spend: $0.0001 — tokens in/out: 360/90", out)
        self.assertIn("| 1/2 trials (50.0%) | $0.0001 | https://ci/run/1 |", out)

    def test_errored_trials_excluded_from_ledger_counts(self):
        make_jobs(self.jobs, "fa-3.0-docker-cpu-0", [{"resolved": True}, {"exception": "TimeoutError"}])
        rc, out = self._run(str(self.jobs), "--family", "3.0")
        self.assertIn("**Resolution: 1/1 scored trials**", out)
        self.assertIn("TimeoutError ×1", out)

    def test_incomplete_run_fails(self):
        make_jobs(self.jobs, "fa-2.0-docker-cpu-0", [{"resolved": True}])
        rc, out = self._run(str(self.jobs), "--family", "2.0", "--expected-trials", "10")
        self.assertEqual(rc, 1)
        self.assertIn("1/10 expected trials", out)

    def test_no_jobs_for_family_fails(self):
        make_jobs(self.jobs, "fa-4.0-docker-cpu-0", [{"resolved": True}])
        rc, out = self._run(str(self.jobs), "--family", "2.1")
        self.assertEqual(rc, 1)
        self.assertIn("No harbor jobs found", out)

    def test_unknown_family_rejected(self):
        # Direct summary calls reject unknown families loudly (rc 2 +
        # stderr annotation) instead of rendering a mis-keyed report.
        import contextlib, io
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc, out = self._run(str(self.jobs), "--family", "9.9")
        self.assertEqual(rc, 2)
        self.assertEqual(out, "")
        self.assertIn("unknown Terminal-Bench family '9.9'", err.getvalue())

    def test_legacy_invocation_unchanged(self):
        # No --family: pre-#1124 behaviour (all job dirs, 4.0 title).
        make_jobs(self.jobs, "fa-4.0-docker-cpu-0", [{"resolved": True}])
        rc, out = self._run(str(self.jobs))
        self.assertEqual(rc, 0)
        self.assertIn("### fa on Terminal-Bench 4.0", out)
        self.assertIn("**Resolution: 1/1 scored trials**", out)
        self.assertNotIn("Ledger row", out)


class PresenceCompletenessTest(unittest.TestCase):
    """gh-1556 AC3/AC4: completeness counts by result.json PRESENCE.

    The TB 2.0 aggregate reddened on legitimate dataset-cap timeouts:
    errored trials (a readable result.json with an exception class) counted
    as unattempted, the exception count was a hard problem, and the only
    way to read the report was downloading the merged artifact. Now: an
    errored trial counts as attempted, the errored class is its own
    breakdown line (never a verdict), exit 1 is reserved for genuinely
    lost trials, and the full report (table + errored breakdown + ledger
    row) renders to $GITHUB_STEP_SUMMARY.
    """

    def setUp(self):
        self._summary_bak = os.environ.pop("GITHUB_STEP_SUMMARY", None)
        self._label_bak = os.environ.pop("BENCH_RUN_LABEL", None)
        self.addCleanup(self._restore_env)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.jobs = Path(tmp.name)

    def _restore_env(self):
        if self._summary_bak is not None:
            os.environ["GITHUB_STEP_SUMMARY"] = self._summary_bak
        if self._label_bak is not None:
            os.environ["BENCH_RUN_LABEL"] = self._label_bak

    def _run(self, *argv) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = main(list(argv))
        return rc, out.getvalue()

    def test_errored_trials_count_as_attempted_and_do_not_redden(self):
        # The exact TB 2.0 shape: one resolved, one unresolved, one
        # errored at a dataset cap — all three produced a result.json.
        make_jobs(
            self.jobs,
            "fa-2.0-docker-cpu-0",
            [
                {"resolved": True},
                {"resolved": False},
                {"exception": "AgentTimeoutError"},
            ],
        )
        rc, out = self._run(str(self.jobs), "--family", "2.0", "--expected-trials", "3")
        self.assertEqual(rc, 0)
        self.assertIn("**Resolution: 1/2 scored trials**", out)
        self.assertIn("**Attempted: 3 trials produced a result.json "
                      "(1 errored before a verdict", out)
        self.assertIn("AgentTimeoutError ×1", out)
        self.assertIn("Errored trials (harness/infra failure, not scored)", out)

    def test_errored_still_counted_with_mixed_exception_classes(self):
        # 2+ errored items with different exception classes — the
        # breakdown lists every class, the presence count aggregates.
        make_jobs(
            self.jobs,
            "fa-2.0-docker-cpu-0",
            [
                {"exception": "AgentTimeoutError"},
                {"exception": "AgentTimeoutError"},
                {"exception": "NonZeroAgentExitCodeError"},
            ],
        )
        rc, out = self._run(str(self.jobs), "--family", "2.0", "--expected-trials", "3")
        self.assertEqual(rc, 0)
        self.assertIn("AgentTimeoutError ×2", out)
        self.assertIn("NonZeroAgentExitCodeError ×1", out)
        self.assertIn("0/0 scored trials", out)

    def test_genuinely_lost_trials_still_fail(self):
        # The lost-shard guard keeps its teeth: a trial with NO
        # result.json never appears in the jobs dir at all.
        make_jobs(self.jobs, "fa-2.0-docker-cpu-0", [{"resolved": True}])
        rc, out = self._run(str(self.jobs), "--family", "2.0", "--expected-trials", "2")
        self.assertEqual(rc, 1)
        self.assertIn("Incomplete run: 1/2 expected trials attempted", out)

    def test_no_jobs_still_fails(self):
        rc, out = self._run(str(self.jobs), "--family", "2.0", "--expected-trials", "2")
        self.assertEqual(rc, 1)
        self.assertIn("No harbor jobs found", out)

    def test_step_summary_carries_table_errored_breakdown_and_ledger(self):
        # gh-1556 AC4 (TB1 parity): the aggregate surfaces the resolution
        # table, the errored breakdown and the paste-ready ledger row in
        # the job's step summary — reading a result must not require
        # downloading the merged artifact.
        make_jobs(
            self.jobs,
            "fa-2.0-docker-cpu-0",
            [{"resolved": True}, {"exception": "AgentTimeoutError"}],
        )
        sink = self.jobs / "step-summary.md"
        os.environ["GITHUB_STEP_SUMMARY"] = str(sink)
        rc, _ = self._run(
            str(self.jobs), "--family", "2.0", "--model", "glm-5.3-flash",
            "--fa-ref", "abc1234", "--run-url", "https://ci/run/1",
            "--expected-trials", "2",
        )
        self.assertEqual(rc, 0)
        report = sink.read_text()
        self.assertIn("| split | resolved | rate | tokens in/out | est cost |", report)
        self.assertIn("Errored trials (harness/infra failure, not scored):", report)
        self.assertIn("AgentTimeoutError ×1", report)
        self.assertIn("### Ledger row — append to docs/bench.md", report)
        self.assertIn("**Attempted: 2 trials produced a result.json", report)


def _write_ledger(trial_dir: Path, items: list[dict]) -> None:
    """The hidden `task_ledger` session record exactly as the Dart side
    persists it (gh-1412): a `custom` record, customType task_ledger."""
    sessions = trial_dir / "agent" / "fah-sessions"
    sessions.mkdir(parents=True)
    record = {"type": "custom", "customType": "task_ledger", "data": {"items": items}}
    (sessions / "session.jsonl").write_text(json.dumps(record) + "\n")


_ITEM = {
    "requirement": "index page content",
    "command": "curl -s localhost:80",
    "expected": "welcome",
    "actual": "welcome",
    "status": "pass",
}


class ChecklistCoverageTest(unittest.TestCase):
    """gh-1412: the near-miss proximity block from hidden task ledgers."""

    def setUp(self):
        # Same hermetic setup as SummaryTest (no inheritance — the base
        # suite must not double-run through a subclass).
        self._summary_bak = os.environ.pop("GITHUB_STEP_SUMMARY", None)
        self.addCleanup(self._restore_summary)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.jobs = Path(tmp.name)

    def _restore_summary(self):
        if self._summary_bak is not None:
            os.environ["GITHUB_STEP_SUMMARY"] = self._summary_bak

    def _run(self, *argv) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = main(list(argv))
        return rc, out.getvalue()

    def _run_default(self) -> tuple[int, str]:
        return self._run(str(self.jobs))

    def test_no_ledgers_stay_silent(self):
        make_jobs(self.jobs, "fa-4.0-docker-cpu-0", [{"resolved": True}])
        rc, out = self._run_default()
        self.assertEqual(rc, 0)
        self.assertNotIn("Checklist coverage", out)

    def test_proximity_block_lists_incomplete_trials(self):
        make_jobs(
            self.jobs,
            "fa-4.0-docker-cpu-0",
            [{"resolved": False}, {"resolved": True}],
        )
        job = self.jobs / "fa-4.0-docker-cpu-0"
        _write_ledger(
            job / "trial-0",
            [dict(_ITEM) for _ in range(6)] + [dict(_ITEM, status="fail")],
        )
        _write_ledger(job / "trial-1", [dict(_ITEM)])
        rc, out = self._run_default()
        self.assertEqual(rc, 0)
        self.assertIn(
            "Checklist coverage (gh-1412): 1/2 ledgered trials fully verified",
            out,
        )
        self.assertIn("- fa-4.0-docker-cpu-0/trial-0: checklist: 6/7 (1 unmet)", out)
        # The fully-verified trial is counted, not listed.
        self.assertNotIn("trial-1: checklist", out)

    def test_corrupt_ledger_payload_never_crashes(self):
        # gh-1412 review (empirically reproduced in round 2): a non-dict
        # `data` must degrade to `checklist: none`, never kill the render
        # (the Dart fold tolerates the same shapes).
        make_jobs(
            self.jobs,
            "fa-4.0-docker-cpu-0",
            [{"resolved": True}, {"resolved": True}, {"resolved": True},
             {"resolved": True}],
        )
        job = self.jobs / "fa-4.0-docker-cpu-0"
        for index, garbage in enumerate((3, "garbage", [1, 2], {"items": "nope"})):
            trial = job / f"trial-{index}"
            sessions = trial / "agent" / "fah-sessions"
            sessions.mkdir(parents=True, exist_ok=True)
            (sessions / "session.jsonl").write_text(
                json.dumps({
                    "type": "custom",
                    "customType": "task_ledger",
                    "data": garbage,
                })
                + "\n"
            )
        rc, out = self._run_default()
        self.assertEqual(rc, 0)
        self.assertNotIn("Checklist coverage", out)

    def test_empty_ledger_is_not_fully_verified(self):
        # A ledger with no items verifies nothing — rendering 0/0 would
        # count the trial as fully verified in the coverage tally.
        make_jobs(self.jobs, "fa-4.0-docker-cpu-0", [{"resolved": True}])
        _write_ledger(self.jobs / "fa-4.0-docker-cpu-0" / "trial-0", [])
        rc, out = self._run_default()
        self.assertEqual(rc, 0)
        self.assertNotIn("Checklist coverage", out)


_POISON_STDOUT = (
    "RUN BATCH 3 (contains 17 tests)\n"
    "urllib3.connectionpool - WARNING - Retrying (Retry(total=2, connect=None, "
    "read=None, redirect=None, status=None)) after connection broken by "
    "'NewConnectionError('<urllib3.connection.HTTPConnection object at "
    "0x7f9c01>: Failed to establish a new connection: [Errno 111] Connection "
    "refused')': /session\n"
    "Failed to load URL: HTTPConnectionPool(host='localhost', port=41864): "
    "Read timed out. (read timeout=120)\n"
    "✓ Filter successfully blocked all 17 XSS attack vectors!\n"
)
_CLEAN_STDOUT = (
    "RUN BATCH 3 (contains 17 tests)\n"
    "✓ Filter successfully blocked all 17 XSS attack vectors!\n"
    "2 passed\n"
)
_STORM_STDOUT = (
    "RUN BATCH 3 (contains 17 tests)\n"
    + "urllib3.connectionpool - WARNING - Retrying (Retry(total=0, "
      "connect=None, read=None, redirect=None, status=None)) after connection "
      "broken by 'ConnectionResetError(104, Connection reset by peer)': "
      "/session\n"
    * 21
    + "2 passed\n"
)


def _write_integrity_trial(
    job: Path,
    name: str,
    scores: dict | None,
    stdout: str | None = None,
    exception: str = "",
) -> None:
    """A trial dir with a result.json and an optional verifier stdout."""
    d = job / name
    d.mkdir(parents=True)
    if exception:
        data = {"exception_info": {"exception_type": exception}}
    else:
        data = {"verifier_result": {"rewards": scores or {}}}
    (d / "result.json").write_text(json.dumps(data), encoding="utf-8")
    if stdout is not None:
        (d / "verifier").mkdir()
        (d / "verifier" / "test-stdout.txt").write_text(stdout, encoding="utf-8")


class IntegrityGateTest(unittest.TestCase):
    """gh-1579 — the verifier integrity gate folded into the report.

    A compromised verifier run (tests that never executed) can never
    count as resolved: it leaves the scored pool into its own reported
    class (excluded from numerator AND clean denominator), whether its
    reward was 1.0 (a poisoned pass) or 0.0 (annotated fail). Missing or
    undecodable stdout on a pass is flagged verifier_unreadable — never
    silently trusted. Legacy layouts without verifier stdout keep their
    byte-shape except the unreadable annotation.
    """

    def setUp(self):
        self._summary_bak = os.environ.pop("GITHUB_STEP_SUMMARY", None)
        self._label_bak = os.environ.pop("BENCH_RUN_LABEL", None)
        self.addCleanup(self._restore_env)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.jobs = Path(tmp.name)

    def _restore_env(self):
        if self._summary_bak is not None:
            os.environ["GITHUB_STEP_SUMMARY"] = self._summary_bak
        if self._label_bak is not None:
            os.environ["BENCH_RUN_LABEL"] = self._label_bak

    def _run(self, *argv) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = main(list(argv))
        return rc, out.getvalue()

    def test_compromised_pass_excluded_from_resolution_and_denominator(self):
        # IT-1 / AC3 / E5: a reward-1.0 trial whose verifier skipped work
        # is not resolved and not in the clean denominator; totals stay
        # consistent: resolved + unresolved_clean + compromised == scored.
        job = self.jobs / "fa-2.1-docker-cpu-4"
        _write_integrity_trial(job, "trial-0", {"main": 1.0}, _CLEAN_STDOUT)
        _write_integrity_trial(job, "trial-1", {"main": 0.0}, _CLEAN_STDOUT)
        # E5: multiple reward keys — one poisoned stdout taints the trial.
        _write_integrity_trial(
            job, "trial-2", {"main": 1.0, "secondary": 1.0}, _POISON_STDOUT
        )
        _write_integrity_trial(job, "trial-3", {"main": 0.0}, _POISON_STDOUT)
        rc, out = self._run(
            str(self.jobs), "--family", "2.1", "--expected-trials", "4"
        )
        self.assertEqual(rc, 0)  # presence-counted: all four attempted
        self.assertIn("**Resolution: 1/2 scored trials**", out)
        self.assertIn(
            "**Attempted: 4 trials produced a result.json "
            "(2 verifier-compromised (verdict untrusted) — see the "
            "integrity breakdown below)**",
            out,
        )
        self.assertIn(
            "Verifier-compromised trials (verdict untrusted, excluded from "
            "resolution): fa-2.1-docker-cpu-4/trial-2 (batches 3 skipped — "
            "17/17 vectors never ran), fa-2.1-docker-cpu-4/trial-3 (batches "
            "3 skipped — 17/17 vectors never ran) ×2",
            out,
        )
        self.assertIn("| CPU shards | 1/2 | 50.0%; 2 verifier-compromised |", out)
        # The identity holds on the parsed rows.
        from summary import _trial_rows

        rows = _trial_rows(job)
        scored = [r for r in rows if not r["exception"]]
        resolved = sum(
            1 for r in scored
            if r["integrity"].status != "compromised" and r["resolved"]
        )
        clean_unresolved = sum(
            1 for r in scored
            if r["integrity"].status != "compromised" and not r["resolved"]
        )
        compromised = sum(
            1 for r in scored if r["integrity"].status == "compromised"
        )
        self.assertEqual(resolved + clean_unresolved + compromised, len(scored))

    def test_compromised_fail_keeps_verdict_and_annotates(self):
        # IT-2 / AC4: reward 0.0 + compromised stdout — verdict direction
        # unchanged, trust annotation in the same breakdown line.
        job = self.jobs / "fa-2.1-docker-cpu-4"
        _write_integrity_trial(job, "trial-0", {"main": 0.0}, _POISON_STDOUT)
        rc, out = self._run(str(self.jobs), "--family", "2.1")
        self.assertEqual(rc, 0)
        self.assertIn("**Resolution: 0/0 scored trials**", out)
        self.assertIn(
            "Verifier-compromised trials (verdict untrusted, excluded from "
            "resolution): fa-2.1-docker-cpu-4/trial-0 (batches 3 skipped — "
            "17/17 vectors never ran) ×1",
            out,
        )
        self.assertIn("| CPU shards | 0/0 | 1 verifier-compromised |", out)

    def test_missing_stdout_on_pass_flags_verifier_unreadable(self):
        # IT-3 / AC7: a pass the gate could not inspect is flagged, not
        # silently trusted; the summary never crashes and still scores.
        job = self.jobs / "fa-2.1-docker-cpu-4"
        _write_integrity_trial(job, "trial-0", {"main": 1.0})
        rc, out = self._run(str(self.jobs), "--family", "2.1")
        self.assertEqual(rc, 0)
        self.assertIn("**Resolution: 1/1 scored trials**", out)
        self.assertIn(
            "Verifier-unreadable trials (no readable verifier stdout — pass "
            "not gate-checked): fa-2.1-docker-cpu-4/trial-0 (stdout missing) ×1",
            out,
        )

    def test_legacy_layout_byte_identical_except_unreadable_annotation(self):
        # REG-3 / AC8: pre-gate runs (no verifier/ dirs) keep their shape
        # — same resolution line, no new classes — plus the annotation.
        job = self.jobs / "fa-4.0-docker-cpu-0"
        _write_integrity_trial(job, "trial-0", {"verifier": 1.0})
        _write_integrity_trial(job, "trial-1", {"verifier": 0.0})
        rc, out = self._run(str(self.jobs), "--expected-trials", "2")
        self.assertEqual(rc, 0)
        self.assertIn("**Resolution: 1/2 scored trials**", out)
        self.assertIn("| CPU shards | 1/2 | 50.0% |", out)
        self.assertNotIn("Verifier-compromised", out)
        self.assertNotIn("Verifier-suspect", out)
        # The failing trial is not flagged: unreadable matters on passes.
        self.assertNotIn("trial-1 (stdout missing)", out)
        self.assertIn(
            "fa-4.0-docker-cpu-0/trial-0 (stdout missing) ×1",
            out,
        )

    def test_suspect_annotated_without_score_change(self):
        # AC6 at report level: retry-storm-only stdout annotates, the
        # verdict stands.
        job = self.jobs / "fa-2.1-docker-cpu-4"
        _write_integrity_trial(job, "trial-0", {"main": 1.0}, _STORM_STDOUT)
        rc, out = self._run(str(self.jobs), "--family", "2.1")
        self.assertEqual(rc, 0)
        self.assertIn("**Resolution: 1/1 scored trials**", out)
        self.assertIn(
            "Verifier-suspect trials (retry/connection storm — annotated, "
            "verdict stands): fa-2.1-docker-cpu-4/trial-0 (21 retry/connection "
            "warnings) ×1",
            out,
        )
        self.assertNotIn("Verifier-compromised", out)

    def test_mixed_errored_and_compromised_classes(self):
        # REG-4 / E7: errored wins for scoring (gh-1556 unchanged), and
        # the compromise signal of an errored trial is still recorded in
        # the breakdown for post-mortems.
        job = self.jobs / "fa-2.1-docker-cpu-4"
        _write_integrity_trial(
            job, "trial-0", None, _POISON_STDOUT, exception="AgentTimeoutError"
        )
        _write_integrity_trial(job, "trial-1", None, exception="AgentTimeoutError")
        _write_integrity_trial(job, "trial-2", {"main": 1.0}, _CLEAN_STDOUT)
        rc, out = self._run(
            str(self.jobs), "--family", "2.1", "--expected-trials", "3"
        )
        self.assertEqual(rc, 0)
        self.assertIn(
            "Errored trials (harness/infra failure, not scored): "
            "AgentTimeoutError ×2",
            out,
        )
        self.assertIn("**Resolution: 1/1 scored trials**", out)
        # The errored-but-compromised trial is listed in the integrity
        # breakdown even though it never entered the scored pool.
        self.assertIn(
            "Verifier-compromised trials (verdict untrusted, excluded from "
            "resolution): fa-2.1-docker-cpu-4/trial-0 (batches 3 skipped — "
            "17/17 vectors never ran) ×1",
            out,
        )
        # The attempted line explains only the errored delta (the
        # compromised trial here was already errored — no pool change).
        self.assertIn(
            "(2 errored before a verdict — see the errored breakdown below)",
            out,
        )

    def test_report_never_quotes_stdout_beyond_metadata(self):
        # Security: report lines quote batch/skip metadata only — never
        # raw stdout blobs (the environment may echo secrets).
        job = self.jobs / "fa-2.1-docker-cpu-4"
        _write_integrity_trial(job, "trial-0", {"main": 1.0}, _POISON_STDOUT)
        rc, out = self._run(str(self.jobs), "--family", "2.1")
        self.assertEqual(rc, 0)
        self.assertNotIn("HTTPConnectionPool", out)
        self.assertNotIn("Retrying (Retry", out)
        self.assertNotIn("✓ Filter successfully blocked", out)
        self.assertNotIn("x00", out)

    def test_ledger_row_annotated_when_compromised_exist(self):
        # IT-4: the paste-ready docs/bench.md row carries the caveat so a
        # pasted row never silently includes compromised trials.
        job = self.jobs / "fa-2.1-docker-cpu-4"
        _write_integrity_trial(job, "trial-0", {"main": 1.0}, _POISON_STDOUT)
        _write_integrity_trial(job, "trial-1", {"main": 1.0}, _CLEAN_STDOUT)
        rc, out = self._run(
            str(self.jobs), "--family", "2.1", "--model", "glm-5.3-flashx",
            "--fa-ref", "abc1234", "--run-url", "https://ci/run/38271607849",
        )
        self.assertEqual(rc, 0)
        self.assertIn("| 1/1 trials (100.0%) |", out)
        self.assertIn(
            "gh-1579: 1 verifier-compromised trial (verdict untrusted) is "
            "excluded from the resolution above — do not paste without the "
            "caveat.",
            out,
        )

    def test_ledger_caveat_counts_scored_compromised_only(self):
        # The caveat states the pool delta a paste-consumer must know:
        # an errored-but-compromised trial was already excluded from
        # resolution by the errored class (gh-1556) BEFORE the gate saw
        # it, so it stays in the breakdown line (post-mortem) but does
        # not count in the caveat — only scored trials changed pools.
        job = self.jobs / "fa-2.1-docker-cpu-4"
        _write_integrity_trial(
            job, "trial-0", None, _POISON_STDOUT, exception="AgentTimeoutError"
        )
        _write_integrity_trial(job, "trial-1", {"main": 1.0}, _POISON_STDOUT)
        rc, out = self._run(
            str(self.jobs), "--family", "2.1", "--model", "glm-5.3-flashx",
            "--fa-ref", "abc1234", "--run-url", "https://ci/run/38271607849",
        )
        self.assertEqual(rc, 0)
        # The breakdown lists both compromised trials…
        self.assertIn("trial-0 (batches 3 skipped", out)
        self.assertIn("trial-1 (batches 3 skipped", out)
        # …but the caveat claims only the pool delta (scored-only).
        self.assertIn(
            "gh-1579: 1 verifier-compromised trial (verdict untrusted) is "
            "excluded from the resolution above — do not paste without the "
            "caveat.",
            out,
        )
        self.assertNotIn("2 verifier-compromised", out)

    def test_ledger_caveat_absent_when_every_compromised_was_errored(self):
        # No scored trial changed pools → no caveat to state; the
        # breakdown line still lists the errored-but-compromised trial.
        job = self.jobs / "fa-2.1-docker-cpu-4"
        _write_integrity_trial(
            job, "trial-0", None, _POISON_STDOUT, exception="AgentTimeoutError"
        )
        rc, out = self._run(
            str(self.jobs), "--family", "2.1", "--model", "glm-5.3-flashx",
            "--fa-ref", "abc1234", "--run-url", "https://ci/run/38271607849",
        )
        self.assertEqual(rc, 0)
        self.assertIn("trial-0 (batches 3 skipped", out)
        self.assertNotIn("do not paste without the caveat", out)

    def test_clean_stdouts_leave_the_report_untouched(self):
        # The gate is additive: clean readable verifier stdout adds no
        # lines at all.
        job = self.jobs / "fa-2.1-docker-cpu-4"
        _write_integrity_trial(job, "trial-0", {"main": 1.0}, _CLEAN_STDOUT)
        rc, out = self._run(str(self.jobs), "--family", "2.1")
        self.assertEqual(rc, 0)
        self.assertIn("**Resolution: 1/1 scored trials**", out)
        self.assertNotIn("Verifier-compromised", out)
        self.assertNotIn("Verifier-suspect", out)
        self.assertNotIn("Verifier-unreadable", out)

    def test_real_incident_fixture_end_to_end(self):
        # E2E-1 shape (AC10) on the pinned fixtures: the run-38271607849
        # shard tree had 5 filter-js-from-html trials — hoBwRwp with the
        # poisoned stdout (reward 0 via the honest other test) and the
        # four clean siblings. The report must name hoBwRwp's skipped
        # batches, keep the siblings unflagged, and recompute the rate
        # over the trusted pool only.
        fixtures = Path(__file__).resolve().parent / "fixtures" / "verifier_integrity"
        job = self.jobs / "fa-2.1-docker-cpu-4"

        def fixture_stdout(trial: str) -> str:
            return (
                fixtures / f"filter-js-from-html__{trial}-test-stdout.txt"
            ).read_text(encoding="utf-8")

        _write_integrity_trial(
            job, "filter-js-from-html__hoBwRwp", {"main": 0.0},
            fixture_stdout("hoBwRwp"),
        )
        for sibling in ("4FpkEin", "NmQswud", "t4MK34E", "UX5zWxE"):
            _write_integrity_trial(
                job, f"filter-js-from-html__{sibling}", {"main": 1.0},
                fixture_stdout(sibling),
            )
        rc, out = self._run(
            str(self.jobs), "--family", "2.1",
            "--model", "glm-5.3-flashx", "--fa-ref", "abc1234",
            "--run-url", "https://ci/run/38271607849",
            "--expected-trials", "5",
        )
        self.assertEqual(rc, 0)
        self.assertIn("**Resolution: 4/4 scored trials**", out)
        self.assertIn(
            "Verifier-compromised trials (verdict untrusted, excluded from "
            "resolution): fa-2.1-docker-cpu-4/filter-js-from-html__hoBwRwp "
            "(batches 2,5,16,20 skipped — 66/439 vectors never ran) ×1",
            out,
        )
        self.assertIn(
            "**Attempted: 5 trials produced a result.json "
            "(1 verifier-compromised (verdict untrusted) — see the "
            "integrity breakdown below)**",
            out,
        )
        # Zero false positives on the clean siblings.
        for sibling in ("4FpkEin", "NmQswud", "t4MK34E", "UX5zWxE"):
            self.assertNotIn(f"{sibling} (batches", out)
        # The 84-retry storm of the incident ride-along stays out of the
        # suspect line (S2 never quarantines on its own, and S1 already
        # fired): no trial appears in both lines.
        self.assertNotIn("Verifier-suspect", out)
        self.assertIn(
            "gh-1579: 1 verifier-compromised trial (verdict untrusted) is "
            "excluded from the resolution above — do not paste without the "
            "caveat.",
            out,
        )

    def test_real_incident_stdout_end_to_end(self):
        # E2E-1/AC10 on the REAL run-38271607849 artifact bytes (not the
        # synthesis): a reward-1.0 pass carrying the real poisoned stdout
        # is quarantined — the rate recomputes over the trusted pool only
        # — while the real sibling stdout (apt prologue, bare-CR progress
        # lines, zero failed loads) stays unflagged.
        fixtures = Path(__file__).resolve().parent / "fixtures" / "verifier_integrity"
        job = self.jobs / "fa-2.1-docker-cpu-4"

        def real_stdout(trial: str) -> str:
            return (
                fixtures / f"filter-js-from-html__{trial}-test-stdout.real.txt"
            ).read_text(encoding="utf-8")

        _write_integrity_trial(
            job, "filter-js-from-html__hoBwRwp", {"main": 1.0},
            real_stdout("hoBwRwp"),
        )
        _write_integrity_trial(
            job, "filter-js-from-html__4FpkEin", {"main": 1.0},
            real_stdout("4FpkEin"),
        )
        rc, out = self._run(
            str(self.jobs), "--family", "2.1",
            "--model", "glm-5.3-flashx", "--fa-ref", "abc1234",
            "--run-url", "https://ci/run/38271607849",
            "--expected-trials", "2",
        )
        self.assertEqual(rc, 0)
        # The poisoned pass (reward 1.0 + real incident stdout) leaves the
        # pool; the trusted sibling carries the resolution.
        self.assertIn("**Resolution: 1/1 scored trials**", out)
        self.assertIn(
            "Verifier-compromised trials (verdict untrusted, excluded from "
            "resolution): fa-2.1-docker-cpu-4/filter-js-from-html__hoBwRwp "
            "(batches 2,5,16,20 skipped — 66/439 vectors never ran) ×1",
            out,
        )
        self.assertIn(
            "**Attempted: 2 trials produced a result.json "
            "(1 verifier-compromised (verdict untrusted) — see the "
            "integrity breakdown below)**",
            out,
        )
        # Zero false positives on the real sibling.
        self.assertNotIn("4FpkEin (batches", out)
        self.assertNotIn("Verifier-suspect", out)
        self.assertIn(
            "gh-1579: 1 verifier-compromised trial (verdict untrusted) is "
            "excluded from the resolution above — do not paste without the "
            "caveat.",
            out,
        )


if __name__ == "__main__":
    unittest.main()
