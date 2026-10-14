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

gh-1556 AC7: when any knob above arms an adapter-side cap, the adapters
also export FA_DEADLINE_EPOCH_MS = now + (effective cap - 120s wrap-up
margin) into the agent session, so fa's own deadline awareness can steer
wrap-up before the kill. With no knobs the export is absent — fa never
invents a clock (see deadline_epoch_ms / deadline_env_from).

Round 5 (gh-1576) — cap resolution: the deadline becomes TRUTHFUL when an
external harness caps the trial below fa's own knobs. The incident
(TB 2.1, run 38271607849): harbor hard-killed four extract-moves-from-video
trials at the dataset-declared 1800s while fa planned against the adapter's
3600s abs ceiling — the T-3min wrap-up steer was armed at minute 57 and
never fired, and the audit writer never ran because the kill came from
outside. The fix is a protocol, not a knob: the workflow resolves each
shard task's declared agent timeout (task.toml `[agent] timeout_sec`)
BEFORE launch and exports it as

  FA_EXTERNAL_CAP_SEC          external harness cap seconds (empty/absent
                               = unknown — knobs rule alone, byte-for-byte
                               today; malformed/<= 0/absurd values are
                               rejected with a warning, knobs-only fallback)

and every deadline computation composes effective_cap = min(external,
knob) with the winning source recorded in the audit. Invariant I1: fa
NEVER sees a deadline later than any known external cap. Invariant I2:
every trial termination leaves the audit (the adapters add incremental
checkpoints plus a SIGTERM/SIGINT and cancellation flush so an external
kill still lands a final record with outcome external_kill; the adapter's
own kill AT the external cap is outcome external_cap). The ProgressWatch /
ProgressLadder kill deadlines clamp to the external cap the same way, so
the adapter — not harbor's blind wait_for — decides and audits the kill
whenever it can. SIGKILL still leaves nothing in-container (non-goal);
the incremental checkpoints are the best-effort residue.

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
import time
import warnings
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


# ── Cap resolution (gh-1576) ─────────────────────────────────────────────
# The external harness cap (harbor's per-task `[agent] timeout_sec`, tb's
# harness cap) resolved by the workflow BEFORE launch and exported as
# FA_EXTERNAL_CAP_SEC. Unlike the knob knobs (fail-loud: a mistyped knob
# costs a whole shard) a malformed cap DEGRADES: knobs-only fallback with
# a warning — the run must never crash inside a trial over harness
# metadata, and it must never arm a clock off garbage either.
EXTERNAL_CAP_ENV = "FA_EXTERNAL_CAP_SEC"

# Anything above this is rejected as absurd rather than trusted: the
# exported deadline is now_ms + cap*1000 and must stay inside an int64
# (Dart int) with room to spare. Real harness caps are minutes-to-hours;
# 1e12 seconds (~31,700 years) is unreachably far above any of them.
_EXTERNAL_CAP_MAX_SEC = 1e12

EXTERNAL_KNOWN = "known"
EXTERNAL_UNKNOWN = "unknown"
EXTERNAL_REJECTED = "rejected"

# The verdict name for the audit's outcome field when the external cap
# is what binds the kill deadline (the knob-clock verdicts keep theirs).
_EXTERNAL_CAP = "external_cap"


def external_cap_from_env(env=None, quiet: bool = False):
    """(cap_sec | None, status) for FA_EXTERNAL_CAP_SEC — never raises.

    status: EXTERNAL_KNOWN (a finite, positive, sane number) |
    EXTERNAL_UNKNOWN (absent or blank — no cap was exported) |
    EXTERNAL_REJECTED (malformed / <= 0 / non-finite / absurdly large:
    ignored with a warning, knobs-only fallback — AC8). quiet=True
    suppresses the warning for callers that log it themselves.
    """
    raw = _optional(env if env is not None else os.environ, EXTERNAL_CAP_ENV)
    if raw is None:
        return None, EXTERNAL_UNKNOWN
    try:
        value = float(raw)
    except ValueError:
        return _reject(raw, quiet)
    if not math.isfinite(value) or value <= 0 or value > _EXTERNAL_CAP_MAX_SEC:
        return _reject(raw, quiet)
    return value, EXTERNAL_KNOWN


def _reject(raw: str, quiet: bool):
    if not quiet:
        warnings.warn(
            f"{EXTERNAL_CAP_ENV}={raw!r} is not a usable cap (need a finite "
            f"positive number of seconds <= {_EXTERNAL_CAP_MAX_SEC:g}); "
            "ignoring it — the effective cap falls back to the adapter "
            "knobs alone (gh-1576 AC8)",
            UserWarning,
            stacklevel=3,
        )
    return None, EXTERNAL_REJECTED


