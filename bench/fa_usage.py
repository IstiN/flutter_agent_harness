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

import io
import json
import math
import sys
import tarfile
from pathlib import Path, PurePosixPath
from typing import NamedTuple

# Same chars-per-token rate as lib/src/compaction/token_estimation.dart.
_CHARS_PER_TOKEN = 4

# gh-1838 AC6: pricing override channel. The value is inline JSON or a
# path to a pricing JSON (the same usd_per_mtok shape); it merges OVER
# bench/pricing.json per model key so a run can price/correct models
# without editing the repo.
PRICING_OVERRIDE_ENV = "FA_BENCH_PRICING"


class ResolvedPricing(NamedTuple):
    """Pricing after resolution (gh-1838 AC5/AC6).

    table    — merged usd_per_mtok ({} when nothing loaded);
    aliases  — merged {model_id: target_model_id} estimate map (AC7);
    source   — human string for the summary's pricing line
               ("repo default — <path>" / "env override FA_BENCH_PRICING
               (file <path>) over repo default <path>");
    warnings — loud resolution problems, each naming the path + error.
    """

    table: dict
    aliases: dict
    source: str
    warnings: list


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
        # gh-1643: True when at least one `model_request_summary` never
        # finalized (the run was killed before its assistant message) —
        # the totals cover PARTIAL knowledge (estimated request-side
        # input, no output). Consumers must never read them as complete
        # accounting.
        self.usage_incomplete = False
        # Last model id seen on a finalized request (gh-1643): a dangling
        # request carries no model of its own, so its estimate is
        # attributed to the model the session actually ran on.
        self.last_model = ""

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


def _feed_dangling(usage: SessionUsage, known_chars: int) -> None:
    """A `model_request_summary` whose request never finalized (gh-1643).

    The run was killed before its assistant message: the summary's KNOWN
    request-side volume — system prompt + outbound message chars, persisted
    BEFORE the request — counts as estimated input at the shared chars/4
    rate; output is unknown and stays 0. The usage is marked incomplete:
    a request the fold only partially knows is never a silent zero.
    """
    usage.usage_incomplete = True
    est = math.ceil(known_chars / _CHARS_PER_TOKEN)
    if est == 0:
        return
    usage.estimated_input_tokens += est
    model = usage.last_model or ""
    tally = _per_model(usage, model)
    tally["estimatedInput"] = tally.get("estimatedInput", 0) + est


def _request_known_chars(data) -> int:
    """Known request-side chars of one `model_request_summary` record.

    `systemPromptChars` + Σ per-message `chars` — the same basis the Dart
    fold's dangling-request fallback uses (gh-1073's ledger cap preserves
    both, so the estimate survives the newest-tail capping).
    """
    if not isinstance(data, dict):
        return 0
    total = 0
    system = data.get("systemPromptChars")
    if isinstance(system, int) and not isinstance(system, bool):
        total += system
    messages = data.get("messages")
    if isinstance(messages, list):
        for message in messages:
            if isinstance(message, dict):
                chars = message.get("chars")
                if isinstance(chars, int) and not isinstance(chars, bool):
                    total += chars
    # issue #1882 AC1: stripped records fold older messages into a
    # {count, chars} aggregate — part of the estimation basis exactly
    # like the per-message chars.
    dropped = data.get("droppedMessages")
    if isinstance(dropped, dict):
        chars = dropped.get("chars")
        if isinstance(chars, int) and not isinstance(chars, bool):
            total += chars
    return total


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
    if model:
        usage.last_model = model
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
    """Sum usage over concatenated JSONL text (container exec / single file).

    gh-1643: request-side records fold too. A `model_request_summary` whose
    request never produced a finalized assistant message — flushed by a
    later summary, a segment marker, a session header, or the end of the
    text — contributes its KNOWN request-side volume as estimated input and
    sets `usage_incomplete`. Finalized requests never double-count: the
    assistant message's usage supersedes its summary.
    """
    usage = usage if usage is not None else SessionUsage()
    pending_chars = None
    for line in text.splitlines():
        if (
            '"usage"' not in line
            and '"inputTokens"' not in line
            and '"model_request_summary"' not in line
            and '"usage_segment_start"' not in line
        ):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue  # corrupt line contributes nothing (fail-soft)
        if not isinstance(obj, dict):
            continue
        custom_type = obj.get("customType")
        if custom_type == "model_request_summary":
            if pending_chars is not None:
                # The previous request never finalized — count it now.
                _feed_dangling(usage, pending_chars)
            pending_chars = _request_known_chars(obj.get("data"))
            continue
        if custom_type == "usage_segment_start":
            if pending_chars is not None:
                _feed_dangling(usage, pending_chars)
                pending_chars = None
            continue
        if obj.get("type") == "session":
            # A new chain header: anything pending belongs to the previous
            # chain (replay/takeover file pairs) — it never finalized.
            if pending_chars is not None:
                _feed_dangling(usage, pending_chars)
                pending_chars = None
            continue
        _feed(usage, obj)
        message = obj.get("message")
        if isinstance(message, dict) and message.get("role") == "assistant":
            # The request finalized: its summary is superseded by the
            # message usage — never double-count.
            pending_chars = None
    if pending_chars is not None:
        _feed_dangling(usage, pending_chars)
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


