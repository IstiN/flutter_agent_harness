#!/usr/bin/env python3
"""Resolution-rate summary for harbor job dirs.

Usage:
    summary.py [--expected-trials N] <jobs-dir>

Reads <jobs-dir>/<job>/*/result.json (per-trial TrialResults; each job's
top-level result.json is a file, not a dir, so the glob skips it) and
prints a GitHub-flavoured-markdown resolution table, also appending it to
$GITHUB_STEP_SUMMARY when set.

Token/cost columns (issue #1123): each trial's fa session usage is folded
into result.json's agent_result by fa_agent.py (n_input/n_output/
n_cache_tokens, estimated share in metadata, cost_usd derived from the
pinned bench price table bench/pricing.json — null renders n/a, never a
made-up price). The table gains per-split tokens/cost columns next to the
resolution rate; a spend line carries the overall totals.

Jobs named fa-4.0-<env>-gpu-<shard> count as the GPU split; everything
else is CPU (bench-harbor.yml names jobs fa-<family>-<env>-<kind>-<shard>;
the legacy fa-4.0-{docker,modal}-<shard> names map modal -> GPU).

--family (issue #1124) keys the report to one Terminal-Bench dataset
family: job dirs from OTHER families are ignored — merged artifacts from
different dataset versions never cross-contaminate a report — and the
report ends in a paste-ready row for the per-version results ledger in
docs/bench.md (dataset, model, fa commit, date, resolution, cost, run —
cost from the same pricing.json accounting, n/a when unpriced). Without
--family the legacy behaviour applies (all job dirs; title pinned to 4.0;
no ledger block).

A trial is resolved when every verifier reward is 1.0; the resolution rate
is resolved trials / scored (non-errored) trials. gh-1579 adds the
verifier integrity gate: every trial's verifier stdout
(verifier/test-stdout.txt) is classified by verifier_integrity.classify()
before the verdict is trusted — a trial whose verifier silently skipped
work (browser batches that never loaded) is `verifier_compromised`, a
fourth reported-only class: pulled out of the scored pool entirely
(neither resolved numerator nor clean denominator — I1), listed by name
in its own breakdown line. Retry/connection storms without failed loads
are `suspect` — annotated, score unchanged. A pass whose verifier stdout
is missing or undecodable is flagged `verifier_unreadable` (I2: absence
of evidence is reported, never assumed clean). Legacy layouts without
verifier stdout keep their shape except the unreadable annotation; the
errored-class (gh-1556) and exit-code semantics are unchanged — the gate
reports, it never reddens the step.

harbor exits 0 even with unresolved trials, so the exit code is the
verdict on run COMPLETENESS
only: 1 when nothing was produced or fewer than --expected-trials trials
produced a readable result.json (lost shard). gh-1556 AC3: the
completeness count is by PRESENCE — a trial whose result.json was written
counts as attempted regardless of exception class, so legitimate
dataset-cap or ladder timeouts (errored before a verdict) can never redden
the job; the errored class gets its own breakdown line instead, and exit 1
is reserved for genuinely lost trials. Unresolved trials are the
scoreboard, not an infra failure — reported without failing the step.

gh-1578: the errored class splits by OWNER. A verifier hang executing
agent-authored code (harbor's VerifierTimeoutError, defensively any
*Verifier*Timeout* class) is reported under its own agent-attributed
class — «Verifier timeouts (agent code hung the verifier — counts against
the agent)» — never inside the harness/infra bucket, with each hang's
wall-clock named per-trial so the 30-minute burn is visible. The guard is
reporting-only by design: the pinned harbor (.bench-venv) exposes no
post-trial hook mapping the timeout onto a reward-0 verdict, so no reward
is fabricated (the score stays 0/error) and the real fix — task tests
must timeout agent code, plus a harbor verifier-timeout → reward-0
mapping — is escalated upstream (gh-1578 AC5).
"""
import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