@dataclass(frozen=True)
class CapResolution:
    """The min() of every known cap input, with the winner recorded (I1).

    knob_cap_sec is None when no adapter knob is set (the adapter's own
    cap is unknown); external_cap_sec is None when the external cap is
    unknown or rejected (status says which). At least one input is known
    whenever a CapResolution exists — resolve_cap returns None when
    NOTHING is known, the byte-identical no-clock contract.
    """

    external_cap_status: str
    effective_cap_sec: float
    winning_cap_source: str
    knob_cap_sec: float | None = None
    external_cap_sec: float | None = None
    # E7: the wrap-up margin does not fit under the cap — the deadline
    # clamps instead of lying (or going negative). Recorded, not silent.
    deadline_clamped: bool = False

    def audit_fields(self, deadline_epoch_ms: int | None = None) -> dict:
        """The audit's cap_resolution block (AC2: source + both inputs)."""
        fields = {
            "external_cap_status": self.external_cap_status,
            "effective_cap_sec": self.effective_cap_sec,
            "winning_cap_source": self.winning_cap_source,
            "deadline_clamped": self.deadline_clamped,
        }
        if self.external_cap_sec is not None:
            fields["external_cap_sec"] = self.external_cap_sec
        if self.knob_cap_sec is not None:
            fields["knob_cap_sec"] = self.knob_cap_sec
        if deadline_epoch_ms is not None:
            fields["deadline_epoch_ms"] = deadline_epoch_ms
        return fields


