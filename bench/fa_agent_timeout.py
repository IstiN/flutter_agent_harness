"""Shared bench agent-timeout policy (issue #1122).

The bench cap stops being a flat guillotine: the base cap is configurable
per run and, when extension is enabled, the kill deadline recedes while
the agent provably makes progress — growth of its rendered output (deltas,
tool calls, tool results). A silent agent dies at the base cap exactly as
before; an agent that never stops producing dies only at a hard ceiling.

bench/terminal_bench/fa_agent.py and bench/harbor_fa/fa_agent.py both
import this module so legacy and 4.0 measurement policy cannot drift.

Round 3 (issue #1392) — the artificial timeout class retires: the ×4
ceiling itself was the killer (play-zork worked productively for 72 min,
136 turns, and was still guillotined by the ladder cap). ProgressWatch,
the new kill decision in this module, replaces the byte-growth ceiling
with a GAP-aware one: a trial counts as progressing while
inter-assistant-record gaps stay under FA_STALL_GAP_SEC; a
progressing trial dies only at FA_AGENT_TIMEOUT_ABS_CEILING_SEC (default
3600s, flat — the agent phase does NOT consume the verifier's test
budget; tb enforces the test phase separately, and the adapter never
folds a test budget in). A gap >= the threshold marks the trial
stalled and the ladder resumes counting (last progress + idle window) —
a genuinely stuck agent still dies, and a class-C catastrophic stall now
dies at the gap boundary instead of burning the whole ladder.

Round 4 (gh-1430) — the stall-gap default couples to fa's OWN stream
watchdog: the shipped gap is now 360s (fa's providerStreamIdleTimeout,
300s, + a 60s poll-jitter margin), and the ordering invariant is part of
this module's contract:

    fa's watchdog is the sole arbiter of stream death; the bench gap
    only catches pane/process death.

A healthy reasoning stream can sit minutes between rendered bytes (the
first event of a reasoning model is a thinking delta, which headless fa
does not render) — fa's own in-band liveness (`… reasoning Ns
(streaming)` heartbeats, gh-1430) keeps the pane growing while events
flow, and fa's stream-idle watchdog errors a truly dead stream at 300s,
BEFORE this module's 360s gap could fire. The bench must never SIGKILL a
stream fa itself considers live, so the gap default may never drop to or
below the watchdog (the shipped REG in test_fa_agent_timeout.py pins
this against the Dart source and fails if either side drifts). Round-2
healthy max gap was ~200s; the pre-gh-1430 default (240s) was the
round-4 killer (13 tasks ≈ 16% killed mid-thinking, stopReason
"aborted", zero provider errors).

The legacy ProgressLadder stays untouched for runs that do not set the
new knobs: with FA_STALL_GAP_SEC / FA_AGENT_TIMEOUT_ABS_CEILING_SEC both
absent, TimeoutKnobs.progress_watch is False and callers keep the
byte-for-byte round-2 behavior (REG).

Environment knobs (all optional; empty string counts as absent, so a
default workflow run keeps today's byte-for-byte behavior):
  FA_AGENT_TIMEOUT_SEC         base cap seconds (default 360)
  FA_PROGRESS_EXTENSION        1/true/yes/on to enable progress-aware extension
  FA_AGENT_IDLE_WINDOW_SEC     silence span that constitutes a stall (default 120)
  FA_AGENT_CEILING_MULTIPLIER  hard ceiling = base * this (default 4)
  FA_STALL_GAP_SEC             progress-watch: inter-record gap that marks a
                               stall (default 360 in watch mode — gh-1430:
                               fa's 300s stream-idle watchdog + 60s margin)
  FA_AGENT_TIMEOUT_ABS_CEILING_SEC  progress-watch: absolute kill ceiling the
                               extension can never pass (default 3600, flat;
                               the ADAPTER does not fold a test budget in)

Extension signal (E1): the counters fed to ProgressLadder measure the
agent process's own output bytes. The harness itself emits nothing into
that stream on a timer — EXCEPT fa's own liveness lines (the ⏳ tool
liveness family and, since gh-1430, the `… reasoning Ns (streaming)`
heartbeat), which are fa's designed in-band liveness signal and are
documented, not subtracted (see audit_dict / liveness_bytes_of).

All times are SECONDS ELAPSED since the agent phase started — no clocks
live in this module, so the ladder is deterministic and unit-testable.
"""

from __future__ import annotations

import math
import os
from dataclasses import dataclass, field

