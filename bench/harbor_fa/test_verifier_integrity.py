#!/usr/bin/env python3
"""gh-1579 — verifier integrity gate: pure classifier tests (UT-1..UT-5).

The fixtures under fixtures/verifier_integrity/ are pinned golden inputs
(regenerate with generate.py):

- ``filter-js-from-html__hoBwRwp-test-stdout.txt`` — the gh-1579 incident
  (run 38271607849, job fa-2.1-docker-cpu-4): 4 of 28 browser batches
  never loaded (batches 2, 5, 16, 20 — 66 of 439 vectors silently
  skipped) while the verifier still claimed
  ``✓ Filter successfully blocked all 439 XSS attack vectors!``.
- the four clean sibling stdouts (4FpkEin, NmQswud, t4MK34E, UX5zWxE) —
  negative fixtures: zero failed loads, a handful of retries.

Run: python3 -m unittest discover -s bench/harbor_fa
"""
import importlib.util
import sys
import tempfile
import time
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "verifier_integrity", _HERE / "verifier_integrity.py"
)
vi = importlib.util.module_from_spec(spec)
sys.modules["verifier_integrity"] = vi
spec.loader.exec_module(vi)

FIXTURES = _HERE / "fixtures" / "verifier_integrity"

INCIDENT_CLAIM = "✓ Filter successfully blocked all 439 XSS attack vectors!"
SIBLINGS = ("4FpkEin", "NmQswud", "t4MK34E", "UX5zWxE")


def _fixture(name: str) -> str:
    return (FIXTURES / f"filter-js-from-html__{name}-test-stdout.txt").read_text()


def _loads(verdict) -> list:
    return [s for s in verdict.signals if isinstance(s, vi.FailedLoad)]


class ClassifierSignalTest(unittest.TestCase):
    """UT-1 / REG-1 / AC1+AC2: the incident stdout is always detected."""

    def setUp(self):
        self.stdout = _fixture("hoBwRwp")

    def test_incident_stdout_classifies_compromised(self):
        verdict = vi.classify(self.stdout)
        self.assertEqual(verdict.status, vi.COMPROMISED)

    def test_exactly_four_failed_loads_in_batches_2_5_16_20(self):
        verdict = vi.classify(self.stdout)
        loads = _loads(verdict)
        self.assertEqual(len(loads), 4)
        self.assertEqual(sorted(s.batch for s in loads), [2, 5, 16, 20])

    def test_skipped_tests_is_66(self):
        verdict = vi.classify(self.stdout)
        self.assertEqual(verdict.skipped_tests, 66)  # 17+17+16+16

    def test_success_claim_captured_verbatim(self):
        # AC2/UT-1: the S3 lie marker is the exact stdout line.
        verdict = vi.classify(self.stdout)
        claims = [s for s in verdict.signals if isinstance(s, vi.SuccessClaim)]
        self.assertEqual(len(claims), 1)
        self.assertEqual(claims[0].claim, INCIDENT_CLAIM)
        self.assertEqual(claims[0].total_tests, 439)

    def test_retry_storm_also_signalled(self):
        # 84 retry warnings ride along with the skipped batches; S1 wins
        # for the status, S2 is recorded so post-mortems see the churn.
        verdict = vi.classify(self.stdout)
        storms = [s for s in verdict.signals if isinstance(s, vi.RetryStorm)]
        self.assertEqual(len(storms), 1)
        self.assertEqual(storms[0].count, 84)

    def test_describe_pins_the_report_detail(self):
        verdict = vi.classify(self.stdout)
        self.assertEqual(
            verdict.describe(),
            "batches 2,5,16,20 skipped — 66/439 vectors never ran",
        )


class CleanSiblingTest(unittest.TestCase):
    """UT-2 / REG-2 / AC5: the four clean siblings must never be flagged."""

    def test_all_clean_siblings_classify_ok(self):
        for name in SIBLINGS:
            with self.subTest(trial=name):
                verdict = vi.classify(_fixture(name))
                self.assertEqual(verdict.status, vi.OK)
                self.assertEqual(verdict.signals, ())
                self.assertIsNone(verdict.skipped_tests)

    def test_honest_success_claim_alone_is_not_a_signal(self):
        # E6: a lone "✓ blocked all N" is the normal clean case; S3
        # requires S1 in the same stdout.
        verdict = vi.classify(_fixture("4FpkEin"))
        self.assertFalse(
            any(isinstance(s, vi.SuccessClaim) for s in verdict.signals)
        )
        self.assertIn(INCIDENT_CLAIM.splitlines()[0].replace("439", "439"),
                      _fixture("4FpkEin"))  # the claim IS in the text


