#!/usr/bin/env python3
"""Bench run metrics: ConnTrace folding, latency aggregation, live progress,
and the score-honesty cross-check (issue #1392).

The fa agent inside the trial container emits one structured line per
provider HTTP lifecycle event when FA_CONN_DEBUG=1 (lib/src/providers/
conn_trace_io.dart — the Dart side of this contract):

    FA_CONN {"event":"first_byte","seq":7,"wallSec":213.0,"slow":true,
             "fresh":false,"localPort":54321,"poolSize":2,"connAgeSec":912.0}

The bench adapter tails the trial's pane (where fa's stderr lands), feeds
the FA_CONN lines through [LiveProgress] AS THEY HAPPEN (a stall is then
visible forming in the live Actions log), folds them into the trial's
bench_metrics.json, and aggregates the run report's p50/p95 latency per
concurrency level.

Fail-soft by contract: noise lines, corrupt JSON, and missing files never
crash a trial — they degrade the metric.
"""
from __future__ import annotations

import json
import math
import sys
from datetime import datetime, timezone
from pathlib import Path

FA_CONN_PREFIX = "FA_CONN "

# Issue #1392: the stall-gap threshold (ProgressWatch freeze boundary,
# StallSentinel trigger, and the AC8 score-honesty yardstick). gh-1430
# raised the shipped gap to 360s — fa's stream-idle watchdog (300s,
# lib/src/providers/provider_common.dart) + a 60s margin; this yardstick
# must mirror bench/fa_agent_timeout.py's _STALL_GAP_DEFAULT (the
# test_bench_metrics coupling REG fails if the two drift). Round-2
# healthy max gap was ~200s; the pre-gh-1430 default was 240s.
DEFAULT_STALL_GAP_SEC = 360.0

# Seconds a first byte may take before the live line flags it (the card's
# "⚠ slow (>120s)" threshold; class-B gaps start ~240s, healthy ~200s).
SLOW_FIRST_BYTE_SEC = 120.0


def parse_conn_events(text):
    """FA_CONN-prefixed JSON lines -> list of dicts (noise tolerated).

    Corrupt or foreign lines are skipped; a pane stream is noise-heavy by
    design and one bad line must not cost a metric.
    """
    if not text:
        return []
    events = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith(FA_CONN_PREFIX):
            continue
        try:
            event = json.loads(line[len(FA_CONN_PREFIX):])
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict) and "event" in event:
            events.append(event)
    return events


