#!/usr/bin/env python3
"""gh-1578: a verifier hang executing agent-authored code gets its own
agent-attributed `verifier_timeout` class — never the harness/infra
bucket — with the wall-clock each hang burned visible in the report.

Covers UT-1..UT-4, IT-1, REG-2 and the E1/E2/E4/E5 edges from the card's
test matrix; E2E-1 is artifact-gated (set HARBOR_JOBS_DIR to a merged
jobs dir containing the real fa-2.1-docker-cpu-4 shard).

Run: python3 -m unittest discover -s bench/harbor_fa
"""
import contextlib
import io
import json
import os
import random
import re
import tempfile
import unittest
from pathlib import Path

from summary import _hang_seconds, _is_verifier_timeout, main, render


def make_row(
    trial="fa-2.1-docker-cpu-4/trial-0",
    exception="",
    verifier_timeout=False,
    hang_secs=None,
    resolved=False,
    **kw,
):
    """A synthetic per-trial ledger row exactly as _trial_rows emits it."""
    row = {
        "resolved": resolved,
        "exception": exception,
        "verifier_timeout": verifier_timeout,
        "hang_secs": hang_secs,
        "tokens_in": 0,
        "tokens_out": 0,
        "cost": None,
        "estimated": 0,
        "checklist": "checklist: none",
        "trial": trial,
    }
    row.update(kw)
    return row


def _bucket_lines(out: str):
    """The two errored breakdown lines: verifier-timeout (agent) first,
    infra second. Either may be absent."""
    lines = out.splitlines()
    vt = [ln for ln in lines if ln.startswith("Verifier timeouts (verifier_timeout")]
    infra = [
        ln
        for ln in lines
        if ln.startswith("Errored trials (harness/infra failure, not scored):")
    ]
    return vt, infra


def _bucket_counts(text: str) -> int:
    return sum(int(m) for m in re.findall(r"×(\d+)", text))


def _reported_in(cls: str, text: str) -> bool:
    """True iff "<cls> ×N" is reported in a bucket line — word-boundary
    aware, so TimeoutError does not match inside VerifierTimeoutError."""
    return re.search(rf"(?<!\w){re.escape(cls)} ×", text) is not None


class ClassifierTest(unittest.TestCase):
    """UT-1 (pure): the verifier_timeout class keys on the harbor
    exception TYPE, never on timing (E1)."""

    def test_verifier_timeout_classes(self):
        self.assertTrue(_is_verifier_timeout("VerifierTimeoutError"))
        # Defensive: any future *Verifier*Timeout* harbor class.
        self.assertTrue(_is_verifier_timeout("VerifierTestTimeoutError"))
        self.assertTrue(_is_verifier_timeout("VerifierProcessTimeoutError"))

    def test_infra_classes_stay_infra(self):
        for cls in (
            "TimeoutError",
            "AgentTimeoutError",
            "NonZeroAgentExitCodeError",
            "ContainerCreateError",
            # E1: a verifier that CRASHED before running agent code —
            # verifier-shaped but no timeout — stays an infra error.
            "VerifierCrashedError",
            "",
        ):
            self.assertFalse(_is_verifier_timeout(cls), cls)