# gh-1578: a verifier hang while executing agent-authored code is the
# AGENT's zero, not an infra failure. Harbor raises VerifierTimeoutError
# (and, defensively, any future *Verifier*Timeout* class) when the
# in-container verifier test — running agent-written code — exceeds the
# outer trial timeout. Those trials keep harbor's error shape (no reward
# exists), but this summary attributes them to the agent side in their
# own reported class, never the harness/infra bucket, and names the
# wall-clock each hang burned. Reporting-only by design: the pinned
# harbor (.bench-venv) exposes no post-trial hook mapping the timeout
# onto a reward-0 verdict, so nothing is rewritten — the score stays
# 0/error and the real fix (task tests must timeout agent code; harbor
# mapping verifier timeouts onto reward 0) is escalated upstream
# (gh-1578 AC5).
_VERIFIER_TIMEOUT_LINE = (
    "Verifier timeouts (verifier_timeout — agent code hung the verifier,"
    " counts against the agent)"
)
_VERIFIER_TIMEOUT_FOOTER = (
    "(score stays 0/error — no reward is fabricated; the real fix is"
    " upstream: task tests must timeout agent code + a harbor"
    " verifier-timeout → reward-0 mapping — gh-1578)"
)
_HANG_SECS_RE = re.compile(
    r"timed out after\s*([0-9]+(?:\.[0-9]+)?)\s*seconds?", re.IGNORECASE
)


def _is_verifier_timeout(exception: str) -> bool:
    """True for the agent-attributed verifier-hang class: harbor's
    VerifierTimeoutError plus, defensively, any *Verifier*Timeout* class.

    Keys on the exception TYPE, never on timing — a verifier that crashed
    before running agent code (docker failure, missing image, a
    Verifier*Error without a timeout) keeps the infra class (gh-1578 E1).
    """
    name = exception.lower()
    return "verifier" in name and "timeout" in name


def _parse_iso_ts(value) -> "datetime | None":
    if not isinstance(value, str) or not value:
        return None
    try:
        ts = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    # E5 hardening (rework thread): harbor versions/sources may mix naive
    # and aware stamps; the delta in _hang_seconds must never raise
    # TypeError on the subtraction. Naive is read as UTC — harbor stamps
    # UTC clocks with or without the offset suffix.
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts


def _hang_seconds(data: dict) -> "float | None":
    """gh-1578 AC6: the wall-clock a verifier hang burned — from the
    exception message («timed out after N seconds») when parseable, else
    the started_at/finished_at delta (whole-trial wall-clock — agent
    time included — only an upper bound on the verifier hang). None when
    neither survives."""
    info = data.get("exception_info")
    message = info.get("exception_message") if isinstance(info, dict) else None
    match = _HANG_SECS_RE.search(str(message or ""))
    if match:
        return float(match.group(1))
    started = _parse_iso_ts(data.get("started_at"))
    finished = _parse_iso_ts(data.get("finished_at"))
    if started and finished:
        delta = (finished - started).total_seconds()
        if delta > 0:
            return delta
    return None


def _format_hang_secs(secs: float) -> str:
    text = f"~{secs:.0f}s"
    if secs >= 120:
        text += f" (~{secs / 60:.1f} min)"
    return text


def _ledger_records(trial_dir: Path) -> list:
    """Every hidden `task_ledger` custom record in the trial's synced fa
    session logs, in file then line order."""
    ledgers = []
    for sessions in sorted(trial_dir.glob("agent*/fah-sessions")):
        for path in sorted(sessions.glob("*.jsonl")):
            try:
                text = path.read_text()
            except OSError:
                continue
            for line in text.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if (
                    isinstance(record, dict)
                    and record.get("type") == "custom"
                    and record.get("customType") == "task_ledger"
                ):
                    ledgers.append(record)
    return ledgers


_LEDGER_VERIFIED = ("pass", "fixed")  # keep in lockstep with the Dart
# `TaskLedgerItemStatus` enum and the SIBLING copy in
# bench/terminal_bench/summary.py (the two summary scripts are
# standalone-by-design — different layout roots — so this parser is
# duplicated; change both together).


def _ledger_cell(trial_dir: Path) -> str:
    """gh-1412: the trial's checklist-coverage cell from its last hidden
    `task_ledger` record — "checklist: V/T [(N unmet)]", "checklist: none"
    when the session carries no ledger.

    Tolerates the corrupt payloads the Dart fold deliberately tolerates
    ("a corrupt ledger payload never throws"): a non-dict `data`, or an
    `items` that is not a list, degrades to `checklist: none` — never an
    AttributeError. An items-less ledger is `none` too: it verifies
    nothing, and rendering 0/0 would count it as fully verified in the
    coverage tally below. Duplicate of the sibling parser in
    bench/terminal_bench/summary.py (the scripts are standalone-by-design)
    — change both together.
    """
    ledgers = _ledger_records(trial_dir)
    if not ledgers:
        return "checklist: none"
    data = ledgers[-1].get("data")
    rows = data.get("items") if isinstance(data, dict) else None
    items = rows if isinstance(rows, list) else []
    if not items:
        return "checklist: none"
    total = len(items)
    verified = sum(
        1
        for item in items
        if isinstance(item, dict)
        and str(item.get("status") or "").lower() in _LEDGER_VERIFIED
    )
    unmet = total - verified
    cell = f"checklist: {verified}/{total}"
    if unmet:
        cell += f" ({unmet} unmet)"
    return cell