def percentile(values, pct):
    """Nearest-rank percentile; [] -> None."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(pct / 100.0 * len(ordered)))
    return ordered[min(rank, len(ordered)) - 1]


def summarize_trial(trial_name, events, concurrency_level=None, stall=None):
    """Fold parsed ConnTrace events into the per-trial bench_metrics shape.

    Shape (AC2):
      trial, concurrency_level,
      requests: [{seq, first_byte_sec, fresh, local_port, pool_size}],
      latency: {first_byte: {p50, p95, max, n} | None, fresh_requests,
                reused_requests, slow_first_byte_count},
      watchdog_events: [connect/idle fires, stale sockets, retries],
      stall: caller-supplied StallSentinel payload (hang capture pointer).
    """
    requests = []
    first_bytes = []
    fresh = reused = slow = 0
    watchdog = []
    for event in events:
        kind = event.get("event")
        if kind == "first_byte":
            wall = event.get("wallSec")
            requests.append(
                {
                    "seq": event.get("seq"),
                    "first_byte_sec": wall,
                    "fresh": bool(event.get("fresh")),
                    "local_port": event.get("localPort"),
                    "pool_size": event.get("poolSize"),
                }
            )
            if isinstance(wall, (int, float)):
                first_bytes.append(float(wall))
            if event.get("fresh"):
                fresh += 1
            else:
                reused += 1
            if event.get("slow"):
                slow += 1
        elif kind in (
            "idle_watchdog_fired",
            "connect_watchdog_fired",
            "stale_socket",
            "retry",
            "stream_error",
            "connect_failed",
        ):
            watchdog.append(event)
    metrics = {
        "trial": trial_name,
        "concurrency_level": concurrency_level,
        "requests": requests,
        "latency": {
            "first_byte": (
                None
                if not first_bytes
                else {
                    "p50": percentile(first_bytes, 50),
                    "p95": percentile(first_bytes, 95),
                    "max": max(first_bytes),
                    "n": len(first_bytes),
                }
            ),
            "fresh_requests": fresh,
            "reused_requests": reused,
            "slow_first_byte_count": slow,
        },
        "watchdog_events": watchdog,
    }
    if stall is not None:
        metrics["stall"] = stall
    return metrics


def _fmt_sec(value):
    """213.0 -> '213', 0.4 -> '0.4' (compact whole-second rendering)."""
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def live_progress_line(event):
    """One ConnTrace event -> one live stderr line (flushed by the caller).

    The format contract (AC2 IT pins it): per-request and per-watchdog
    lines that make a stall visible forming in the Actions log.
    """
    kind = event.get("event")
    if kind == "request_start":
        return f"[fa-bench] req#{event.get('seq')} sent"
    if kind == "first_byte":
        wall = _fmt_sec(event.get("wallSec"))
        state = "fresh" if event.get("fresh") else "reused"
        pool = f", pool={event.get('poolSize')}" if event.get("poolSize") else ""
        if event.get("slow"):
            return (
                f"[fa-bench] req#{event.get('seq')} first byte after "
                f"{wall}s ⚠ ({state}{pool}, port={event.get('localPort')})"
            )
        return (
            f"[fa-bench] req#{event.get('seq')} first byte after "
            f"{wall}s ({state}{pool})"
        )
    if kind == "idle_watchdog_fired":
        return (
            f"[fa-bench] idle-watchdog FIRED after "
            f"{_fmt_sec(event.get('idleSec'))}s "
            f"(conn age {_fmt_sec(event.get('connAgeSec'))}s, "
            f"port {event.get('localPort')})"
        )
    if kind == "connect_watchdog_fired":
        return (
            f"[fa-bench] connect-watchdog FIRED after "
            f"{_fmt_sec(event.get('timeoutSec'))}s "
            f"(attempt {event.get('attempt')})"
        )
    if kind == "connect_failed":
        state = "fresh" if event.get("fresh") else "pooled"
        return (
            f"[fa-bench] connect failed ({state}, "
            f"attempt {event.get('attempt')}): {event.get('error')}"
        )
    if kind == "retry":
        return (
            f"[fa-bench] retry #{event.get('attempt')} in "
            f"{_fmt_sec(event.get('delaySec'))}s ({event.get('reason')})"
        )
    if kind == "stale_socket":
        return (
            f"[fa-bench] stale socket port {event.get('localPort')} "
            f"(age {_fmt_sec(event.get('ageSec'))}s): {event.get('error')}"
        )
    if kind == "request_done":
        return (
            f"[fa-bench] req#{event.get('seq')} done status "
            f"{event.get('statusCode')}"
        )
    return None


class LiveProgress:
    """Renders FA_CONN lines as they happen (issue #1392 LiveProgress).

    The adapter feeds every NEW pane byte each poll; each parsed event
    prints one flushed line so a stall is visible forming in the live
    Actions log, not just in the post-mortem.
    """

    def __init__(self, out=None):
        self.out = out if out is not None else sys.stderr

    def feed(self, new_text):
        if not new_text:
            return
        for event in parse_conn_events(new_text):
            line = live_progress_line(event)
            if line is None:
                continue
            print(line, file=self.out, flush=True)


def _parse_iso_timestamp(raw):
    """ISO8601 -> epoch seconds; None when absent/unparseable."""
    if not isinstance(raw, str) or not raw:
        return None
    value = raw.strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def session_assistant_gaps(jsonl_text):
    """Gaps (seconds) between consecutive assistant message records.

    The AC8/ProgressWatch record stream: a session file is a header line
    plus one JSON record per line, each carrying an ISO `timestamp`;
    assistant records are the model's turns (`message.role ==
    "assistant"`, the same shape fa_usage.py folds). Corrupt lines and
    records without timestamps are skipped.
    """
    gaps = []
    last = None
    for line in (jsonl_text or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(record, dict):
            continue
        message = record.get("message")
        if not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        stamp = _parse_iso_timestamp(record.get("timestamp"))
        if stamp is None:
            continue
        if last is not None:
            gaps.append(max(0.0, stamp - last))
        last = stamp
    return gaps


def max_session_gap(jsonl_text):
    """Largest assistant-record gap, or None when the file says nothing."""
    gaps = session_assistant_gaps(jsonl_text)
    if not gaps:
        return None
    return max(gaps)


def score_honesty_violation(failure_mode, max_gap_sec, stall_gap_sec=None):
    """AC8: an agent_timeout verdict on a trial whose session shows only
    steady sub-threshold gaps cannot recur silently — it is a violation
    the report must name (the round-2 contradiction)."""
    if stall_gap_sec is None:
        stall_gap_sec = DEFAULT_STALL_GAP_SEC
    if failure_mode != "agent_timeout":
        return False
    if max_gap_sec is None:
        return False
    return max_gap_sec < stall_gap_sec


def loud_empty_violation(metrics, usage_tokens):
    """Issue #1406 loud-empty guard predicate: True when a trial's
    bench_metrics.json folded ZERO ConnTrace requests while the usage
    fold proves the trial made model requests (tokens > 0).

    Round-3 bench shipped 29/29 empty shells that way — an
    instrumentation outage must never masquerade as a quiet trial.
    Anything unreadable (non-dict metrics, absent/zero tokens) is not a
    violation: the usage fold's own warnings cover those.
    """
    if not isinstance(metrics, dict):
        return False
    if not usage_tokens or isinstance(usage_tokens, bool) or usage_tokens < 0:
        return False
    return metrics.get("requests") == []


def write_bench_metrics(path, metrics):
    """Persist one trial's bench_metrics.json (parents created)."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(metrics, indent=2, sort_keys=True))