class HangSecondsTest(unittest.TestCase):
    """UT-4 (pure): the wall-clock a verifier hang burned (AC6) — from
    the exception message («timed out after N seconds») first, else the
    started_at/finished_at delta."""

    def test_from_exception_message(self):
        data = {
            "exception_info": {
                "exception_type": "VerifierTimeoutError",
                "exception_message": "Trial timed out after 1800 seconds",
            }
        }
        self.assertEqual(_hang_seconds(data), 1800.0)

    def test_float_seconds_case_insensitive(self):
        data = {"exception_info": {"exception_message": "Timed out after 1800.5 seconds"}}
        self.assertAlmostEqual(_hang_seconds(data), 1800.5)

    def test_from_started_finished_delta(self):
        data = {
            "started_at": "2025-01-01T09:00:00+00:00",
            "finished_at": "2025-01-01T09:46:00+00:00",
        }
        self.assertAlmostEqual(_hang_seconds(data), 46 * 60.0)

    def test_z_suffix_timestamps(self):
        data = {
            "started_at": "2025-01-01T09:00:00Z",
            "finished_at": "2025-01-01T09:30:00Z",
        }
        self.assertAlmostEqual(_hang_seconds(data), 1800.0)

    def test_mixed_naive_aware_timestamps(self):
        # Rework thread (PRRT_kwDOTXdlLc6sAKyM): mixed naive/aware stamps
        # across harbor versions must not raise TypeError in the delta
        # subtraction — a naive stamp is read as UTC (harbor clocks UTC).
        data = {
            "started_at": "2025-01-01T09:00:00",  # naive
            "finished_at": "2025-01-01T09:30:00+00:00",  # aware
        }
        self.assertAlmostEqual(_hang_seconds(data), 1800.0)

    def test_mixed_aware_naive_timestamps(self):
        # Same hazard, other direction.
        data = {
            "started_at": "2025-01-01T09:00:00Z",  # aware
            "finished_at": "2025-01-01T09:15:00",  # naive
        }
        self.assertAlmostEqual(_hang_seconds(data), 900.0)

    def test_unknown_when_nothing_parses(self):
        self.assertIsNone(_hang_seconds({}))
        self.assertIsNone(_hang_seconds({"exception_info": {}}))
        self.assertIsNone(_hang_seconds({"exception_info": {"exception_message": "boom"}}))
        self.assertIsNone(_hang_seconds({"started_at": "nope", "finished_at": "nope"}))
        # Negative delta (clock skew) is not a duration.
        self.assertIsNone(
            _hang_seconds(
                {
                    "started_at": "2025-01-01T09:46:00+00:00",
                    "finished_at": "2025-01-01T09:00:00+00:00",
                }
            )
        )
        # Malformed exception_info must never crash (E5).
        self.assertIsNone(_hang_seconds({"exception_info": "garbage"}))


class AttributionTest(unittest.TestCase):
    """UT-2: the narrative attributes a verifier hang to the agent side
    and never dresses it as an infra/harness failure."""

    def test_verifier_timeout_attributed_to_agent(self):
        rows = [
            make_row(exception="VerifierTimeoutError", verifier_timeout=True, hang_secs=1800)
        ]
        lines, problems = render({"cpu": rows, "gpu": []})
        self.assertEqual(problems, [])
        out = "\n".join(lines)
        self.assertIn("verifier_timeout", out)
        self.assertIn("agent code hung the verifier", out)
        self.assertIn("counts against the agent", out)
        # AC6: the trial's burned wall-clock is named, minutes included.
        self.assertIn(
            "- fa-2.1-docker-cpu-4/trial-0: VerifierTimeoutError,"
            " ~1800s (~30.0 min)",
            out,
        )
        vt, infra = _bucket_lines(out)
        self.assertEqual(len(vt), 1)
        # No infra errors → the infra label never appears at all (AC2).
        self.assertEqual(infra, [])
        self.assertNotIn("harness/infra failure", out)

    def test_verifier_timeout_never_in_infra_bucket(self):
        rows = [
            make_row(
                trial="j/hang",
                exception="VerifierTimeoutError",
                verifier_timeout=True,
                hang_secs=600.0,
            ),
            make_row(trial="j/infra", exception="AgentTimeoutError"),
        ]
        out = "\n".join(render({"cpu": rows, "gpu": []})[0])
        vt, infra = _bucket_lines(out)
        self.assertEqual(_bucket_counts("\n".join(vt)), 1)
        self.assertNotIn("VerifierTimeoutError", "\n".join(infra))
        self.assertIn("Errored trials (harness/infra failure, not scored): AgentTimeoutError ×1", out)

    def test_reporting_only_footer(self):
        # No reward fabrication: the score stays 0/error; the real fix is
        # upstream (harbor exposes no hook — explicitly reporting-only).
        rows = [
            make_row(exception="VerifierTimeoutError", verifier_timeout=True, hang_secs=None)
        ]
        out = "\n".join(render({"cpu": rows, "gpu": []})[0])
        self.assertIn("no reward is fabricated", out)
        self.assertIn("gh-1578", out)
        self.assertIn(
            "- fa-2.1-docker-cpu-4/trial-0: VerifierTimeoutError, duration unknown",
            out,
        )

    def test_multiple_hangs_aggregate_wall_clock(self):
        # E3: k of n trials hung — the class line counts ×k and states
        # the aggregate burn; every hang is listed per-trial.
        rows = [
            make_row(trial="j/hang-0", exception="VerifierTimeoutError",
                     verifier_timeout=True, hang_secs=1800.0),
            make_row(trial="j/hang-1", exception="VerifierTimeoutError",
                     verifier_timeout=True, hang_secs=600.0),
        ]
        out = "\n".join(render({"cpu": rows, "gpu": []})[0])
        vt, _ = _bucket_lines(out)
        self.assertEqual(len(vt), 1)
        self.assertIn("VerifierTimeoutError ×2", vt[0])
        self.assertIn("~2400s verifier wall-clock burned", vt[0])
        self.assertIn("- j/hang-0: VerifierTimeoutError, ~1800s (~30.0 min)", out)
        self.assertIn("- j/hang-1: VerifierTimeoutError, ~600s (~10.0 min)", out)