def _status(row: dict) -> str:
    """The row's integrity status (gh-1579). Rows that predate the gate
    (hand-built splits) count as ok — the gate is additive (AC8)."""
    verdict = row.get("integrity")
    return verdict.status if verdict is not None else "ok"


def _trial_rows(job_dir: Path) -> list[dict]:
    # gh-1579: the integrity gate rides the same lazy-import pattern as
    # families below — importlib-based harnesses load this module
    # without this dir on sys.path.
    import verifier_integrity as vi

    rows = []
    for path in sorted(glob.glob(str(job_dir / "*" / "result.json"))):
        try:
            data = json.loads(Path(path).read_text())
        except (OSError, ValueError):
            # gh-1578 E5: an unreadable result.json is NOT a trial — it
            # never enters any reported class and stays unattempted, so
            # the lost-shard guard below keeps its teeth.
            continue
        if not isinstance(data, dict):
            continue
        verdict = data.get("verifier_result")
        # E5 (rework thread): the same tolerant-read contract as
        # exception_info below — a truthy non-dict rewards degrades to
        # no rewards, never an AttributeError on .values().
        raw_rewards = verdict.get("rewards") if isinstance(verdict, dict) else None
        rewards = raw_rewards if isinstance(raw_rewards, dict) else {}
        # E5 (rework thread): a rewards value that is not numeric (a
        # label, null) is skipped, never a ValueError/TypeError killing
        # the render — the numeric values still score.
        scores = []
        for value in rewards.values():
            try:
                scores.append(float(value))
            except (TypeError, ValueError):
                pass
        resolved = bool(scores) and all(v >= 1.0 for v in scores)
        # Tolerate malformed/missing exception_info (E5): no dict, no
        # class — never an AttributeError, never verifier_timeout.
        info = data.get("exception_info")
        if not isinstance(info, dict):
            info = {}
        exception = str(info.get("exception_type") or "")
        verifier_timeout = _is_verifier_timeout(exception)
        # Issue #1123: token/cost accounting folded in by fa_agent.py at
        # populate_context_post_run time; absent (old runs) → zeros + n/a.
        agent = data.get("agent_result")
        if not isinstance(agent, dict):
            agent = {}
        metadata = agent.get("metadata")
        if not isinstance(metadata, dict):
            metadata = {}
        trial_dir = Path(path).parent
        # gh-1579 integrity gate: read + classify the verifier's stdout
        # BEFORE the verdict is trusted (pure classifier; IO here).
        stdout_text, stdout_reason = vi.read_stdout(trial_dir)
        verdict = vi.classify(stdout_text)
        if verdict.status == vi.COMPROMISED:
            note = verdict.describe()
        elif verdict.status == vi.SUSPECT:
            storms = [
                s.count for s in verdict.signals if isinstance(s, vi.RetryStorm)
            ]
            note = f"{storms[0]} retry/connection warnings"
        elif verdict.status == vi.UNREADABLE:
            note = f"stdout {stdout_reason}"
        else:
            note = ""
        rows.append({
            "resolved": resolved,
            "exception": exception,
            "verifier_timeout": verifier_timeout,
            # gh-1578 AC6: the hang's wall-clock, for verifier timeouts only.
            "hang_secs": _hang_seconds(data) if verifier_timeout else None,
            "tokens_in": agent.get("n_input_tokens") or 0,
            "tokens_out": agent.get("n_output_tokens") or 0,
            "cost": agent.get("cost_usd"),
            "estimated": metadata.get("estimated_tokens") or 0,
            "checklist": _ledger_cell(trial_dir),
            "trial": f"{job_dir.name}/{trial_dir.name}",
            "integrity": verdict,
            "integrity_note": note,
        })
    return rows