_BASE_DEFAULT = 360.0
_IDLE_DEFAULT = 120.0
_CEILING_DEFAULT = 4.0
# gh-1430: fa's stream-idle watchdog (providerStreamIdleTimeout, 300s in
# lib/src/providers/provider_common.dart) + a 60s margin for poll jitter
# and one missed tick. MUST stay above the watchdog — the REG in
# test_fa_agent_timeout.py reads the Dart source and enforces it.
_STALL_GAP_DEFAULT = 360.0
_ABS_CEILING_DEFAULT = 3600.0

_STALL = "stall"
_HARD_CEILING = "hard-ceiling"
_ABS_CEILING = "abs_ceiling"


def _optional(env, name):
    value = env.get(name)
    if value is None or value.strip() == "":
        return None
    return value.strip()


def _number(env, name, default):
    raw = _optional(env, name)
    if raw is None:
        return default
    try:
        value = float(raw)
    except ValueError:
        raise ValueError(
            f"{name} must be a number of seconds, got: {raw!r}"
        ) from None
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f"{name} must be a finite positive number, got: {raw!r}")
    return value


_FLAG_TRUE = ("1", "true", "yes", "on")
_FLAG_FALSE = ("0", "false", "no", "off")


def _flag(env, name, default=False):
    raw = _optional(env, name)
    if raw is None:
        return default
    value = raw.lower()
    if value in _FLAG_TRUE:
        return True
    if value in _FLAG_FALSE:
        return False
    # A mistyped flag must never silently disable the extension (a silent
    # mis-parse costs a multi-hour run) - fail loud, same as _number().
    raise ValueError(f"{name} must be boolean (true/false), got: {raw!r}")


@dataclass(frozen=True)
class TimeoutKnobs:
    """Resolved knob values; from_env returns None when no knob is set."""

    base_sec: float = _BASE_DEFAULT
    progress_extension: bool = False
    idle_window_sec: float = _IDLE_DEFAULT
    ceiling_multiplier: float = _CEILING_DEFAULT
    stall_gap_sec: float | None = None
    abs_ceiling_sec: float | None = None

    @property
    def ceiling_sec(self) -> float:
        return self.base_sec * self.ceiling_multiplier

    @property
    def progress_watch(self) -> bool:
        """Round-3 gap-aware kill decision (issue #1392) is active."""
        return self.stall_gap_sec is not None or self.abs_ceiling_sec is not None

    @property
    def watch_stall_gap_sec(self) -> float:
        """Effective stall-gap threshold.

        gh-1430: default 360s in watch mode — fa's stream-idle watchdog
        (300s) + a 60s margin. The ordering invariant lives in this
        module's docstring: fa's watchdog is the sole arbiter of stream
        death; the bench gap only catches pane/process death.
        """
        if self.stall_gap_sec is not None:
            return self.stall_gap_sec
        return _STALL_GAP_DEFAULT

    @property
    def watch_abs_ceiling_sec(self) -> float:
        """Effective absolute ceiling (default 3600s in watch mode)."""
        if self.abs_ceiling_sec is not None:
            return self.abs_ceiling_sec
        return _ABS_CEILING_DEFAULT

    @classmethod
    def from_env(cls, env=None) -> "TimeoutKnobs | None":
        env = os.environ if env is None else env
        if not any(
            _optional(env, name) is not None
            for name in (
                "FA_AGENT_TIMEOUT_SEC",
                "FA_PROGRESS_EXTENSION",
                "FA_AGENT_IDLE_WINDOW_SEC",
                "FA_AGENT_CEILING_MULTIPLIER",
                "FA_STALL_GAP_SEC",
                "FA_AGENT_TIMEOUT_ABS_CEILING_SEC",
            )
        ):
            return None
        stall_gap = _optional(env, "FA_STALL_GAP_SEC")
        abs_ceiling = _optional(env, "FA_AGENT_TIMEOUT_ABS_CEILING_SEC")
        return cls(
            base_sec=_number(env, "FA_AGENT_TIMEOUT_SEC", _BASE_DEFAULT),
            progress_extension=_flag(env, "FA_PROGRESS_EXTENSION"),
            idle_window_sec=_number(env, "FA_AGENT_IDLE_WINDOW_SEC", _IDLE_DEFAULT),
            ceiling_multiplier=_number(
                env, "FA_AGENT_CEILING_MULTIPLIER", _CEILING_DEFAULT
            ),
            stall_gap_sec=None if stall_gap is None else _number(env, "FA_STALL_GAP_SEC", 0.0),
            abs_ceiling_sec=(
                None
                if abs_ceiling is None
                else _number(env, "FA_AGENT_TIMEOUT_ABS_CEILING_SEC", 0.0)
            ),
        )