def resolve_cap(
    knobs: "TimeoutKnobs | None",
    env=None,
    test_budget_sec: float = 0.0,
    quiet: bool = False,
) -> "CapResolution | None":
    """Compose every known cap input: effective = min(external, knobs).

    Returns None only when NO input is known — no knobs and no usable
    external cap — the pre-gh-1576 no-clock contract byte-for-byte
    (AC5/REG-2). The winning source is `external` on ties (E5): the
    harness is the stricter truth.
    """
    external, status = external_cap_from_env(env, quiet=quiet)
    knob_cap = (
        effective_cap_sec(knobs, test_budget_sec) if knobs is not None else None
    )
    if knob_cap is None and external is None:
        return None
    if external is None:
        effective, source = knob_cap, "knobs"
    elif knob_cap is None:
        effective, source = external, "external"
    else:
        effective = min(external, knob_cap)
        source = "external" if external <= knob_cap else "knobs"
    return CapResolution(
        external_cap_status=status,
        effective_cap_sec=effective,
        winning_cap_source=source,
        knob_cap_sec=knob_cap,
        external_cap_sec=external,
        # E7: the shipped wrap-up margin cannot fit under this cap — the
        # deadline will clamp to the cap itself (recorded in the audit).
        deadline_clamped=effective - _DEADLINE_MARGIN_SEC <= 0,
    )


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

    gh-1576: external_cap_sec (a known external harness cap) clamps every
    deadline — the trial can never be killed later than the harness would
    (I1); when the external bound is what binds (<= the knob deadline,
    ties included) the verdict names it external_cap so the audit says
    which clock fired. None (default) is byte-identical legacy behavior.
    """

    knobs: TimeoutKnobs
    last_progress_at: float = 0.0
    last_bytes: int = 0
    kill_at: float = 0.0
    events: list = field(default_factory=list)
    external_cap_sec: float | None = None

    def __post_init__(self):
        # The standing deadline starts at the base cap — the regression pin:
        # a fully silent agent dies exactly at today's flat cap, even when
        # the idle window is larger than the base.
        self._knob_kill_at = self.knobs.base_sec
        self.kill_at = self._capped(self._knob_kill_at)

    def _capped(self, deadline: float) -> float:
        if self.external_cap_sec is None:
            return deadline
        return min(deadline, self.external_cap_sec)

    def _external_binds(self) -> bool:
        """The external cap (ties included, E5) is the binding deadline."""
        return (
            self.external_cap_sec is not None
            and self.external_cap_sec <= self._knob_kill_at
        )

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
        the ladder keeps its previous notion of progress. gh-1576: a
        binding external cap yields 'external_cap' instead.
        """
        if output_bytes is not None and output_bytes > self.last_bytes:
            self.last_bytes = output_bytes
            if elapsed > self.last_progress_at:
                new_deadline = self._deadline_from(elapsed)
                if new_deadline > self._knob_kill_at:
                    self.events.append(
                        {
                            "at_sec": round(elapsed, 3),
                            "output_bytes": self.last_bytes,
                            "deadline_sec": round(self._capped(new_deadline), 3),
                        }
                    )
                    self._knob_kill_at = new_deadline
                    self.kill_at = self._capped(new_deadline)
            self.last_progress_at = elapsed
        if elapsed < self.kill_at:
            return None
        if self._external_binds():
            return _EXTERNAL_CAP
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

    gh-1576: external_cap_sec (a known external harness cap) clamps every
    kill deadline — a progressing trial dies at the harness guillotine
    (decided HERE, audited, instead of harbor's blind wait_for), and the
    verdict names external_cap whenever the external bound is what binds.
    None (default) is byte-identical legacy behavior.
    """

    knobs: TimeoutKnobs
    test_budget_sec: float = 0.0
    last_progress_at: float = 0.0
    last_bytes: int = 0
    kill_at: float = 0.0
    stalled: bool = False
    events: list = field(default_factory=list)
    external_cap_sec: float | None = None

    def __post_init__(self):
        # Progressing (extension on) starts against the absolute ceiling;
        # extension off is the legacy flat base cap — the regression pin.
        self._knob_kill_at = (
            self._abs_deadline if self.knobs.progress_extension else self.knobs.base_sec
        )
        self.kill_at = self._capped(self._knob_kill_at)

    def _capped(self, deadline: float) -> float:
        if self.external_cap_sec is None:
            return deadline
        return min(deadline, self.external_cap_sec)

    def _external_binds(self) -> bool:
        """The external cap (ties included, E5) is the binding deadline."""
        return (
            self.external_cap_sec is not None
            and self.external_cap_sec <= self._knob_kill_at
        )

    @property
    def _abs_deadline(self) -> float:
        return self.knobs.watch_abs_ceiling_sec + self.test_budget_sec

    def evaluate(self, elapsed: float, output_bytes: int | None = None):
        """Feed one sample; None = keep going, else 'stall' | 'abs_ceiling'.

        output_bytes None means the sample could not be read this poll —
        the watch keeps its previous notion of progress. gh-1576: a
        binding external cap yields 'external_cap' instead.
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
            if elapsed < self.kill_at:
                return None
            return _EXTERNAL_CAP if self._external_binds() else _STALL
        gap = elapsed - self.last_progress_at
        if not self.stalled and gap >= self.knobs.watch_stall_gap_sec:
            # A gap at/over the threshold is the stall proof; the verdict
            # lands on the same sample (the deadline below is <= elapsed).
            self._mark_stalled(elapsed, gap)
        if self.stalled:
            # Ladder counting resumed: the deadline was pinned at detection
            # (max(detection moment, last progress + idle window)), so a
            # stall_gap under the idle window still waits the window out.
            if elapsed < self.kill_at:
                return None
            return _EXTERNAL_CAP if self._external_binds() else _STALL
        # Progressing: the only kill is the absolute ceiling — CAPPED by a
        # known external harness cap (I1), never the stall-pinned kill_at
        # (a resumed trial re-freezes against the ceiling, not the old
        # pin — the byte-identical pre-gh-1576 branch tested _abs_deadline).
        if elapsed >= self._capped(self._abs_deadline):
            return _EXTERNAL_CAP if self._external_binds() else _ABS_CEILING
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
                "deadline_sec": round(self._capped(deadline), 3),
            }
        )
        self._knob_kill_at = deadline
        self.kill_at = self._capped(deadline)


