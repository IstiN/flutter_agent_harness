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
  FA_TEST_TIMEOUT_MULTIPLIER  tb --global-timeout-multiplier in force
                              (bench default 2). The override math pads
                              the DECLARED value so that
                              declared x multiplier >= measured p95 x 1.5;
                              a mistyped value fails loud.
  FA_TEST_BUDGET_OVERRIDES    path to an extra override-table JSON
                              merged over the checked-in
                              test_budget_overrides.json (gh-1407).

gh-1407 (bench rounds 2-3): the floor alone cannot fix a task whose
test phase needs more than any sane global floor — jupyter-notebook-server
and build-initramfs-qemu died as test_timeout at BOTH the 120s (r1) and
360s (r2/r3 effective) caps. The fix is a per-task OVERRIDE TABLE keyed
by runner-measured test-phase p95: effective budget = max(declared,
p95 x 1.5). The table lives in test_budget_overrides.json next to this
module; load_overrides() is its single loader, override_declared() the
single budget computation — patch_test_timeouts.py (dataset patching)
and shard_tasks.py (LPT sizing + fairness guard) both go through them.
"""

from __future__ import annotations

import json
import math
import os
import re
from pathlib import Path

FLOOR_ENV = "FA_TEST_TIMEOUT_FLOOR_SEC"
MULTIPLIER_ENV = "FA_TEST_TIMEOUT_MULTIPLIER"
OVERRIDES_ENV = "FA_TEST_BUDGET_OVERRIDES"

# gh-1407: a task must survive a slow runner, not a median one — the
# measured p95 gets 50% headroom.
FACTOR = 1.5
DEFAULT_MULTIPLIER = 2.0

# Checked-in evidence table (runner-measured test-phase p95 per task).
OVERRIDES_FILENAME = "test_budget_overrides.json"

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
    return padded_task_yaml(text, floor)


def resolve_multiplier(flag_value=None, env=None) -> float:
    """--multiplier flag > env > bench default 2 (tb multiplier in force)."""
    env = os.environ if env is None else env
    raw = _optional(env, MULTIPLIER_ENV)
    if flag_value is not None and str(flag_value).strip() != "":
        raw = str(flag_value).strip()
    if raw is None:
        return DEFAULT_MULTIPLIER
    try:
        value = float(raw)
    except ValueError:
        raise ValueError(
            f"{MULTIPLIER_ENV} must be a number, got: {raw!r}"
        ) from None
    if not math.isfinite(value) or value <= 0:
        raise ValueError(
            f"{MULTIPLIER_ENV} must be a finite positive number, got: {raw!r}"
        )
    return value


def default_overrides_path() -> Path:
    """The checked-in evidence table shipped next to this module."""
    return Path(__file__).resolve().parent / OVERRIDES_FILENAME


def _validate_entry(task_id, entry):
    if not isinstance(entry, dict) or "measured_p95_sec" not in entry:
        raise ValueError(
            f"override entry {task_id!r} must carry 'measured_p95_sec'"
        )
    p95 = entry["measured_p95_sec"]
    if not isinstance(p95, (int, float)) or not math.isfinite(p95) or p95 <= 0:
        raise ValueError(
            f"override entry {task_id!r} needs a positive finite "
            f"measured_p95_sec, got: {p95!r}"
        )


def load_overrides(path=None, no_overrides=False, env=None) -> dict:
    """The effective override table: checked-in JSON (+ optional extra).

    path         explicit table path REPLACING the checked-in default.
    no_overrides True disables everything (floor-only dispatch).
    env          OVERRIDES_ENV points at an extra table merged OVER the
                 default (per-run additions without editing the repo).

    A missing default table loads empty (the guard simply has nothing to
    say); a missing EXPLICIT path or any malformed entry fails loud —
    a silently ignored table re-times-out the tasks it was meant to save.
    """
    if no_overrides:
        return {}
    env = os.environ if env is None else env
    if path is not None:
        sources = [Path(path)]
    else:
        sources = [default_overrides_path()]
        extra = _optional(env, OVERRIDES_ENV)
        if extra:
            sources.append(Path(extra))
    table: dict = {}
    for i, source in enumerate(sources):
        if not source.is_file():
            # Only explicitly named files (path flag / env table) must
            # exist; the checked-in default may be absent (no table
            # shipped = empty table, guard silent).
            if i > 0 or path is not None:
                raise ValueError(f"overrides file not found: {source}")
            continue
        try:
            data = json.loads(source.read_text())
        except (OSError, ValueError) as exc:
            raise ValueError(f"overrides file {source}: {exc}") from None
        if not isinstance(data, dict):
            raise ValueError(f"overrides file {source} must be a JSON object")
        for task_id, entry in data.items():
            if task_id.startswith("_"):
                continue  # "_"-prefixed keys are file metadata, not tasks
            _validate_entry(task_id, entry)
            table[task_id] = entry
    return table


def override_declared(declared: float, floor: float | None, p95, multiplier: float):
    """The declared test timeout to write for one task (gh-1407).

    floor first (gh-1206), then the measured-p95 override: the returned
    declared value satisfies declared x multiplier >= p95 x FACTOR, i.e.
    the effective budget carries 50% headroom over the slowest observed
    healthy run. p95 None (task not in the table) = floor-only math.
    Whole seconds: ceil keeps the product above p95 x 1.5 and keeps the
    yaml token clean.
    """
    padded = floored(declared, floor)
    if p95 is None:
        return padded
    required = math.ceil((p95 * FACTOR) / multiplier)
    return max(padded, required)


def effective_test_seconds(declared: float, multiplier: float) -> float:
    """Wall-clock seconds a declared test timeout buys at this multiplier."""
    return declared * multiplier


def padded_task_yaml(text: str, floor: float | None, p95=None,
                     multiplier: float = DEFAULT_MULTIPLIER) -> tuple:
    """Rewrite the declared max_test_timeout_sec per floor + override.

    Same contract as floor_task_yaml (byte-identical when nothing
    changes); the override path renders whole seconds as plain ints.
    """
    match = TEST_TIMEOUT_RE.search(text)
    if match is None:
        return text, None, None
    declared = float(match.group(2))
    padded = override_declared(declared, floor, p95, multiplier)
    if padded == declared:
        return text, declared, declared
    # Only the number token is replaced; the rest of the line (indentation,
    # key, spacing) and the file stay as authored. Values render the way
    # the datasets write yaml floats (60.0 -> 120.0); overrides render as
    # plain ints (180.0 -> 271).
    new_text = TEST_TIMEOUT_RE.sub(lambda m: f"{m.group(1)}{padded}", text, count=1)
    return new_text, declared, padded