@dataclass
class ProgressLadder:
    """Kill-decision state machine over (elapsed, output-bytes) samples.

    Deadline = max(base, last_progress + idle_window), capped at the hard
    ceiling. With extension disabled the deadline is the flat base cap —
    the regression pin: a silent agent dies at the base cap exactly as
    today. Every progress-driven deadline push is recorded in `events`
    for the run-metadata audit trail.
    """

    knobs: TimeoutKnobs
    last_progress_at: float = 0.0
    last_bytes: int = 0
    kill_at: float = 0.0
    events: list = field(default_factory=list)

    def __post_init__(self):
        # The standing deadline starts at the base cap — the regression pin:
        # a fully silent agent dies exactly at today's flat cap, even when
        # the idle window is larger than the base.
        self.kill_at = self.knobs.base_sec

    def _deadline_from(self, progress_elapsed: float) -> float:
        if not self.knobs.progress_extension:
            return self.knobs.base_sec
        target = max(
            self.knobs.base_sec, progress_elapsed + self.knobs.idle_window_sec
        )
        return min(target, self.knobs.ceiling_sec)

    def evaluate(self, elapsed: float, output_bytes: int | None = None):
        """Feed one sample; None = keep going, else 'stall' | 'hard-ceiling'.

        output_bytes None means the sample could not be read this poll —
        the ladder keeps its previous notion of progress.
        """
        if output_bytes is not None and output_bytes > self.last_bytes:
            self.last_bytes = output_bytes
            if elapsed > self.last_progress_at:
                new_deadline = self._deadline_from(elapsed)
                if new_deadline > self.kill_at:
                    self.events.append(
                        {
                            "at_sec": round(elapsed, 3),
                            "output_bytes": self.last_bytes,
                            "deadline_sec": round(new_deadline, 3),
                        }
                    )
                    self.kill_at = new_deadline
            self.last_progress_at = elapsed
        if elapsed < self.kill_at:
            return None
        if self.kill_at >= self.knobs.ceiling_sec and self.ceiling_is_extension():
            return _HARD_CEILING
        return _STALL

    def ceiling_is_extension(self) -> bool:
        return self.knobs.ceiling_sec > self.knobs.base_sec


@dataclass
class ProgressWatch:
    """Round-3 gap-aware kill decision (issue #1392 AC1).

    Push-driven like ProgressLadder — the caller feeds (elapsed, bytes)
    samples; no clocks live here, so it stays deterministic and
    unit-testable with a fake clock. Kill contract:

    - bytes growing and inter-sample gap < stall-gap: the trial is
      PROGRESSING — the only kill is the absolute ceiling
      watch_abs_ceiling_sec (+ test_budget_sec — a DECISION-OBJECT knob
      only: the bench adapter leaves it 0.0 because tb enforces the
      verifier phase separately; the shipped ceiling is flat 3600s). The
      legacy ×4 ceiling no
      longer guillotines productive runs.
    - a sample whose gap (elapsed - last progress) >= stall-gap marks the
      trial STALLED (sticky): the ladder resumes counting and the kill
      lands at max(detection moment, last progress + idle window). With
      the default stall-gap (360s, gh-1430) above the idle window (120s)
      that is the gap boundary itself — a class-C catastrophic stall dies
      the moment it is provable instead of burning the whole ladder.
    - new output bytes after a stall detection re-freeze the ladder
      (hysteresis, E1): the verdict cannot flap while the agent resumes.
    - extension disabled: flat base cap, the legacy regression pin.
    """

    knobs: TimeoutKnobs
    test_budget_sec: float = 0.0
    last_progress_at: float = 0.0
    last_bytes: int = 0
    kill_at: float = 0.0
    stalled: bool = False
    events: list = field(default_factory=list)

    def __post_init__(self):
        # Progressing (extension on) starts against the absolute ceiling;
        # extension off is the legacy flat base cap — the regression pin.
        self.kill_at = (
            self._abs_deadline if self.knobs.progress_extension else self.knobs.base_sec
        )

    @property
    def _abs_deadline(self) -> float:
        return self.knobs.watch_abs_ceiling_sec + self.test_budget_sec

    def evaluate(self, elapsed: float, output_bytes: int | None = None):
        """Feed one sample; None = keep going, else 'stall' | 'abs_ceiling'.

        output_bytes None means the sample could not be read this poll —
        the watch keeps its previous notion of progress.
        """
        progressed = output_bytes is not None and output_bytes > self.last_bytes
        if progressed:
            self.last_bytes = output_bytes
            if self.stalled:
                self.stalled = False
                self.events.append(
                    {
                        "kind": "progress_resumed",
                        "at_sec": round(elapsed, 3),
                        "output_bytes": self.last_bytes,
                    }
                )
            self.last_progress_at = elapsed
        if not self.knobs.progress_extension:
            return None if elapsed < self.knobs.base_sec else _STALL
        gap = elapsed - self.last_progress_at
        if not self.stalled and gap >= self.knobs.watch_stall_gap_sec:
            # A gap at/over the threshold is the stall proof; the verdict
            # lands on the same sample (the deadline below is <= elapsed).
            self._mark_stalled(elapsed, gap)
        if self.stalled:
            # Ladder counting resumed: the deadline was pinned at detection
            # (max(detection moment, last progress + idle window)), so a
            # stall_gap under the idle window still waits the window out.
            return None if elapsed < self.kill_at else _STALL
        if elapsed >= self._abs_deadline:
            return _ABS_CEILING
        return None

    def _mark_stalled(self, elapsed: float, gap: float) -> None:
        self.stalled = True
        deadline = max(elapsed, self.last_progress_at + self.knobs.idle_window_sec)
        self.events.append(
            {
                "kind": "stall_detected",
                "at_sec": round(elapsed, 3),
                "gap_sec": round(gap, 3),
                "last_progress_sec": round(self.last_progress_at, 3),
                "deadline_sec": round(deadline, 3),
            }
        )
        self.kill_at = deadline