class ReconciliationPropertyTest(unittest.TestCase):
    """UT-3 (property): for randomized exception mixes every errored
    trial lands in exactly one reported class and the per-class counts
    sum to the errored total — nothing dropped, nothing double-counted."""

    CLASSES = [
        "VerifierTimeoutError",  # agent — verifier hang
        "VerifierTestTimeoutError",  # agent — defensive future class
        "AgentTimeoutError",  # infra
        "TimeoutError",  # infra
        "NonZeroAgentExitCodeError",  # infra
        "ContainerCreateError",  # infra (E1: crashed before agent code)
    ]

    def test_counts_reconcile_across_random_mixes(self):
        rnd = random.Random(1578)
        reconciled_rounds = 0
        for _ in range(25):
            rows = []
            for i in range(rnd.randint(0, 8)):
                cls = rnd.choice(self.CLASSES)
                vt = _is_verifier_timeout(cls)
                rows.append(
                    make_row(
                        trial=f"j/trial-{i}",
                        exception=cls,
                        verifier_timeout=vt,
                        hang_secs=60.0 if vt else None,
                    )
                )
            errored = sum(1 for r in rows if r["exception"])
            out = "\n".join(render({"cpu": rows, "gpu": []})[0])
            vt, infra = _bucket_lines(out)
            # Exactly one line per non-empty bucket.
            self.assertLessEqual(len(vt), 1)
            self.assertLessEqual(len(infra), 1)
            self.assertEqual(_bucket_counts("\n".join(vt + infra)), errored)
            if errored:
                reconciled_rounds += 1
            # Class-level: no class reported in both buckets (via the
            # word-boundary-aware marker helper).
            vt_text, infra_text = "\n".join(vt), "\n".join(infra)
            for cls in self.CLASSES:
                self.assertFalse(
                    _reported_in(cls, vt_text) and _reported_in(cls, infra_text),
                    cls,
                )
        self.assertGreater(reconciled_rounds, 0)


class CrossClassGuardTest(unittest.TestCase):
    """REG-2: every exception class seen across prior shards lands in
    exactly one reported class; a scored zero (E4: a future harbor
    mapping verifier timeouts onto reward 0 natively) is scored 0 —
    never double-attributed."""

    def test_every_class_in_exactly_one_bucket(self):
        classes = [
            "VerifierTimeoutError",
            "AgentTimeoutError",
            "NonZeroAgentExitCodeError",
            "TimeoutError",
        ]
        rows = [
            make_row(
                trial=f"j/{cls}",
                exception=cls,
                verifier_timeout=_is_verifier_timeout(cls),
            )
            for cls in classes
        ]
        out = "\n".join(render({"cpu": rows, "gpu": []})[0])
        vt, infra = _bucket_lines(out)
        vt_text, infra_text = "\n".join(vt), "\n".join(infra)
        self.assertIn("VerifierTimeoutError ×1", vt_text)
        self.assertFalse(_reported_in("VerifierTimeoutError", infra_text))
        for cls in ("AgentTimeoutError", "NonZeroAgentExitCodeError", "TimeoutError"):
            self.assertIn(f"{cls} ×1", infra_text)
            self.assertFalse(_reported_in(cls, vt_text))

    def test_scored_zero_never_double_attributed(self):
        # E4: reward 0.0 with NO exception → a scored zero on the
        # scoreboard, in neither breakdown.
        rows = [make_row(resolved=False)]
        out = "\n".join(render({"cpu": rows, "gpu": []})[0])
        vt, infra = _bucket_lines(out)
        self.assertEqual(vt + infra, [])
        self.assertIn("**Resolution: 0/1 scored trials**", out)


