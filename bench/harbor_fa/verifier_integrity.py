#!/usr/bin/env python3
"""Verifier integrity gate (gh-1579) — classify harbor verifier stdout.

A harbor trial's verifier can silently skip work: the filter-js-from-html
verifier drives 439 XSS vectors through a real Chrome in 28 batches, and
when a batch page fails to load (chromedriver read timeout / connection
refused) the batch's vectors are silently skipped and implicitly counted
as blocked — while the test still prints its success claim. The scorer
that only reads `rewards` then trusts a lie.

This module is the named protocol every trust decision about a verifier
verdict passes through: ``classify(stdout_text) -> IntegrityVerdict``.
It is PURE — stdout text in, a structured verdict out, no IO, no eval,
no shell, no template rendering of captured groups (verifier stdout is
task-influenced output: data, never instructions). The file read lives in
``read_stdout`` (called from summary._trial_rows); captured log text is
length-capped before it leaves this module, and report lines built from a
verdict quote only batch/skip metadata, never raw log blobs.

Signals (the core set):

- S1 ``FailedLoad`` — a ``Failed to load URL: HTTPConnectionPool(...):
  Read timed out|Connection refused|ConnectionResetError`` line, bound to
  the preceding ``RUN BATCH N (contains K tests)`` header (batch id +
  skipped-test count). A failure seen before any header binds to no
  batch (batch=None, E1) and contributes 0 to ``skipped_tests``. One
  signal per batch (repeat failures in the same batch count once) and
  one-shot per batch id: a batch that failed and later re-runs all its
  vectors under a second header is still flagged — deliberate until
  upstream ships a distinguishable retry marker (terminal-bench-2#89).
  The binding is forward-persistent: a failure line after the final
  batch's output still names the last header seen (no per-vector
  result stream exists to end a batch's region; pinned deliberately).
- S2 ``RetryStorm`` — urllib3 ``Retrying (...)`` / ``ConnectionResetError``
  churn. At/above ``RETRY_STORM_THRESHOLD`` alone it downgrades the
  verdict to ``suspect`` (annotation only, never a score change); the
  threshold is calibrated above the clean siblings' handful of retries.
- S3 ``SuccessClaim`` — a ``✓ ... blocked all N ...`` summary line
  captured verbatim (length-capped). Only a signal when S1 fired in the
  same stdout (E6): the claim contradicts the failed loads — the lie
  marker. A lone success line is the normal clean case.

Statuses:

- ``ok``          — no S1, S2 below threshold; the verdict stands.
- ``suspect``     — S2 alone at/above threshold; annotated, score stands.
- ``compromised`` — S1 fired; the verdict is untrusted (I1: a trial in
  this state can never count as resolved).
- ``unreadable``  — stdout absent/blank/undecodable (I2: absence of
  evidence is reported, never assumed clean; a pass may still score, but
  the report flags that the gate could not inspect it).

The detector matches patterns, not task names (I3): the same failure mode
in any browser/HTTP-driven verifier of any family is caught. Patterns are
bounded literal+simple-regex matches over a line stream — no nested
quantifiers, no backreferences — so stdout parses in linear time (UT-4
pins the property on a 10 MB adversarial blob with a scaled assertion;
the bound is the linearity, not the absolute size).

Upstream escalation (the task-side fix, fail-or-retry instead of a
silent skip): harbor-framework/terminal-bench-2#89.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

OK = "ok"
SUSPECT = "suspect"
COMPROMISED = "compromised"
UNREADABLE = "unreadable"

# E3: retry/connection churn below this many events leaves the verdict
# ok — the clean sibling trials log a handful of retries and must stay
# quiet; the incident run logged 84. Named constant, pinned by UT-3.
RETRY_STORM_THRESHOLD = 20

# Captured log text is length-capped before it enters any verdict/report.
_MAX_CLAIM_CHARS = 200

_BATCH_HEADER_RE = re.compile(r"RUN BATCH (\d+) \(contains (\d+) tests\)")
# E8: bound to the full driver-failure shape, never the bare "Failed to
# load URL" substring (a task about error pages must not trip the gate).
_FAILED_LOAD_RE = re.compile(
    r"Failed to load URL: HTTPConnectionPool\([^)]*\): "
    r"(?:Read timed out|Connection refused|ConnectionResetError)"
)
_RETRY_RE = re.compile(r"Retrying \(")
_RESET_RE = re.compile(r"ConnectionResetError")
_CLAIM_RE = re.compile(r"✓.*\bblocked all (\d+)\b")


@dataclass(frozen=True)
class FailedLoad:
    """S1: a page the verifier failed to load — its tests never ran.

    One-shot per batch id, by design: once a batch id is in
    ``seen_batches`` nothing can un-signal it. If upstream adopts the
    retry variant of the fail-or-retry patch (AC9,
    harbor-framework/terminal-bench-2#89), a batch that failed to load
    and then re-ran successfully under a second ``RUN BATCH N`` header
    is STILL flagged — until upstream emits a distinguishable retry
    marker, a recovering re-run is indistinguishable from the incident's
    silent skip, and the gate fails closed (a false COMPROMISED
    quarantines one honest trial; a false ok re-admits a lying verdict).
    Pinned by
    BatchBindingTest.test_batch_reheadered_after_failure_still_compromised."""

    batch: int | None  # None = seen before any RUN BATCH header (E1)
    n_tests: int | None


@dataclass(frozen=True)
class RetryStorm:
    """S2: urllib3 retry/connection churn (annotation-grade on its own)."""

    count: int


@dataclass(frozen=True)
class SuccessClaim:
    """S3: the success claim line, verbatim (length-capped) — a lie marker
    only when a FailedLoad fired in the same stdout (E6)."""

    claim: str
    total_tests: int | None


Signal = FailedLoad | RetryStorm | SuccessClaim


@dataclass(frozen=True)
class IntegrityVerdict:
    """The structured trust verdict for one verifier stdout."""

    status: str  # OK | SUSPECT | COMPROMISED | UNREADABLE
    signals: tuple[Signal, ...]
    skipped_tests: int | None  # batch-bound skips; None when no S1 fired
    total_tests: int | None = None  # claimed/header-declared vector total

    def describe(self) -> str:
        """Report-grade detail: batches + skip counts only — never raw log
        text (report lines quote metadata, not blobs)."""
        loads = [s for s in self.signals if isinstance(s, FailedLoad)]
        batches = [
            "unknown" if s.batch is None else str(s.batch) for s in loads
        ]
        batch_part = f"batches {','.join(batches)} skipped"
        skips = self.skipped_tests or 0
        if skips and self.total_tests:
            skip_part = f"{skips}/{self.total_tests} vectors never ran"
        elif skips:
            skip_part = f"{skips} vectors never ran"
        else:
            # Unknown-bindings contribute 0 (E1): no attributable skips.
            skip_part = "skipped-test count unknown"
        return f"{batch_part} — {skip_part}"


def classify(stdout_text: str | None) -> IntegrityVerdict:
    """Classify one verifier's stdout (pure; None = absent/undecodable)."""
    if stdout_text is None or "\x00" in stdout_text or not stdout_text.strip():
        # I2, fail-closed: absent, blank, or binary garbage is unreadable —
        # never silently ok on a pass.
        return IntegrityVerdict(UNREADABLE, (), None, None)

    loads: list[FailedLoad] = []
    seen_batches: set[int] = set()
    has_unknown = False  # one E1 signal no matter how many prologue hiccups
    current: tuple[int, int] | None = None  # (batch id, n tests)
    retry_count = 0
    claim: SuccessClaim | None = None
    header_total = 0

    for line in stdout_text.splitlines():
        header = _BATCH_HEADER_RE.search(line)
        if header:
            current = (int(header.group(1)), int(header.group(2)))
            header_total += current[1]
            continue
        # `current` deliberately persists until the next header: real
        # verifier stdout emits no one-line-per-vector stream to count a
        # batch as consumed, so a trailing failure line binds to the
        # last header seen (pinned by BatchBindingTest
        # .test_trailing_failure_line_after_last_batch_binds_to_it).
        if _FAILED_LOAD_RE.search(line):
            if current is None:
                # E1: outside any batch — kept, but never misattributed,
                # and deduped like batch-bound signals so the report
                # line stays stable across a flapping prologue.
                if not has_unknown:
                    loads.append(FailedLoad(None, None))
                    has_unknown = True
            elif current[0] not in seen_batches:
                loads.append(FailedLoad(current[0], current[1]))
                seen_batches.add(current[0])
            continue
        if _RETRY_RE.search(line) or _RESET_RE.search(line):
            retry_count += 1
            continue
        if claim is None:
            match = _CLAIM_RE.search(line)
            if match:
                claim = SuccessClaim(
                    line.strip()[:_MAX_CLAIM_CHARS], int(match.group(1))
                )

    signals: list[Signal] = list(loads)
    skipped_tests: int | None = None
    total_tests: int | None = None
    if loads:
        skipped_tests = sum(s.n_tests or 0 for s in loads if s.batch is not None)
        total_tests = claim.total_tests if claim else (header_total or None)
        if claim is not None:
            signals.append(claim)  # S3 requires S1 (E6)
    elif claim is not None:
        total_tests = claim.total_tests
    if retry_count >= RETRY_STORM_THRESHOLD:
        signals.append(RetryStorm(retry_count))

    if loads:
        status = COMPROMISED
    elif retry_count >= RETRY_STORM_THRESHOLD:
        status = SUSPECT
    else:
        status = OK
    return IntegrityVerdict(status, tuple(signals), skipped_tests, total_tests)


def read_stdout(trial_dir: Path) -> tuple[str | None, str]:
    """Read ``<trial>/verifier/test-stdout.txt`` → (text, reason).

    text is None unless the file exists, decodes as UTF-8, and is
    non-blank; reason is one of ``missing`` | ``io-error`` |
    ``undecodable`` | ``empty`` | ``ok`` — an ``OSError`` on read is
    ``io-error`` (a filesystem/permissions problem, not a decoding one)
    so the report routes the post-mortem correctly. The caller treats
    None as UNREADABLE (I2) — never as clean.
    """
    path = Path(trial_dir) / "verifier" / "test-stdout.txt"
    try:
        raw = path.read_bytes()
    except (FileNotFoundError, NotADirectoryError):
        return None, "missing"
    except OSError:
        return None, "io-error"
    try:
        text = raw.decode("utf-8")
    except (UnicodeDecodeError, ValueError):
        return None, "undecodable"
    if not text.strip():
        return None, "empty"
    return text, "ok"