class RetryStormTest(unittest.TestCase):
    """UT-3 / AC6 / E3: S2 alone downgrades to suspect, never quarantines."""

    @staticmethod
    def _storm(count: int) -> str:
        header = "RUN BATCH 1 (contains 439 tests)\n"
        retries = (
            "urllib3.connectionpool - WARNING - Retrying (Retry(total=2, "
            "connect=None, read=None, redirect=None, status=None)) after "
            "connection broken by 'ConnectionResetError(104, Connection "
            "reset by peer)': /session\n"
        )
        return header + retries * count + "2 passed\n"

    def test_threshold_constant_is_pinned(self):
        # E3: the calibration is a named constant; the clean siblings
        # (≤ 8 retries) and the incident (84) sit either side of it.
        self.assertEqual(vi.RETRY_STORM_THRESHOLD, 20)

    def test_storm_at_threshold_is_suspect_without_quarantine(self):
        verdict = vi.classify(self._storm(vi.RETRY_STORM_THRESHOLD))
        self.assertEqual(verdict.status, vi.SUSPECT)
        self.assertEqual(verdict.skipped_tests, None)

    def test_storm_below_threshold_is_ok(self):
        verdict = vi.classify(self._storm(vi.RETRY_STORM_THRESHOLD - 1))
        self.assertEqual(verdict.status, vi.OK)
        self.assertEqual(verdict.signals, ())

    def test_suspect_never_fires_from_a_clean_stdout(self):
        # REG-2 guard: the clean siblings' handful of retries stays ok.
        for name in SIBLINGS:
            self.assertNotEqual(vi.classify(_fixture(name)).status, vi.SUSPECT)


class UnreadableTest(unittest.TestCase):
    """UT-4 / E4 / I2: absent, undecodable, or blank stdout is unreadable —
    never ok, never a crash."""

    def test_missing_stdout_is_unreadable(self):
        self.assertEqual(vi.classify(None).status, vi.UNREADABLE)

    def test_blank_stdout_is_unreadable(self):
        self.assertEqual(vi.classify("").status, vi.UNREADABLE)
        self.assertEqual(vi.classify("  \n \n").status, vi.UNREADABLE)

    def test_nul_byte_garbage_is_unreadable(self):
        self.assertEqual(vi.classify("progress\x00\x01\x02garbage").status,
                         vi.UNREADABLE)

    def test_read_stdout_reports_missing_undecodable_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            trial = Path(tmp)
            text, reason = vi.read_stdout(trial)
            self.assertEqual((text, reason), (None, "missing"))
            vdir = trial / "verifier"
            vdir.mkdir()
            (vdir / "test-stdout.txt").write_bytes(b"\xff\xfe\x00binary")
            text, reason = vi.read_stdout(trial)
            self.assertEqual((text, reason), (None, "undecodable"))
            (vdir / "test-stdout.txt").write_bytes(b"  \n\n")
            text, reason = vi.read_stdout(trial)
            self.assertEqual((text, reason), (None, "empty"))
            (vdir / "test-stdout.txt").write_text("2 passed\n")
            text, reason = vi.read_stdout(trial)
            self.assertEqual((text, reason), ("2 passed\n", "ok"))