def write_result(trial_dir: Path, data) -> None:
    trial_dir.mkdir(parents=True)
    (trial_dir / "result.json").write_text(
        data if isinstance(data, str) else json.dumps(data)
    )


class IncidentIT(unittest.TestCase):
    """IT-1: a synthetic jobs dir mirroring fa-2.1-docker-cpu-4 — the
    real xtRpuH5 result.json shape, a clean resolved trial and a genuine
    infra error — renders three distinct attributions."""

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

    def test_three_distinct_attributions(self):
        job = self.jobs / "fa-2.1-docker-cpu-4"
        # (a) the real incident shape (gh-1578): the agent's attack.py hung
        # the verifier; harbor raised VerifierTimeoutError at the outer
        # 1800s bound, verifier_result null, no reward.
        write_result(
            job / "feal-differential-cryptanalysis__xtRpuH5",
            {
                "verifier_result": None,
                "exception_info": {
                    "exception_type": "VerifierTimeoutError",
                    "exception_message": "Trial timed out after 1800 seconds",
                    "exception_traceback": "…",
                },
                "started_at": "2025-01-01T09:00:00+00:00",
                "finished_at": "2025-01-01T09:46:00+00:00",
                "agent_result": {
                    "n_input_tokens": 120000,
                    "n_output_tokens": 30000,
                    "cost_usd": None,
                    "metadata": {},
                },
            },
        )
        # (b) a clean resolved trial.
        write_result(job / "resolved-trial", {"verifier_result": {"rewards": {"r": 1.0}}})
        # (c) a genuine infra error (agent-side ladder timeout).
        write_result(
            job / "infra-trial",
            {"exception_info": {"exception_type": "AgentTimeoutError"}},
        )
        rc, out = self._run(str(self.jobs), "--family", "2.1", "--expected-trials", "3")
        self.assertEqual(rc, 0)
        # Resolved trial scores normally.
        self.assertIn("**Resolution: 1/1 scored trials**", out)
        # The hang is agent-attributed with its wall-clock (AC1, AC2, AC6).
        self.assertIn("agent code hung the verifier", out)
        self.assertIn("VerifierTimeoutError ×1", out)
        self.assertIn(
            "- fa-2.1-docker-cpu-4/feal-differential-cryptanalysis__xtRpuH5:"
            " VerifierTimeoutError, ~1800s (~30.0 min)",
            out,
        )
        # The infra error keeps its own bucket, without the verifier class.
        self.assertIn(
            "Errored trials (harness/infra failure, not scored): AgentTimeoutError ×1",
            out,
        )
        # AC3: per-class counts reconcile to the errored total (2 of 3).
        self.assertIn("(2 errored before a verdict", out)
        vt, infra = _bucket_lines(out)
        self.assertEqual(_bucket_counts("\n".join(vt + infra)), 2)