def audit_dict(
    knobs: TimeoutKnobs,
    ladder: ProgressLadder,
    outcome: str | None,
    progress_bytes: int | None = None,
    liveness_bytes: int | None = None,
    deadline_epoch_ms: int | None = None,
    cap: "CapResolution | None" = None,
):
    """Trial-artifact audit record (what extended, when, why).

    Issue #1185 AC6: when the caller can read the progress stream, it also
    passes the final sample size (`progress_bytes`) and the bytes inside it
    that are fa's OWN liveness lines (`liveness_bytes`,
    [liveness_bytes_of] — both the ⏳ tool-liveness family and the
    `… reasoning` reasoning-liveness family, gh-1055/gh-1198/gh-1430) —
    harness-originated prints the pane counter
    counts as progress. Documented, not subtracted: the model legitimately
    reads its own logs, so separating the two streams perfectly is not
    attempted; the audit makes the inflation visible per trial.

    gh-1576: `cap` (a resolve_cap result) adds the cap_resolution block —
    the winning cap source and BOTH input values (AC2) — and omits the
    block entirely when no cap was resolved (byte-identical legacy audit).
    knobs=None (the external-cap-only unsupervised run) renders policy
    "external-cap" and drops the knobs block.
    """
    record = {
        "issue": 1122,
        "policy": (
            "external-cap"
            if knobs is None
            else (
                "progress-watch"
                if getattr(knobs, "progress_watch", False)
                else ("progress-aware" if knobs.progress_extension else "flat-cap")
            )
        ),
        "outcome": outcome or "completed",
        # gh-1556 AC7: the deadline exported to fa as FA_DEADLINE_EPOCH_MS
        # is audited next to the knobs it derives from, so a trial's
        # fa-timeout-metadata.json shows the clock fa actually saw.
        **(
            {"deadline_epoch_ms": deadline_epoch_ms}
            if deadline_epoch_ms is not None
            else {}
        ),
        # gh-1576: which clock won — the external harness cap or the
        # adapter knobs — and both inputs (AC2). Never any other env
        # value: the cap inputs are integers, the block is a fixed shape.
        **({"cap_resolution": cap.audit_fields(deadline_epoch_ms)} if cap else {}),
        **(
            {
                "knobs": {
                    "base_sec": knobs.base_sec,
                    "progress_extension": knobs.progress_extension,
                    "idle_window_sec": knobs.idle_window_sec,
                    "ceiling_multiplier": knobs.ceiling_multiplier,
                    "ceiling_sec": knobs.ceiling_sec,
                    # Round-3 (issue #1392): effective watch knobs render in
                    # the audit only when the gap-aware decision is active.
                    **(
                        {
                            "stall_gap_sec": knobs.watch_stall_gap_sec,
                            "abs_ceiling_sec": knobs.watch_abs_ceiling_sec,
                        }
                        if getattr(knobs, "progress_watch", False)
                        else {}
                    ),
                }
            }
            if knobs is not None
            else {}
        ),
        "last_progress_sec": round(getattr(ladder, "last_progress_at", 0.0), 3),
        "last_output_bytes": getattr(ladder, "last_bytes", 0),
        "deadline_sec": round(getattr(ladder, "kill_at", 0.0), 3),
        "extensions": getattr(ladder, "events", []) or [],
    }
    if progress_bytes is not None:
        record["progress_sample_bytes"] = progress_bytes
    if liveness_bytes is not None:
        record["progress_liveness_bytes"] = liveness_bytes
        record["progress_note"] = (
            "progress_liveness_bytes = the agent's own liveness status "
            "lines inside the progress sample (issue #1185 AC6): "
            "harness-originated bytes the pane counter counts as progress "
            "(the ⏳ tool-liveness family and the `… reasoning` "
            "reasoning-liveness family, gh-1055/gh-1198/gh-1430)"
        )
    return record


# The liveness status lines' grep anchors: every harness-originated
# liveness line carries one of these; nothing else the agent emits does.
# The ⏳ family is the gh-1055 tool-liveness lines; `… reasoning` is the
# gh-1198/gh-1430 reasoning family (the tier-2 line and its `(streaming)`
# heartbeat sibling).
_LIVENESS_ANCHORS = ("⏳", "… reasoning")


def _is_liveness_line(line: str) -> bool:
    return any(anchor in line for anchor in _LIVENESS_ANCHORS)