def extract_session_archive(tar_bytes: bytes, dest) -> int:
    """Unpack a docker get_archive tarball of the container's session root
    into the trial's host agent-logs dir (issue #1339 AC4). Returns the
    extracted file count.

    The archive originates from a container path the model's own bash tool
    can write, so the data filter's traversal rules are re-asserted
    manually on EVERY interpreter BEFORE anything is extracted — a guard
    that vanishes on a TypeError fallback is not a guard (PR #1351
    review): only regular files and directories, no absolute paths, no
    `..` members, nothing resolving outside dest. Violations fail loud;
    the tarfile data filter is then applied where the interpreter has it.
    """
    root = Path(dest).resolve()
    with tarfile.open(fileobj=io.BytesIO(tar_bytes)) as tar:
        members = tar.getmembers()
        for member in members:
            if not (member.isfile() or member.isdir()):
                raise ValueError(
                    f"non-regular member in session archive: {member.name!r}"
                )
            if member.name.startswith("/") or ".." in PurePosixPath(member.name).parts:
                raise ValueError(f"unsafe path in session archive: {member.name!r}")
            if not (root / member.name).resolve().is_relative_to(root):
                raise ValueError(f"path escapes the trial dir: {member.name!r}")
        try:
            tar.extractall(dest, members=members, filter="data")
        except TypeError:  # pre-backport interpreter: no filter kwarg
            print(
                "[fa_agent] warning: this Python lacks the tarfile data "
                "filter; extracting the manually screened session archive "
                "without it",
                file=sys.stderr,
            )
            tar.extractall(dest, members=members)
        return sum(1 for member in members if member.isfile())


