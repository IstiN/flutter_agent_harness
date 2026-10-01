"""Shared bench agent-timeout policy (issue #1122).

The bench cap stops being a flat guillotine: the base cap is configurable
per run and, when extension is enabled, the kill deadline recedes while
the agent provably makes progress — growth of its rendered output (deltas,
tool calls, tool results). A silent agent dies at the base cap exactly as
before; an agent that never stops producing dies only at a hard ceiling.

bench/terminal_bench/fa_agent.py and bench/harbor_fa/fa_agent.py both
import this module so legacy and 4.0 measurement policy cannot drift.

Environment knobs (all optional; empty string counts as absent, so a
default workflow run keeps today's byte-for-byte behavior):
  FA_AGENT_TIMEOUT_SEC         base cap seconds (default 360)
  FA_PROGRESS_EXTENSION        1/true/yes/on to enable progress-aware extension
  FA_AGENT_IDLE_WINDOW_SEC     silence span that constitutes a stall (default 120)
  FA_AGENT_CEILING_MULTIPLIER  hard ceiling = base * this (default 4)

Extension signal (E1): the counters fed to ProgressLadder measure the
agent process's own output bytes. The harness itself emits nothing into
that stream on a timer, so a pure keep-alive source does not exist here;
fa headless output is exactly deltas/tool activity.

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

_STALL = "stall"
_HARD_CEILING = "hard-ceiling"


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

    @property
    def ceiling_sec(self) -> float:
        return self.base_sec * self.ceiling_multiplier

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
            )
        ):
            return None
        return cls(
            base_sec=_number(env, "FA_AGENT_TIMEOUT_SEC", _BASE_DEFAULT),
            progress_extension=_flag(env, "FA_PROGRESS_EXTENSION"),
            idle_window_sec=_number(env, "FA_AGENT_IDLE_WINDOW_SEC", _IDLE_DEFAULT),
            ceiling_multiplier=_number(
                env, "FA_AGENT_CEILING_MULTIPLIER", _CEILING_DEFAULT
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


def audit_dict(knobs: TimeoutKnobs, ladder: ProgressLadder, outcome: str | None):
    """Trial-artifact audit record (what extended, when, why)."""
    return {
        "issue": 1122,
        "policy": "progress-aware" if knobs.progress_extension else "flat-cap",
        "outcome": outcome or "completed",
        "knobs": {
            "base_sec": knobs.base_sec,
            "progress_extension": knobs.progress_extension,
            "idle_window_sec": knobs.idle_window_sec,
            "ceiling_multiplier": knobs.ceiling_multiplier,
            "ceiling_sec": knobs.ceiling_sec,
        },
        "last_progress_sec": round(ladder.last_progress_at, 3),
        "last_output_bytes": ladder.last_bytes,
        "deadline_sec": round(ladder.kill_at, 3),
        "extensions": ladder.events,
    }