class AdversarialInputTest(unittest.TestCase):
    """UT-4: hostile shapes never crash the classifier and never cost
    super-linear time; the degradation rules are pinned."""

    def test_truncated_mid_batch_header_does_not_crash(self):
        text = (
            "RUN BATCH 1 (contains 16 tests)\nv1-1: blocked\n"
            "RUN BATCH 7 (contains 1"  # cut mid-header, no newline
        )
        verdict = vi.classify(text)
        # No explicit failure signal → no quarantine (explicit-signal
        # discipline); the partial header contributes no skipped tests.
        self.assertEqual(verdict.status, vi.OK)
        self.assertIsNone(verdict.skipped_tests)

    def test_header_without_a_following_verdict_is_ok(self):
        verdict = vi.classify("RUN BATCH 3 (contains 12 tests)\n")
        self.assertEqual(verdict.status, vi.OK)

    def test_truncated_file_keeps_the_signals_it_saw(self):
        # A failure visible before the cut is still a failure.
        text = (
            "RUN BATCH 2 (contains 17 tests)\n"
            "Failed to load URL: HTTPConnectionPool(host='localhost', "
            "port=41863): Read timed out. (read timeout=120)\n"
            "RUN BATCH 3 (contains 1"
        )
        verdict = vi.classify(text)
        self.assertEqual(verdict.status, vi.COMPROMISED)
        self.assertEqual(verdict.skipped_tests, 17)

    def test_hundred_megabyte_stdout_parses_in_linear_time(self):
        # ReDoS / resource bound: bounded literal+simple-regex line scan;
        # a 100 MB adversarial repetition must stay in seconds.
        line = "v1-1: <img src=x onerror=alert(1)> -> blocked\n"
        blob = line * (100 * 1024 * 1024 // len(line) + 1)
        self.assertGreaterEqual(len(blob), 100 * 1024 * 1024)
        start = time.monotonic()
        verdict = vi.classify(blob)
        elapsed = time.monotonic() - start
        self.assertEqual(verdict.status, vi.OK)
        self.assertLess(elapsed, 30.0, f"100 MB parse took {elapsed:.1f}s")


class BatchBindingTest(unittest.TestCase):
    """UT-5 / E1: binding to the preceding RUN BATCH header, never
    misattributed; prologue failures bind to no batch."""

    def test_failed_load_before_any_header_binds_unknown(self):
        text = (
            "Failed to load URL: HTTPConnectionPool(host='localhost', "
            "port=41861): Read timed out. (read timeout=120)\n"
            "RUN BATCH 1 (contains 16 tests)\n"
            "v1-1: blocked\n"
        )
        verdict = vi.classify(text)
        self.assertEqual(verdict.status, vi.COMPROMISED)
        loads = _loads(verdict)
        self.assertEqual(len(loads), 1)
        self.assertIsNone(loads[0].batch)
        self.assertIsNone(loads[0].n_tests)
        # E1: unknown-bindings contribute 0 to skipped_tests…
        self.assertEqual(verdict.skipped_tests, 0)
        # …and are listed as unknown in the report detail.
        self.assertEqual(
            verdict.describe(),
            "batches unknown skipped — skipped-test count unknown",
        )

    def test_failed_load_binds_to_the_current_header(self):
        text = (
            "RUN BATCH 1 (contains 16 tests)\n"
            "v1-1: blocked\n"
            "RUN BATCH 4 (contains 15 tests)\n"
            "Failed to load URL: HTTPConnectionPool(host='localhost', "
            "port=41865): Read timed out. (read timeout=120)\n"
        )
        verdict = vi.classify(text)
        self.assertEqual(_loads(verdict)[0].batch, 4)
        self.assertEqual(verdict.skipped_tests, 15)

    def test_repeat_failure_in_the_same_batch_counts_once(self):
        text = (
            "RUN BATCH 9 (contains 14 tests)\n"
            "Failed to load URL: HTTPConnectionPool(host='localhost', "
            "port=41870): Read timed out. (read timeout=120)\n"
            "Failed to load URL: HTTPConnectionPool(host='localhost', "
            "port=41870): Read timed out. (read timeout=120)\n"
        )
        verdict = vi.classify(text)
        self.assertEqual(len(_loads(verdict)), 1)
        self.assertEqual(verdict.skipped_tests, 14)


class SignalShapeTest(unittest.TestCase):
    """E8: the S1 pattern is bound to the full driver-failure shape —
    neither the bare substring nor a lookalike may fire it."""

    def test_bare_failed_to_load_substring_is_not_a_signal(self):
        verdict = vi.classify("Failed to load URL: http://localhost:8000/page\n")
        self.assertEqual(verdict.status, vi.OK)

    def test_driver_shape_without_failed_load_prefix_is_not_a_signal(self):
        verdict = vi.classify(
            "HTTPConnectionPool(host='localhost', port=41861): Read timed "
            "out. (read timeout=120)\n"
        )
        self.assertEqual(verdict.status, vi.OK)

    def test_connection_refused_page_load_is_a_signal(self):
        # The incident names both failure modes as silent skips.
        text = (
            "RUN BATCH 6 (contains 16 tests)\n"
            "Failed to load URL: HTTPConnectionPool(host='localhost', "
            "port=41867): Connection refused.\n"
        )
        verdict = vi.classify(text)
        self.assertEqual(verdict.status, vi.COMPROMISED)
        self.assertEqual(verdict.skipped_tests, 16)


if __name__ == "__main__":
    unittest.main()