def load_pricing(path) -> dict:
    """Load the pinned $/Mtok table (bench/pricing.json shape). Missing → {}."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}
    table = data.get("usd_per_mtok") if isinstance(data, dict) else None
    return table if isinstance(table, dict) else {}


def _read_pricing_doc(path):
    """(doc | None, error | None) — one pricing JSON read + parse."""
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle), None
    except (OSError, json.JSONDecodeError) as exc:
        return None, exc


def _pricing_parts(doc, what: str, warnings: list) -> tuple[dict, dict, bool]:
    """(usd_per_mtok, aliases, accepted) from one pricing doc; loud shape
    warnings. accepted=False means the doc was rejected outright (no
    usd_per_mtok table) and contributed nothing — callers must not claim
    it as an active source."""
    if not isinstance(doc, dict) or not isinstance(doc.get("usd_per_mtok"), dict):
        warnings.append(f"{what}: no usd_per_mtok table — ignored")
        return {}, {}, False
    aliases = doc.get("aliases")
    if aliases is None:
        aliases = {}
    elif isinstance(aliases, dict):
        aliases = dict(aliases)
    else:
        warnings.append(f"{what}: aliases is not an object — ignored")
        aliases = {}
    return dict(doc["usd_per_mtok"]), aliases, True


def _validate_aliases(table: dict, aliases: dict, warnings: list) -> None:
    """Loud dead-end detection over the merged alias map (gh-1838 review:
    an alias whose target has no entry must never silently degrade to the
    direct entry — that is exactly the silent-resolution failure AC5
    bans). Chains are followed hop-by-hop; a chain is valid when ANY hop
    lands on a table entry; cycles and dead ends warn, naming the alias,
    the target, and the verdict."""
    for alias in sorted(aliases, key=str):
        target = aliases[alias]
        seen = {str(alias)}
        current = target
        while (
            isinstance(current, str)
            and current
            and price_entry(table, current) is None
            and str(current) not in seen
        ):
            seen.add(str(current))
            current = aliases.get(current)
        if (
            not isinstance(current, str)
            or not current
            or price_entry(table, current) is None
        ):
            warnings.append(
                f'alias "{alias}" → "{target}" has no entry in the '
                "loaded table — alias ignored"
            )


def load_pricing_resolved(default_path, override=None) -> ResolvedPricing:
    """bench/pricing.json + the FA_BENCH_PRICING override (gh-1838 AC5/AC6).

    `override` is the env channel's VALUE: inline JSON or a path to a
    pricing JSON (usd_per_mtok shape, optional aliases). It merges OVER
    the repo default per model key (input/output/cache_read/cache_write)
    and per alias — an existing base rate survives unless the override
    names it. Every load/parse failure appends a LOUD warning naming the
    path + the error (an entry that exists must never degrade to a
    silent n/a); a failed — or shape-rejected, contributing-nothing —
    override falls back to the repo default and the `source` label says
    so instead of claiming an active override. Alias targets are
    validated against the MERGED table: a dead-end alias warns loudly
    (naming alias + target) instead of silently degrading to the direct
    entry (gh-1838 review). Unknown models stay unpriced — an override
    never invents rates, it only supplies them (#1123 rule).
    """
    default = str(default_path)
    warnings: list[str] = []
    doc, err = _read_pricing_doc(default)
    if doc is None:
        warnings.append(f"pricing file {default} failed to load: {err}")
        table, aliases = {}, {}
    else:
        table, aliases, _ = _pricing_parts(doc, f"pricing file {default}", warnings)
    source = f"repo default — {default}"
    if override is not None and override.strip():
        stripped = override.strip()
        if stripped.startswith("{"):
            what = "env override FA_BENCH_PRICING (inline JSON)"
            try:
                odoc, oerr = json.loads(stripped), None
            except json.JSONDecodeError as exc:
                odoc, oerr = None, exc
        else:
            what = f"env override FA_BENCH_PRICING (file {stripped})"
            odoc, oerr = _read_pricing_doc(stripped)
        if odoc is None:
            warnings.append(f"{what} failed to load: {oerr}")
            source += " (⚠️ FA_BENCH_PRICING override failed — see pricing warnings)"
        else:
            otable, oaliases, oaccepted = _pricing_parts(odoc, what, warnings)
            for model, entry in otable.items():
                if not isinstance(entry, dict):
                    warnings.append(
                        f"{what}: entry for {model} is not an object — ignored"
                    )
                    continue
                table[model] = {**table.get(model, {}), **entry}
            aliases.update(oaliases)
            if oaccepted:
                source = f"{what} over repo default {default}"
            else:
                source += (
                    " (⚠️ FA_BENCH_PRICING override failed — see pricing warnings)"
                )
    _validate_aliases(table, aliases, warnings)
    return ResolvedPricing(table, aliases, source, warnings)


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


def _alias_target(aliases: dict, model) -> str | None:
    """The alias target configured for model (exact, then
    case-insensitive); None when there is no usable string target."""
    if not model:
        return None
    target = aliases.get(model)
    if target is None:
        lowered = str(model).lower()
        for key, candidate in aliases.items():
            if key.lower() == lowered:
                target = candidate
                break
    return target if isinstance(target, str) and target else None


def resolve_entry(table: dict, aliases: dict, model) -> tuple[dict | None, str | None]:
    """Pricing entry for a model id, resolving the `aliases` map (gh-1838 AC7).

    Returns (entry, alias_target). alias_target is None for a direct
    entry; when an alias maps the model onto another id's rates it is
    that target id and the CALLER must label the cost as an estimate at
    the target's rates — never mix it with real billing. The alias is
    explicit config and takes precedence over a direct entry (it is how
    a subscription plan's $0 entry gets upgraded to a labelled estimate);
    (None, None) = unpriced: unknown models stay n/a, an alias never
    invents rates.

    Chains resolve hop-by-hop (a→b, b→c prices `a` at c's rates, labelled
    "estimate @ c rates"); cycles and dead ends stop following and fall
    back to the model's own direct entry. load_pricing_resolved has
    already warned loudly about every dead-end alias at load time (gh-1838
    review), so this fallback is silent only for callers holding an
    unvalidated map.
    """
    if model:
        seen: set[str] = set()
        current = model
        for _ in range(5):  # chains are config, not a graph — cap the hops
            target = _alias_target(aliases, current)
            if target is None or str(target) in seen:
                break
            seen.add(str(current))
            entry = price_entry(table, target)
            if entry is not None:
                return entry, target
            current = target
    entry = price_entry(table, model)
    if entry is not None:
        return entry, None
    return None, None


def cost_components(
    entry: dict | None,
    input_tokens: int,
    output_tokens: int,
    cache_read_tokens: int = 0,
    cache_write_tokens: int = 0,
) -> dict | None:
    """Per-component USD (input/output/cache_read/cache_write) under one
    pricing entry; None when unpriced. Sums to cost_usd — kept separate
    so the summary can show the cache_read component (gh-1838 AC8: the
    cached reads dominate API-style cost and must stay visible)."""
    if entry is None:
        return None

    def rate(key) -> float:
        value = entry.get(key)
        # A rate the table omits prices at 0 only because the table pins the
        # rest; an absent MODEL is handled by price_entry → None (n/a).
        return float(value) if isinstance(value, (int, float)) else 0.0

    return {
        "input": input_tokens * rate("input") / 1e6,
        "output": output_tokens * rate("output") / 1e6,
        "cache_read": cache_read_tokens * rate("cache_read") / 1e6,
        "cache_write": cache_write_tokens * rate("cache_write") / 1e6,
    }


def cost_usd(
    entry: dict | None,
    input_tokens: int,
    output_tokens: int,
    cache_read_tokens: int = 0,
    cache_write_tokens: int = 0,
) -> float | None:
    """USD for a token split under one pricing entry; None when unpriced (E3)."""
    components = cost_components(
        entry, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens
    )
    return None if components is None else sum(components.values())
