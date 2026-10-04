#!/usr/bin/env python3
"""Shared fa-session token/cost extraction for the bench adapters (issue #1123).

One extraction path for both pipelines (legacy bench/terminal_bench and
Harbor bench/harbor_fa). fa session JSONL assistant records embed
``message.usage = {input, output, cacheRead, cacheWrite, ...}``
(Usage.toJson in lib/src/types.dart) plus ``message.model``; flat
``inputTokens``-style keys are accepted as a fallback (trajectory export
shape). Only assistant records carry usage — the ``model_request_summary``
ledger records hold request-side sizes only — so summing over records
cannot double-count.

A record whose usage is missing or all-zero (provider omitted it)
contributes a chars/4 estimate tallied separately, so totals stay honest
about what the provider actually reported. The chars/4 rate matches
lib/src/compaction/token_estimation.dart.

Fail-soft by contract (issue #1123): a missing/corrupt session log leaves
zeros + a warning, never a failed trial.

cost derivation reads a pinned price table (bench/pricing.json, $/Mtok,
data not code). A model missing from the table prices as None — the
callers render ``n/a``, never a made-up 0.00.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

# Same chars-per-token rate as lib/src/compaction/token_estimation.dart.
_CHARS_PER_TOKEN = 4


class SessionUsage:
    """Token totals summed over one trial's fa session JSONL records."""

    def __init__(self):
        self.input_tokens = 0
        self.output_tokens = 0
        self.cache_read_tokens = 0
        self.cache_write_tokens = 0
        self.estimated_input_tokens = 0
        self.estimated_output_tokens = 0
        # model id -> per-model tally; "" when the record named no model.
        self.models = {}
        self.warnings = []

    @property
    def estimated_tokens(self) -> int:
        return self.estimated_input_tokens + self.estimated_output_tokens

    def total_tokens(self) -> int:
        return (
            self.input_tokens
            + self.output_tokens
            + self.cache_read_tokens
            + self.cache_write_tokens
            + self.estimated_tokens
        )


def _per_model(usage: SessionUsage, model: str) -> dict:
    return usage.models.setdefault(
        model,
        {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "estimatedOutput": 0},
    )


def _content_chars(content) -> int:
    """Char volume of an assistant message's content blocks.

    Estimate basis for records whose usage the provider omitted — tallied
    as ESTIMATED OUTPUT (the content is the response side of the request).
    """
    if isinstance(content, str):
        return len(content)
    if not isinstance(content, list):
        return 0
    n = 0
    for block in content:
        if not isinstance(block, dict):
            continue
        kind = block.get("type")
        if kind == "text":
            n += len(block.get("text") or "")
        elif kind == "thinking":
            n += len(block.get("thinking") or "")
        elif kind == "toolCall":
            args = block.get("arguments")
            if args is not None:
                n += len(args if isinstance(args, str) else json.dumps(args))
    return n