def liveness_bytes_of(stream: str | bytes | None) -> int | None:
    """Bytes of fa's liveness lines inside a progress stream (AC6 helper).

    Counts BOTH families: the `⏳` tool-liveness lines (gh-1055) and the
    `… reasoning` reasoning-liveness lines (gh-1198 tier 2 + the gh-1430
    `(streaming)` heartbeat) — the audit disclosure must cover every
    harness-originated byte class the pane counter credits as progress.

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
        if _is_liveness_line(line):
            total += len(line.encode("utf-8"))
            if index < len(lines) - 1:
                total += 1  # the newline this line ends with
    return total


# gh-1556 AC7 — fa-side deadline awareness. The adapters export
# FA_DEADLINE_EPOCH_MS into the agent session so fa can shift into
# wrap-up (land partial results, drain background jobs, run its checks)
# BEFORE the harness guillotine. Two binding rules from the ticket:
# - the deadline comes ONLY from the adapter's own effective kill cap
#   minus a wrap-up margin — never invented, never extended; with no
#   adapter cap (no knobs: harbor's dataset-declared task caps are
#   invisible to the adapter) fa's deadline awareness stays OFF;
# - the margin exists so the wrap-up turn completes before the kill —
#   a deadline at the cap itself would steer fa into its own SIGKILL.
_DEADLINE_MARGIN_SEC = 120.0
# A tiny configured cap must still leave fa a wrap-up window: the
# deadline is clamped to at least this much remaining time rather than
# landing in the past.
_DEADLINE_MIN_REMAINING_SEC = 30.0


def effective_cap_sec(knobs: TimeoutKnobs, test_budget_sec: float = 0.0) -> float:
    """The adapter's own kill cap — the only honest deadline source.

    Progress-watch mode: the flat abs ceiling (+ the caller's test
    budget where one is folded in, as tb does NOT — it leaves the
    verifier phase to the harness) — but ONLY while the extension is on;
    with the extension off ProgressWatch pins kill_at to the flat
    base_sec, so promising the abs ceiling would be a lie over the real
    guillotine (never lie about the clock). Legacy progress-aware
    ladder: the byte-growth hard ceiling. Flat ladder: the flat base
    cap.
    """
    if knobs.progress_watch:
        cap = (
            knobs.watch_abs_ceiling_sec
            if knobs.progress_extension
            else knobs.base_sec
        )
        return cap + test_budget_sec
    if knobs.progress_extension:
        return knobs.ceiling_sec
    return knobs.base_sec


def deadline_from_cap(
    cap: "CapResolution",
    now_ms: int,
    margin_sec: float = _DEADLINE_MARGIN_SEC,
) -> int:
    """Epoch-ms deadline from an already-resolved cap (gh-1576).

    The min() already happened in resolve_cap; this only projects it:
    deadline = now + max(effective - margin, min(remaining-floor, effective)).
    The floor is itself clamped to the cap (E7): a tiny cap yields
    deadline == start + cap (zero wrap-up margin) rather than a deadline
    PAST the kill — the clock never lies, and never goes negative.
    """
    effective = cap.effective_cap_sec
    floor = min(_DEADLINE_MIN_REMAINING_SEC, effective)
    remaining = max(effective - margin_sec, floor)
    return int(now_ms + remaining * 1000)


def deadline_epoch_ms(
    knobs: TimeoutKnobs | None,
    now_ms: int,
    test_budget_sec: float = 0.0,
    margin_sec: float = _DEADLINE_MARGIN_SEC,
    external_cap_sec: float | None = None,
) -> int | None:
    """Epoch-ms deadline for fa's FA_DEADLINE_EPOCH_MS, or None when off.

    now_ms is injected (not read from a wall clock) so the decision is
    deterministic and unit-testable. None propagates the "no adapter cap
    => feature off" contract — fa never sees a fabricated clock.

    gh-1576 (I1): external_cap_sec (when known) caps the projection —
    effective = min(knob cap, external) — so fa NEVER sees a deadline
    later than a known external harness kill.
    """
    knob_cap = (
        effective_cap_sec(knobs, test_budget_sec) if knobs is not None else None
    )
    if knob_cap is None and external_cap_sec is None:
        return None
    if knob_cap is None:
        effective = external_cap_sec
    elif external_cap_sec is None:
        effective = knob_cap
    else:
        effective = min(knob_cap, external_cap_sec)
    floor = min(_DEADLINE_MIN_REMAINING_SEC, effective)
    remaining = max(effective - margin_sec, floor)
    return int(now_ms + remaining * 1000)


def resolve_deadline(
    knobs: TimeoutKnobs | None,
    env=None,
    now_ms: int | None = None,
    test_budget_sec: float = 0.0,
):
    """One call for the adapters: (cap, deadline) from the resolved env.

    cap is the resolve_cap result (winning source + both inputs, for the
    audit); deadline the matching FA_DEADLINE_EPOCH_MS value. Both None
    when no cap input is known — the byte-identical no-clock contract.
    now_ms defaults to the wall clock (the adapters call this at launch).
    """
    cap = resolve_cap(knobs, env, test_budget_sec)
    if cap is None:
        return None, None
    if now_ms is None:
        now_ms = int(time.time() * 1000)
    return cap, deadline_from_cap(cap, now_ms)


def deadline_env_from(
    env=None,
    now_ms: int | None = None,
    test_budget_sec: float = 0.0,
) -> dict[str, str]:
    """`{"FA_DEADLINE_EPOCH_MS": ...}` for the agent session, or {}.

    env defaults to os.environ; now_ms defaults to the wall clock (the
    adapters call this at launch time). Empty when no timeout knob is
    set AND no external cap is known — fa never sees a fabricated clock
    (gh-1576: a known FA_EXTERNAL_CAP_SEC arms the deadline through the
    same min() even without adapter knobs; a rejected one never does).
    """
    cap = resolve_cap(TimeoutKnobs.from_env(env), env, test_budget_sec)
    if cap is None:
        return {}
    if now_ms is None:
        now_ms = int(time.time() * 1000)
    return {"FA_DEADLINE_EPOCH_MS": str(deadline_from_cap(cap, now_ms))}
