#!/usr/bin/env python3
"""Test-side timeout policy for the legacy terminal-bench bench (gh-1206).

The #1122 knob family (bench/fa_agent_timeout.py) governs the AGENT cap;
this module is its test-side analog. Slow-start server tasks (jupyter,
databases) burn tens of seconds on first boot and verifier phases still
install their own dependencies inside the task container, so the declared
per-task test budget (tb default 60s declared = 120s effective at the
bench's --global-timeout-multiplier 2) classifies healthy-but-slow
verifier phases as failure_mode=test_timeout while the agent's own work
is already done (run 37144207185: jupyter-notebook-server, agent pane
DONE, tests blew their own budget).

Policy: a per-run FLOOR for the declared max_test_timeout_sec.
patch_test_timeouts.py pads task.yaml files declaring less (the same
in-place dataset patch as the Debian apt fix); shard_tasks.py sizes LPT
shards on the padded budgets so the shard math never under-counts. A
floor costs nothing for fast verifier phases — a timeout cap is a cap,
not a wait — it only widens the failure boundary for phases that would
otherwise be killed mid-install.

Knob (all consumers share it: --floor flag > environment):
  FA_TEST_TIMEOUT_FLOOR_SEC   minimum declared test-timeout seconds.
                              Absent/empty = no floor (byte-for-byte
                              legacy budgets). 0 is accepted and is a
                              natural no-op (max(declared, 0) ==
                              declared). Anything else must be a finite
                              non-negative number — a mistyped knob
                              fails loud (a silent mis-parse costs a
                              multi-hour run), same contract as #1122.
"""

from __future__ import annotations

import math
import os
import re

FLOOR_ENV = "FA_TEST_TIMEOUT_FLOOR_SEC"

# The declared test timeout on its own line (same shape shard_tasks.py has
# matched since #142). Dataset task ids and yaml keys carry no whitespace,
# so the line anchor is unambiguous; group 2 is the value token.
TEST_TIMEOUT_RE = re.compile(r"^(\s*max_test_timeout_sec:\s*)([\d.]+)[ \t]*$", re.M)


def _optional(env, name):
    value = env.get(name)
    if value is None or value.strip() == "":
        return None
    return value.strip()


def parse_floor(env=None) -> float | None:
    """FA_TEST_TIMEOUT_FLOOR_SEC -> float | None (absent/empty = no floor)."""
    env = os.environ if env is None else env
    raw = _optional(env, FLOOR_ENV)
    if raw is None:
        return None
    try:
        value = float(raw)
    except ValueError:
        raise ValueError(
            f"{FLOOR_ENV} must be a number of seconds, got: {raw!r}"
        ) from None
    if not math.isfinite(value) or value < 0:
        raise ValueError(
            f"{FLOOR_ENV} must be a finite non-negative number of seconds,"
            f" got: {raw!r}"
        )
    return value


def resolve_floor(flag_value=None, env=None) -> float | None:
    """--floor flag > env knob; None (both absent/blank) = no floor."""
    env = os.environ if env is None else env
    if flag_value is not None and str(flag_value).strip() != "":
        return parse_floor({FLOOR_ENV: str(flag_value).strip()})
    return parse_floor(env)


def floored(declared: float, floor: float | None) -> float:
    """Declared test timeout under the floor; no floor = declared."""
    if floor is None:
        return declared
    return max(declared, floor)


def floor_task_yaml(text: str, floor: float) -> tuple:
    """Rewrite the declared max_test_timeout_sec up to the floor.

    Returns (new_text, declared, padded): declared is None when the task
    declares no value (tb's 60s default then applies implicitly — the
    patcher never invents yaml shape); a file already at/above the floor
    comes back byte-identical (idempotent re-runs).
    """
    match = TEST_TIMEOUT_RE.search(text)
    if match is None:
        return text, None, None
    declared = float(match.group(2))
    padded = floored(declared, floor)
    if padded == declared:
        return text, declared, declared
    # Only the number token is replaced; the rest of the line (indentation,
    # key, spacing) and the file stay as authored. Values render the way
    # the datasets write yaml floats (60.0 -> 120.0).
    new_text = TEST_TIMEOUT_RE.sub(
        lambda m: f"{m.group(1)}{padded}", text, count=1
    )
    return new_text, declared, padded