def audit_dict(
    knobs: TimeoutKnobs,
    ladder: ProgressLadder,
    outcome: str | None,
    progress_bytes: int | None = None,
    liveness_bytes: int | None = None,
):
    """Trial-artifact audit record (what extended, when, why).

    Issue #1185 AC6: when the caller can read the progress stream, it also
    passes the final sample size (`progress_bytes`) and the bytes inside it
    that are fa's OWN `⏳` liveness lines (`liveness_bytes`,
    [liveness_bytes_of]) — harness-originated prints the pane counter
    counts as progress. Documented, not subtracted: the model legitimately
    reads its own logs, so separating the two streams perfectly is not
    attempted; the audit makes the inflation visible per trial.
    """
    record = {
        "issue": 1122,
        "policy": (
            "progress-watch"
            if getattr(knobs, "progress_watch", False)
            else ("progress-aware" if knobs.progress_extension else "flat-cap")
        ),
        "outcome": outcome or "completed",
        "knobs": {
            "base_sec": knobs.base_sec,
            "progress_extension": knobs.progress_extension,
            "idle_window_sec": knobs.idle_window_sec,
            "ceiling_multiplier": knobs.ceiling_multiplier,
            "ceiling_sec": knobs.ceiling_sec,
            # Round-3 (issue #1392): effective watch knobs render in the
            # audit only when the gap-aware decision is active.
            **(
                {
                    "stall_gap_sec": knobs.watch_stall_gap_sec,
                    "abs_ceiling_sec": knobs.watch_abs_ceiling_sec,
                }
                if getattr(knobs, "progress_watch", False)
                else {}
            ),
        },
        "last_progress_sec": round(ladder.last_progress_at, 3),
        "last_output_bytes": ladder.last_bytes,
        "deadline_sec": round(ladder.kill_at, 3),
        "extensions": ladder.events,
    }
    if progress_bytes is not None:
        record["progress_sample_bytes"] = progress_bytes
    if liveness_bytes is not None:
        record["progress_liveness_bytes"] = liveness_bytes
        record["progress_note"] = (
            "progress_liveness_bytes = the agent's own liveness status "
            "lines inside the progress sample (issue #1185 AC6): "
            "harness-originated bytes the pane counter counts as progress"
        )
    return record


# The liveness status line's grep anchor (gh-1055): every harness-originated
# reminder/escalation line carries it; nothing else the agent emits does.
_LIVENESS_ANCHOR = "⏳"


def liveness_bytes_of(stream: str | bytes | None) -> int | None:
    """Bytes of `⏳` liveness lines inside a progress stream (AC6 helper).

    None propagates: an unreadable stream must not fabricate a zero (the
    audit then just omits the field).

    Byte accounting splits on `'\\n'` only (reproducible against `wc -c`):
    a matched line counts its full bytes — a `\\r` stays in the line — plus
    exactly the one newline it ends with, and a final unterminated line
    counts without the newline. `str.splitlines()` would also split on
    `\\r`, `\\v`, `\\x85`, … and silently miscount against the byte total.
    """
    if stream is None:
        return None
    if isinstance(stream, bytes):
        stream = stream.decode("utf-8", errors="replace")
    total = 0
    lines = stream.split("\n")
    for index, line in enumerate(lines):
        if _LIVENESS_ANCHOR in line:
            total += len(line.encode("utf-8"))
            if index < len(lines) - 1:
                total += 1  # the newline this line ends with
    return total