class UnreadableResultTest(unittest.TestCase):
    """E5: malformed/missing exception_info and an unreadable result.json
    never crash and never misclassify as verifier_timeout."""

    def setUp(self):
        self._summary_bak = os.environ.pop("GITHUB_STEP_SUMMARY", None)
        self.addCleanup(self._restore_env)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.jobs = Path(tmp.name)

    def _restore_env(self):
        if self._summary_bak is not None:
            os.environ["GITHUB_STEP_SUMMARY"] = self._summary_bak

    def _run(self, *argv) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = main(list(argv))
        return rc, out.getvalue()

    def test_malformed_exception_info_not_verifier_timeout(self):
        # A non-dict exception_info carries no class → the legacy scored
        # shape (0 resolved here), never verifier_timeout, never a crash.
        job = self.jobs / "fa-2.1-docker-cpu-0"
        write_result(job / "weird", {"exception_info": "garbage", "verifier_result": None})
        rc, out = self._run(str(self.jobs))
        self.assertEqual(rc, 0)
        self.assertNotIn("verifier_timeout", out)
        self.assertIn("**Resolution: 0/1 scored trials**", out)

    def test_malformed_agent_result_never_crashes(self):
        # Same E5 robustness for the token/cost block: a non-dict
        # agent_result degrades to zeros + n/a cost.
        job = self.jobs / "fa-2.1-docker-cpu-0"
        write_result(
            job / "weird",
            {"verifier_result": {"rewards": {"r": 1.0}}, "agent_result": "garbage"},
        )
        rc, out = self._run(str(self.jobs))
        self.assertEqual(rc, 0)
        self.assertIn("**Resolution: 1/1 scored trials**", out)
        self.assertIn("| CPU shards | 1/1 | 100.0% | 0/0 | n/a |", out)

    def test_missing_exception_info_not_verifier_timeout(self):
        job = self.jobs / "fa-2.1-docker-cpu-0"
        write_result(job / "plain", {"verifier_result": {"rewards": {"r": 0.0}}})
        rc, out = self._run(str(self.jobs))
        self.assertEqual(rc, 0)
        self.assertNotIn("verifier_timeout", out)
        self.assertIn("**Resolution: 0/1 scored trials**", out)

    def test_corrupt_result_json_counts_as_unattempted(self):
        # An unreadable result.json is NOT a trial: it never enters any
        # class and the lost-shard guard keeps its teeth (presence counts).
        job = self.jobs / "fa-2.1-docker-cpu-0"
        write_result(job / "good", {"verifier_result": {"rewards": {"r": 1.0}}})
        write_result(job / "torn", "{not json")
        rc, out = self._run(str(self.jobs), "--expected-trials", "2")
        self.assertEqual(rc, 1)
        self.assertIn("Incomplete run: 1/2 expected trials attempted", out)
        self.assertNotIn("verifier_timeout", out)


class MixedTimezoneRenderTest(unittest.TestCase):
    """E5 hardening (rework thread PRRT_kwDOTXdlLc6sAKyM): a
    verifier-hang trial whose started_at/finished_at mix naive and aware
    stamps (mixed sources across harbor versions) must render the full
    summary — the TypeError in the delta fallback must never kill it."""

    def setUp(self):
        self._summary_bak = os.environ.pop("GITHUB_STEP_SUMMARY", None)
        self.addCleanup(self._restore_env)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.jobs = Path(tmp.name)

    def _restore_env(self):
        if self._summary_bak is not None:
            os.environ["GITHUB_STEP_SUMMARY"] = self._summary_bak

    def _run(self, *argv) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = main(list(argv))
        return rc, out.getvalue()

    def test_render_survives_mixed_naive_aware_stamps(self):
        # No «timed out after N seconds» message → the delta fallback is
        # exercised with a naive started_at against an aware finished_at.
        job = self.jobs / "fa-2.1-docker-cpu-0"
        write_result(
            job / "mixed-tz",
            {
                "verifier_result": None,
                "exception_info": {"exception_type": "VerifierTimeoutError"},
                "started_at": "2025-01-01T09:00:00",  # naive
                "finished_at": "2025-01-01T09:30:00+00:00",  # aware
            },
        )
        rc, out = self._run(str(self.jobs))
        self.assertEqual(rc, 0)
        self.assertIn("agent code hung the verifier", out)
        self.assertIn(
            "- fa-2.1-docker-cpu-0/mixed-tz: VerifierTimeoutError, ~1800s (~30.0 min)",
            out,
        )
        self.assertNotIn(
            "Errored trials (harness/infra failure, not scored): VerifierTimeoutError",
            out,
        )