def _feed(usage: SessionUsage, obj) -> None:
    message = obj.get("message") if isinstance(obj, dict) else None
    if not isinstance(message, dict) or message.get("role") != "assistant":
        return
    model = message.get("model") or ""
    usage_or_flat = message.get("usage")
    if not isinstance(usage_or_flat, dict):
        # Flat trajectory-export shape fallback.
        usage_or_flat = {
            "input": message.get("inputTokens"),
            "output": message.get("outputTokens"),
            "cacheRead": message.get("cacheReadTokens"),
            "cacheWrite": message.get("cacheWriteTokens"),
        }

    def num(key) -> int:
        value = usage_or_flat.get(key)
        # Some providers emit floats (or strings) for token counts; a
        # silent 0 here would reroute a real report into the estimate path.
        if isinstance(value, bool):
            return 0
        if isinstance(value, int):
            return value
        if isinstance(value, float):
            # Fractional token counts round UP: under-counting spend is
            # the worse failure, and ceil matches the estimate path.
            return int(value) if value.is_integer() else math.ceil(value)
        return 0

    inp, out = num("input"), num("output")
    cr, cw = num("cacheRead"), num("cacheWrite")
    if inp == 0 and out == 0 and cr == 0 and cw == 0:
        # Provider omitted usage: contribute a chars/4 estimate, marked as such.
        reported = [
            usage_or_flat.get(key)
            for key in ("input", "output", "cacheRead", "cacheWrite")
        ]
        if reported and not any(
            isinstance(v, (int, float)) and not isinstance(v, bool) for v in reported
        ):
            # The record LOOKS like it carries usage but nothing parsed —
            # say so instead of quietly estimating real spend away.
            usage.warnings.append(
                "malformed usage record (no numeric token fields); "
                "estimated from content chars/4"
            )
        est = math.ceil(_content_chars(message.get("content")) / _CHARS_PER_TOKEN)
        usage.estimated_output_tokens += est
        _per_model(usage, model)["estimatedOutput"] += est
        return
    usage.input_tokens += inp
    usage.output_tokens += out
    usage.cache_read_tokens += cr
    usage.cache_write_tokens += cw
    tally = _per_model(usage, model)
    tally["input"] += inp
    tally["output"] += out
    tally["cacheRead"] += cr
    tally["cacheWrite"] += cw


def extract_from_text(text: str, usage: SessionUsage = None) -> SessionUsage:
    """Sum usage over concatenated JSONL text (container exec / single file)."""
    usage = usage if usage is not None else SessionUsage()
    for line in text.splitlines():
        if '"usage"' not in line and '"inputTokens"' not in line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue  # corrupt line contributes nothing (fail-soft)
        if isinstance(obj, dict):
            _feed(usage, obj)
    return usage


def extract_from_dir(sessions_dir, usage: SessionUsage = None) -> SessionUsage:
    """Sum usage over every *.jsonl under the trial's fah-sessions dir.

    rglob covers retries (multiple sessions per trial) and subagent
    sessions — all of it is the trial's real spend (issue #1123 E1/E2).
    """
    usage = usage if usage is not None else SessionUsage()
    sessions_dir = Path(sessions_dir)
    if not sessions_dir.is_dir():
        usage.warnings.append(f"session dir missing: {sessions_dir}")
        return usage
    for path in sorted(sessions_dir.rglob("*.jsonl")):
        try:
            extract_from_text(path.read_text(errors="replace"), usage)
        except OSError as exc:
            usage.warnings.append(f"unreadable session log {path}: {exc}")
    return usage


def load_pricing(path) -> dict:
    """Load the pinned $/Mtok table (bench/pricing.json shape). Missing → {}."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}
    table = data.get("usd_per_mtok") if isinstance(data, dict) else None
    return table if isinstance(table, dict) else {}


def price_entry(pricing: dict, model) -> dict | None:
    """Pricing entry for a model id (exact, then case-insensitive); None = unpriced."""
    if not model:
        return None
    if model in pricing:
        return pricing[model]
    lowered = str(model).lower()
    for key, entry in pricing.items():
        if key.lower() == lowered:
            return entry
    return None


def cost_usd(
    entry: dict | None,
    input_tokens: int,
    output_tokens: int,
    cache_read_tokens: int = 0,
    cache_write_tokens: int = 0,
) -> float | None:
    """USD for a token split under one pricing entry; None when unpriced (E3)."""
    if entry is None:
        return None

    def rate(key) -> float:
        value = entry.get(key)
        # A rate the table omits prices at 0 only because the table pins the
        # rest; an absent MODEL is handled by price_entry → None (n/a).
        return float(value) if isinstance(value, (int, float)) else 0.0

    return (
        input_tokens * rate("input")
        + output_tokens * rate("output")
        + cache_read_tokens * rate("cache_read")
        + cache_write_tokens * rate("cache_write")
    ) / 1e6