def render(splits: dict, expected=None, title=None, ledger=None, run_label=None):
    """Build the summary (lines, problems) — pure, testable.

    title: report heading (family mode, issue #1124); defaults to the
    legacy 4.0 heading. ledger: dict(dataset=, model=, fa_ref=, run_url=)
    — when set, a paste-ready per-version results-ledger row is appended
    with the real cost totals computed below (issue #1124 + #1123).
    run_label: provider+model tag (gh-1503, BENCH_RUN_LABEL env) so glm
    and kimi runs never blend in the ledger/cost views.
    """
    lines = [title or "### fa on Terminal-Bench 4.0", ""]
    problems: list[str] = []
    if run_label:
        # gh-1503: the report names the provider+model (BENCH_RUN_LABEL,
        # set by bench-harbor.yml's provider resolve step — the same
        # contract bench.yml's gh-1471 summary uses).
        lines.append(f"Provider: {run_label} (gh-1503).")
    has_jobs = any(rows for rows in splits.values())

    if not has_jobs:
        lines.append("**No harbor jobs found — the run did not complete.**")
        problems.append("no harbor jobs found")
        return lines, problems

    total_resolved = total_rows = 0
    total_attempted = 0
    total_scored = 0
    total_compromised = 0
    compromised_entries: list[str] = []
    suspect_entries: list[str] = []
    unreadable_entries: list[str] = []
    total_in = total_out = total_est = 0
    costs: list[float] = []
    unpriced = 0
    table = [
        "| split | resolved | rate | tokens in/out | est cost |",
        "|---|---|---|---|---|",
    ]
    for split, label in (("cpu", "CPU shards"), ("gpu", "GPU shards")):
        rows = splits[split]
        if not rows:
            table.append(f"| {label} | 0/0 | no trials | — | n/a |")
            continue
        # gh-1556 AC3: presence counts — every trial that produced a
        # readable result.json attempted the task; the errored subset is
        # scored separately below (it errored before a verdict).
        total_attempted += len(rows)
        scored = [r for r in rows if not r["exception"]]
        errored = len(rows) - len(scored)
        # gh-1579 integrity gate (I1): a compromised verifier run is a
        # class of its own — pulled out of the scored pool entirely
        # (neither the resolved numerator nor the clean denominator — a
        # compromised pass poisons the rate if scored, and hiding it
        # lies by omission), reported by name in its own breakdown.
        comp = [r for r in scored if _status(r) == "compromised"]
        trusted = [r for r in scored if _status(r) != "compromised"]
        resolved = sum(1 for r in trusted if r["resolved"])
        total_resolved += resolved
        total_rows += len(trusted)
        total_scored += len(scored)
        total_compromised += len(comp)
        rate = f"{resolved / len(trusted):.1%}" if trusted else None
        if errored and not comp:
            note = f"{errored} errored"
        elif comp:
            parts = ([rate] if rate else []) + [f"{len(comp)} verifier-compromised"]
            if errored:
                parts.append(f"{errored} errored")
            note = "; ".join(parts)
        else:
            note = rate or "no trials"
        split_in = sum(r["tokens_in"] for r in scored)
        split_out = sum(r["tokens_out"] for r in scored)
        split_costs = [r["cost"] for r in scored if r["cost"] is not None]
        unpriced += sum(1 for r in scored if r["tokens_in"] and r["cost"] is None)
        costs.extend(split_costs)
        total_in += split_in
        total_out += split_out
        total_est += sum(r["estimated"] for r in scored)
        cost_cell = f"${sum(split_costs):.4f}" if split_costs else "n/a"
        table.append(
            f"| {label} | {resolved}/{len(trusted)} | {note} | {split_in}/{split_out} | {cost_cell} |"
        )
        # gh-1579: per-trial integrity entries across all classes; the
        # compromised breakdown lists errored trials too (E7 — post-
        # mortems see the poisoned stdout even when scoring ignored it),
        # the unreadable flag is pass-only (I2), suspect annotates only.
        for r in rows:
            status = _status(r)
            if status == "compromised":
                compromised_entries.append(f"{r['trial']} ({r['integrity_note']})")
            elif status == "suspect":
                suspect_entries.append(f"{r['trial']} ({r['integrity_note']})")
            elif (
                status == "unreadable"
                and r["resolved"]
                and not r["exception"]
            ):
                unreadable_entries.append(f"{r['trial']} ({r['integrity_note']})")
    lines.append(f"**Resolution: {total_resolved}/{total_rows} scored trials**")
    if total_attempted != total_rows:
        bits = []
        errored_total = total_attempted - total_scored
        if errored_total:
            bits.append(
                f"{errored_total} errored before a verdict — see the errored breakdown below"
            )
        if total_compromised:
            bits.append(
                f"{total_compromised} verifier-compromised (verdict untrusted)"
                " — see the integrity breakdown below"
            )
        lines.append(
            f"**Attempted: {total_attempted} trials produced a result.json "
            f"({'; '.join(bits)})**"
        )
    if total_in or total_out:
        cost_total = f"${sum(costs):.4f}" if costs else "n/a"
        suffix = f" — {unpriced} trial(s) unpriced (model missing from pricing.json)" if unpriced else ""
        lines.append(f"**Spend: {cost_total} — tokens in/out: {total_in}/{total_out}{suffix}**")
        if total_est:
            lines.append(
                f"includes ~{total_est} estimated tokens (chars/4 where the provider omitted usage)"
            )
    lines.append("")
    lines.extend(table)

    # gh-1412: near-miss proximity — per-trial checklist coverage from the
    # hidden `task_ledger` records the FinalizeGate contract emits. Only
    # trials WITH a ledger speak here (legacy runs stay silent), and the
    # block lists the incomplete ones by name: "failed 1 of 7 checks,
    # checklist verified 6" is the diagnostic the card exists for.
    ledgered = [
        (r["trial"], r["checklist"])
        for rows in splits.values()
        for r in rows
        if r["checklist"] != "checklist: none"
    ]
    if ledgered:
        fully = sum(1 for _, cell in ledgered if " unmet" not in cell)
        lines.append("")
        lines.append(
            f"Checklist coverage (gh-1412): {fully}/{len(ledgered)}"
            " ledgered trials fully verified"
        )
        for trial, cell in sorted(ledgered):
            if " unmet" in cell:
                lines.append(f"- {trial}: {cell}")

    # gh-1578: the errored class splits by OWNER. Verifier timeouts (the
    # in-container verifier hung executing agent-authored code) are the
    # agent's zero and get their own agent-attributed line — never the
    # harness/infra bucket — with each hang's wall-clock named per-trial.
    # Every other exception keeps the legacy infra breakdown unchanged.
    # The two lines together always reconcile to the total errored count
    # (sum of per-class counts == attempted − scored) — the invariant the
    # property test pins. Exit-code semantics untouched (gh-1556): no
    # errored class reddens the job by itself.
    verifier_hangs = [
        r for rows in splits.values() for r in rows if r.get("verifier_timeout")
    ]
    exceptions: dict[str, int] = {}
    for rows in splits.values():
        for r in rows:
            # Tolerant key access (gh-1579 _status precedent): hand-built
            # rows predating the gh-1578 keys count as legacy, no KeyError.
            if r["exception"] and not r.get("verifier_timeout"):
                exceptions[r["exception"]] = exceptions.get(r["exception"], 0) + 1
    if verifier_hangs:
        per_class: dict[str, int] = {}
        for r in verifier_hangs:
            per_class[r["exception"]] = per_class.get(r["exception"], 0) + 1
        header = _VERIFIER_TIMEOUT_LINE + ": " + ", ".join(
            f"{k} ×{v}" for k, v in sorted(per_class.items())
        )
        burned = sum(
            r.get("hang_secs") for r in verifier_hangs if r.get("hang_secs") is not None
        )
        if burned:
            header += f" — ~{burned:.0f}s verifier wall-clock burned"
        lines.append("")
        lines.append(header)
        for r in sorted(verifier_hangs, key=lambda r: r["trial"]):
            detail = (
                _format_hang_secs(r.get("hang_secs"))
                if r.get("hang_secs") is not None
                else "duration unknown"
            )
            lines.append(f"- {r['trial']}: {r['exception']}, {detail}")
        lines.append(_VERIFIER_TIMEOUT_FOOTER)
    if exceptions:
        lines.append("")
        lines.append(
            "Errored trials (harness/infra failure, not scored): "
            + ", ".join(f"{k} ×{v}" for k, v in sorted(exceptions.items()))
        )
        # gh-1556 AC3: the errored class is REPORTED (breakdown line
        # above), never a verdict — its trials produced a result.json, so
        # the lost-shard guard below (presence-counted) keeps its teeth
        # only for genuinely missing trials.

    # gh-1579: the integrity-gate breakdowns, next to the errored-class
    # line (report, don't redden — none of the three lines touches the
    # exit code; only the completeness guard below can).
    if compromised_entries:
        lines.append("")
        lines.append(
            "Verifier-compromised trials (verdict untrusted, excluded from "
            "resolution): "
            + ", ".join(compromised_entries)
            + f" ×{len(compromised_entries)}"
        )
    if suspect_entries:
        lines.append("")
        lines.append(
            "Verifier-suspect trials (retry/connection storm — annotated, "
            "verdict stands): "
            + ", ".join(suspect_entries)
            + f" ×{len(suspect_entries)}"
        )
    if unreadable_entries:
        lines.append("")
        lines.append(
            "Verifier-unreadable trials (no readable verifier stdout — pass "
            "not gate-checked): "
            + ", ".join(unreadable_entries)
            + f" ×{len(unreadable_entries)}"
        )

    if expected is not None and total_attempted < expected:
        lines.append("")
        lines.append(
            f"**Incomplete run: {total_attempted}/{expected} expected trials attempted"
            " (lost or timed-out shard).**"
        )
        problems.append(f"only {total_attempted}/{expected} expected trials attempted")

    if ledger:
        rate = f"{total_resolved / total_rows:.1%}" if total_rows else "no trials"
        cost_cell = f"${sum(costs):.4f}" if costs else "n/a"
        date = datetime.now(timezone.utc).date().isoformat()
        lines += [
            "",
            "### Ledger row — append to docs/bench.md (rows are append-only)",
            "",
            "| dataset | model | fa | date | resolution | cost | run |",
            "|---|---|---|---|---|---|---|",
            f"| {ledger['dataset']} | {ledger['model']} | {ledger['fa_ref']} | {date} |"
            f" {total_resolved}/{total_rows} trials ({rate}) | {cost_cell} |"
            f" {ledger['run_url']} |",
        ]
        if total_compromised:
            # gh-1579/IT-4: the pasted row must never silently include
            # compromised trials — the caveat sits inside the paste block
            # and counts SCORED trials only: an errored-but-compromised
            # trial was already outside resolution via the errored class
            # (gh-1556) before the gate saw it, so it is listed in the
            # breakdown above without changing this caveat's pool-delta
            # claim.
            n = total_compromised
            noun = "trial" if n == 1 else "trials"
            verb = "is" if n == 1 else "are"
            lines.append("")
            lines.append(
                f"gh-1579: {n} verifier-compromised {noun} (verdict untrusted) "
                f"{verb} excluded from the resolution above — do not paste "
                "without the caveat."
            )
    return lines, problems


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("jobs_dir", type=Path)
    parser.add_argument("--expected-trials", type=int, default=None)
    parser.add_argument("--family", default=None)
    parser.add_argument("--model", default=None)
    parser.add_argument("--fa-ref", dest="fa_ref", default=None)
    parser.add_argument("--run-url", dest="run_url", default=None)
    args = parser.parse_args(argv)

    # Issue #1124: key the report to one dataset family — ignore job dirs
    # from other families so merged artifacts never cross-contaminate.
    job_dirs = [d for d in sorted(args.jobs_dir.glob("*")) if d.is_dir()]
    if args.family:
        job_dirs = [d for d in job_dirs if d.name.startswith(f"fa-{args.family}-")]

    splits: dict[str, list[dict]] = {"cpu": [], "gpu": []}
    for job_dir in job_dirs:
        name = job_dir.name
        if "-gpu-" in name:
            split = "gpu"
        elif "-cpu-" in name:
            split = "cpu"
        else:
            # legacy scheme: docker shards were CPU, modal was the GPU leg
            split = "gpu" if "modal" in name else "cpu"
        splits[split].extend(_trial_rows(job_dir))

    # Lazy: only the family path needs the manifest, and importlib-based
    # test harnesses load this module without the dir on sys.path.
    title = ledger = None
    if args.family:
        import families

        if args.family not in families.FAMILIES:
            # Defense in depth: the workflow resolves the dataset via
            # families.py before dispatch, but a direct summary call must
            # not silently render a mis-keyed report.
            print(
                f"::error::unknown Terminal-Bench family '{args.family}' —"
                f" resolve the dataset id first (families.py resolve);"
                f" known: {', '.join(sorted(families.FAMILIES))}",
                file=sys.stderr,
            )
            return 2

        title = f"### fa on Terminal-Bench {args.family} ({families.FAMILIES[args.family]})"
        ledger = {
            "dataset": families.FAMILIES[args.family],
            "model": args.model or "—",
            "fa_ref": args.fa_ref or "—",
            "run_url": args.run_url or "—",
        }

    lines, problems = render(
        splits,
        args.expected_trials,
        title=title,
        ledger=ledger,
        run_label=os.environ.get("BENCH_RUN_LABEL", "").strip() or None,
    )

    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("\n".join(lines) + "\n")
    else:
        print("\n".join(lines))

    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