class MalformedRewardsTest(unittest.TestCase):
    """E5 completion (rework thread PRRT_kwDOTXdlLc6sGjPV): a
    verifier_result whose rewards values are not numeric — or whose
    rewards is not a dict at all — degrades instead of crashing the
    whole summary render."""

    def setUp(self):
        self._summary_bak = os.environ.pop("GITHUB_STEP_SUMMARY", None)
        self.addCleanup(self._restore_env)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.jobs = Path(tmp.name)

    def _restore_env(self):
        if self._summary_bak is not None:
            os.environ["GITHUB_STEP_SUMMARY"] = self._summary_bak

    def _run(self, *argv) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = main(list(argv))
        return rc, out.getvalue()

    def test_non_numeric_reward_value_degrades(self):
        # {"r": "high"} used to raise ValueError inside float(v).
        job = self.jobs / "fa-2.1-docker-cpu-0"
        write_result(
            job / "labeled",
            {"verifier_result": {"rewards": {"r": "high"}}},
        )
        rc, out = self._run(str(self.jobs))
        self.assertEqual(rc, 0)
        self.assertIn("**Resolution: 0/1 scored trials**", out)

    def test_null_reward_value_degrades(self):
        # {"r": null} used to raise TypeError inside float(v).
        job = self.jobs / "fa-2.1-docker-cpu-0"
        write_result(job / "nulled", {"verifier_result": {"rewards": {"r": None}}})
        rc, out = self._run(str(self.jobs))
        self.assertEqual(rc, 0)
        self.assertIn("**Resolution: 0/1 scored trials**", out)

    def test_mixed_numeric_and_garbage_rewards(self):
        # Unparseable values are skipped; the numeric ones still score.
        job = self.jobs / "fa-2.1-docker-cpu-0"
        write_result(
            job / "mixed",
            {"verifier_result": {"rewards": {"a": 1.0, "b": "high", "c": None}}},
        )
        rc, out = self._run(str(self.jobs))
        self.assertEqual(rc, 0)
        self.assertIn("**Resolution: 1/1 scored trials**", out)

    def test_non_dict_rewards_degrade(self):
        # A truthy non-dict rewards used to raise AttributeError on
        # .values() — the E5 dict-guard pattern applies here too.
        job = self.jobs / "fa-2.1-docker-cpu-0"
        write_result(job / "stringy", {"verifier_result": {"rewards": "garbage"}})
        rc, out = self._run(str(self.jobs))
        self.assertEqual(rc, 0)
        self.assertIn("**Resolution: 0/1 scored trials**", out)


class TolerantRowKeysTest(unittest.TestCase):
    """render() reads the gh-1578 row keys tolerantly (rework thread
    PRRT_kwDOTXdlLc6sGjRj) — the gh-1579 _status() precedent: hand-built
    rows that predate the verifier_timeout/hang_secs keys render without
    a KeyError."""

    @staticmethod
    def _legacy_row(**kw):
        # The row shape BEFORE gh-1578 added verifier_timeout/hang_secs.
        row = {
            "resolved": False,
            "exception": "",
            "tokens_in": 0,
            "tokens_out": 0,
            "cost": None,
            "estimated": 0,
            "checklist": "checklist: none",
            "trial": "j/legacy",
        }
        row.update(kw)
        return row

    def test_legacy_row_without_gh1578_keys_renders(self):
        rows = [self._legacy_row(resolved=True)]
        lines, problems = render({"cpu": rows, "gpu": []})
        self.assertEqual(problems, [])
        self.assertIn("**Resolution: 1/1 scored trials**", "\n".join(lines))

    def test_legacy_errored_row_without_gh1578_keys_renders(self):
        rows = [self._legacy_row(exception="AgentTimeoutError")]
        lines, _ = render({"cpu": rows, "gpu": []})
        self.assertIn(
            "Errored trials (harness/infra failure, not scored): AgentTimeoutError ×1",
            "\n".join(lines),
        )

    def test_verifier_timeout_row_without_hang_secs(self):
        rows = [self._legacy_row(exception="VerifierTimeoutError",
                                 verifier_timeout=True)]
        lines, _ = render({"cpu": rows, "gpu": []})
        out = "\n".join(lines)
        self.assertIn("agent code hung the verifier", out)
        self.assertIn("- j/legacy: VerifierTimeoutError, duration unknown", out)


@unittest.skipUnless(
    os.environ.get("HARBOR_JOBS_DIR"),
    "E2E-1 needs the real fa-2.1-docker-cpu-4 artifacts (run 38271607849); "
    "set HARBOR_JOBS_DIR to the merged jobs dir to run",
)
class RealArtifactsE2ETest(unittest.TestCase):
    """E2E-1: snapshot-assert the exact incident this card was filed
    from — trial feal-differential-cryptanalysis__xtRpuH5 must surface
    under the verifier_timeout class with its burned wall-clock."""

    def test_xtrpuh5_verifier_hang_snapshot(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = main([os.environ["HARBOR_JOBS_DIR"], "--family", "2.1"])
        self.assertEqual(rc, 0)
        report = out.getvalue()
        self.assertIn("agent code hung the verifier", report)
        self.assertIn("VerifierTimeoutError ×1", report)
        self.assertIn("feal-differential-cryptanalysis__xtRpuH5", report)
        self.assertNotIn("harness/infra failure, not scored): VerifierTimeoutError", report)


if __name__ == "__main__":
    unittest.main()
