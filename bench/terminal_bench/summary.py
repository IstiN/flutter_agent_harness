#!/usr/bin/env python3
"""Accuracy summary for terminal-bench run dirs.

Usage:
    summary.py [--no-fail] <runs-dir> [expected-count] [--model MODEL_ID]

Reads every <runs-dir>/*/results.json (sharded runs pin --run-id, so one
subdir per shard) and prints a GitHub-flavoured-markdown accuracy table,
also appending it to $GITHUB_STEP_SUMMARY when set.

Token/cost columns (issue #1123): total_input/output_tokens come from the
trial's fa session records (folded in by fa_agent.py at perform_task time).
Per-trial cost is derived from the pinned price table bench/pricing.json
($/Mtok, data not code); the model id is taken from the trial's synced
session records when present, else --model (or the MODEL /
FA_PROVIDER_CONFIG env), else the cost renders n/a — never a made-up
price. Tokens estimated where a provider omitted usage (chars/4, done by
fa_agent.py) are flagged in a note when > 0.

Issue #1339: rows whose recorded totals were lost (tb's flat-cap timeout
fabrication discards the adapter's fold — gh-1209) re-fold their usage
from the synced session logs; an agent_timeout trial that did real work
after a zero-byte takeover classifies as `recovered`, distinct from
provider hang and cap exhaustion; a test_timeout trial reads as a
terminal `no (test_timeout)` in the resolved column, while other
unresolved modes render honest `pending (mode)`; and the
unpriced line names the model ids it could not price (or says the id is
unknown).

tb exits 0 even with unresolved tasks, so the exit code is the verdict on
run COMPLETENESS only. Issue #1392 AC6: a lost/cancelled shard degrades
to an explicit `coverage: X/N` note (green-with-note) — the red verdict
is reserved for real defects: nothing produced at all, or the AC8
score-honesty contradiction (an `agent_timeout` trial whose session
shows steady sub-threshold inter-record gaps, i.e. the round-2 "killed
mid-work" class the progress-aware ladder was built to retire).
--no-fail turns the verdict off (informational per-shard tallies).

Issue #1392 AC2: the report also carries request-latency p50/p95 per
concurrency level (from each trial's bench_metrics.json) and tags the
run's concurrency level (BENCH_CONCURRENCY env, set by bench.yml's
max-concurrent input).

gh-1471: the report header tags the run's provider+model
(BENCH_RUN_LABEL env, set by bench.yml's provider resolve step) so glm
and kimi runs never blend in the ledger/cost views.
"""
import glob
import json
import os
import sys
from pathlib import Path
from typing import NamedTuple

_BENCH_DIR = str(Path(__file__).resolve().parent.parent)
if _BENCH_DIR not in sys.path:
    sys.path.insert(0, _BENCH_DIR)
import bench_metrics
import fa_usage

_PRICING_PATH = Path(_BENCH_DIR) / "pricing.json"


class Row(NamedTuple):
    """One summary row.

    rec_in/rec_out: totals as recorded in results.json (0/None when tb's
    flat-cap fabrication discarded the adapter's fold). tin/tout:
    effective totals — recorded, else re-folded from the synced session
    logs (issue #1339 AC1). checklist: the gh-1412 task-ledger coverage
    cell ("checklist: V/T [ (N unmet)]" from the trial's last hidden
    `task_ledger` record, "checklist: none" when the session carries no
    ledger).
    """

    task: str
    trial: str
    mark: str
    mode: str
    rec_in: object
    rec_out: object
    tin: object
    tout: object
    cost: object
    checklist: str = "checklist: none"


def _parse_args(argv):
    """Parse [--no-fail] <runs-dir> [expected-count] [--model MODEL_ID].

    Single parse point (the reviewer's thread 6): --model without a
    non-empty value is a loud usage error, never a silent env fallback;
    a non-numeric expected-count is the same. Falls back to the MODEL /
    FA_PROVIDER_CONFIG env only when no --model was given.
    """
    no_fail = False
    model = None
    positional = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--no-fail":
            no_fail = True
        elif arg == "--model":
            if i + 1 >= len(argv) or not argv[i + 1]:
                print(
                    "[summary] error: --model requires a model id", file=sys.stderr
                )
                sys.exit(2)
            model = argv[i + 1]
            i += 1
        else:
            positional.append(arg)
        i += 1
    if not positional:
        print(
            "[summary] error: usage: summary.py [--no-fail] <runs-dir>"
            " [expected-count] [--model MODEL_ID]",
            file=sys.stderr,
        )
        sys.exit(2)
    try:
        expected = int(positional[1]) if len(positional) > 1 else None
    except ValueError:
        print(
            f"[summary] error: expected-count must be an integer, got:"
            f" {positional[1]!r}",
            file=sys.stderr,
        )
        sys.exit(2)
    if model is None:
        model = os.environ.get("MODEL")
    if model is None:
        config = os.environ.get("FA_PROVIDER_CONFIG")
        if config:
            try:
                model = json.loads(config).get("model")
            except json.JSONDecodeError:
                print(
                    "[summary] warning: FA_PROVIDER_CONFIG is not JSON — "
                    "ignoring it for the model id",
                    file=sys.stderr,
                )
    return no_fail, Path(positional[0]), expected, model


def _session_facts(runs_dir: Path) -> dict:
    """trial_name → {"model": str|None, "estimated": int,
    "input_tokens": int, "output_tokens": int} from synced sessions.

    tb ships each trial's fa sessions in the run artifacts. The glob is
    pinned to the two shipped layouts — <run>/<task>/<trial>/agent-logs/
    fah-sessions (tb sync) and <run>/<task>/<trial>/agent/fah-sessions
    (older artifact shape) — and warns loudly when a run with results has
    no session logs at all, so a layout drift can't silently zero the
    cost columns. Best-effort overall: old artifacts just yield no facts.
    """
    facts = {}
    try:
        candidates = list(runs_dir.glob("*/*/*/agent-logs/fah-sessions")) + list(
            runs_dir.glob("*/*/*/agent/fah-sessions")
        )
    except OSError:
        candidates = []
    if not candidates:
        # Only reachable when at least one results.json exists, so this is
        # a real run whose session logs went missing or drifted layout.
        print(
            f"[summary] warning: no fa session logs found "
            f"(*/*/*/agent*/fah-sessions under {runs_dir}) — per-trial model "
            f"unknown, cost renders n/a unless --model/env provides one",
            file=sys.stderr,
        )
    for sessions in candidates:
        usage = fa_usage.extract_from_dir(sessions)
        models = sorted(m for m in usage.models if m)
        facts[sessions.parent.parent.name] = {
            # One model per trial is the norm; mixed → None (cost n/a).
            "model": models[0] if len(models) == 1 else None,
            "estimated": usage.estimated_tokens,
            # Issue #1339: the fold fa_agent.py writes into results.json
            # can be discarded by tb's flat-cap timeout fabrication, so
            # keep the session-side totals for the summary's re-fold.
            "input_tokens": usage.input_tokens + usage.estimated_input_tokens,
            "output_tokens": usage.output_tokens + usage.estimated_output_tokens,
        }
    return facts


def _latency_facts(runs_dir: Path) -> dict:
    """concurrency level -> [first_byte_sec, ...] (raw per-request samples).

    Reads every trial's bench_metrics.json, consuming the keys
    bench_metrics.summarize_trial actually writes (`first_byte_sec` — the
    same writer the adapter calls from _write_trial_metrics; AC2).
    Percentiles are computed with bench_metrics.percentile, so the report
    and the per-trial `latency.first_byte` block share one semantics.
    Trials without the file (older artifacts) contribute nothing; corrupt
    files degrade to a warning, never a crash.
    """
    levels = {}
    for path in sorted(glob.glob(str(runs_dir / "*" / "*" / "*" / "bench_metrics.json"))):
        try:
            data = json.loads(Path(path).read_text())
        except (OSError, json.JSONDecodeError) as exc:
            print(
                f"[summary] warning: unreadable {path}: {exc}", file=sys.stderr
            )
            continue
        if not isinstance(data, dict):
            continue
        bucket = levels.setdefault(data.get("concurrency_level"), [])
        for req in data.get("requests") or []:
            if not isinstance(req, dict):
                continue
            value = req.get("first_byte_sec")
            if isinstance(value, (int, float)) and value >= 0:
                bucket.append(float(value))
    return levels


def _render_latency_block(runs_dir: Path, lines) -> None:
    """AC2: 'Request latency by concurrency level' block (p50/p95)."""
    levels = _latency_facts(runs_dir)
    if not levels:
        return
    lines.append("Request latency by concurrency level:")

    def label(level):
        return f"concurrency {level}" if level is not None else "concurrency default"

    for level in sorted(levels, key=lambda v: (v is None, v)):
        values = levels[level]
        if not values:
            continue
        lines.append(
            f"- {label(level)}: first-byte"
            f" p50={bench_metrics.percentile(values, 50):.1f}s"
            f" p95={bench_metrics.percentile(values, 95):.1f}s"
            f" requests={len(values)}"
        )


def _trial_dirs(runs_dir: Path) -> dict:
    """trial_name -> trial dir, from the same layout _session_facts uses."""
    dirs = {}
    for pattern in ("*/*/*/agent-logs", "*/*/*/agent", "*/*/*/fa-agent-timeout.json"):
        for path in glob.glob(str(runs_dir / pattern)):
            trial_dir = Path(path).parent
            dirs[trial_dir.name] = trial_dir
    return dirs


# gh-1576: `external_cap` is the decider's verdict when the external
# harness cap binds (the harness's own declared kill), `external_kill`
# the flush for a kill that came from outside the adapter — both name
# their killer in the audit, so neither may read as a bench-inflicted
# contradiction (a verdict missing here silently no-ops into a false
# "killed while progressing" claim — the gh-1556 lesson).
# Review round 2: `running` is the incremental checkpoint's "no verdict
# yet" — the residue a SIGKILL leaves when the final write never lands.
# It names NO bench kill, so a checkpoint-only audit can never be a
# contradiction either. Keep in lockstep with post_mortem_usage.py.
_AUDIT_JUSTIFIED = (
    "stall",
    "hard-ceiling",
    "abs_ceiling",
    "external_cap",
    "external_kill",
    "running",
)


def _trial_max_gap(trial_dir: Path):
    """Max inter-assistant-record gap across the trial's session files."""
    gaps = []
    for sessions in sorted(trial_dir.glob("agent*/fah-sessions")):
        for path in sorted(sessions.glob("*.jsonl")):
            try:
                text = path.read_text()
            except OSError:
                continue
            gaps.extend(bench_metrics.session_assistant_gaps(text))
    return max(gaps) if gaps else None


_LEDGER_VERIFIED = ("pass", "fixed")  # keep in lockstep with the Dart
# `TaskLedgerItemStatus` enum and the SIBLING copy in bench/harbor_fa/summary.py
# (the two summary scripts are standalone-by-design — different layout
# roots — so this parser is duplicated; change both together).

# gh-1646 C3: the early-exit margin — a trial that ended ≥60s before the
# effective cap had real budget left. Same value in the harbor sibling.
_EARLY_EXIT_MARGIN_SEC = 60.0


def classify_early_exit_unmet(
    clean_exit: bool,
    ledger_unmet,
    duration_secs,
    cap_secs,
    margin: float = _EARLY_EXIT_MARGIN_SEC,
):
    """gh-1646 C3: the early-exit-with-unmet-ledger verdict for one trial.

    True = "honest surrender": the trial ended on its own (no cap kill),
    its FINAL task ledger still carries unmet items, and it ended at
    least `margin` seconds before the effective cap — budget remained
    and the gate wording licensed the stop. False = not in the class
    (killed by the cap, fully verified ledger, or at/near the wall).
    None = unclassifiable — a missing ledger, duration, or cap input
    (legacy artifacts) never fabricates a classification.

    Duplicated in bench/harbor_fa/summary.py (the summary scripts are
    standalone-by-design) — change both together.
    """
    if ledger_unmet is None or duration_secs is None or cap_secs is None:
        return None
    if not clean_exit or ledger_unmet <= 0:
        return False
    return duration_secs < cap_secs - margin




def classify_clean_exit_wrong(clean_exit: bool, ledger_unmet, reward_zero):
    """gh-1652 C4: the CLEAN-WRONG verdict for one trial.

    True = the trial ended on its own (no cap kill), its FINAL task
    ledger carries ZERO unmet items (the agent believed it was done —
    it validated through its own checklist oracle: file exists, move is
    legal), and the verifier still scored reward 0 — the grader's own
    invocation was never run. False = not in the class (killed, an
    unmet ledger — that is the gh-1646 surrender class instead — or a
    nonzero reward). None = unclassifiable — a missing ledger or
    verifier-reward input (legacy artifacts) never fabricates the class.

    DISJOINT from `classify_early_exit_unmet` by construction: the two
    classes key on opposite sides of `ledger_unmet <= 0`, so a trial is
    counted once.

    Duplicated in bench/harbor_fa/summary.py (the summary scripts are
    standalone-by-design) — change both together.
    """
    if ledger_unmet is None or reward_zero is None:
        return None
    if not clean_exit or ledger_unmet > 0 or not reward_zero:
        return False
    return True
def _trial_session_texts(trial_dir: Path) -> list[str]:
    """The trial's synced fa session file texts, read ONCE per trial.

    gh-1646 review: the per-trial folds below (`_ledger_records` for the
    checklist cell AND the unmet count, `_trial_agent_duration` for the
    stamps) all walk the same `agent*/fah-sessions/*.jsonl` set — one
    read here feeds all of them instead of re-reading per fold.
    """
    texts = []
    for sessions in sorted(trial_dir.glob("agent*/fah-sessions")):
        for path in sorted(sessions.glob("*.jsonl")):
            try:
                texts.append(path.read_text())
            except OSError:
                continue
    return texts


def _ledger_records(trial_dir: Path, texts=None) -> list:
    """Every hidden `task_ledger` custom record in the trial's synced fa
    session logs, in file then line order.

    `texts` (gh-1646 review): pre-read session file texts from
    `_trial_session_texts` — render reads each trial ONCE and shares the
    texts across every fold; None (direct/test callers) reads from disk.
    """
    if texts is None:
        texts = _trial_session_texts(trial_dir)
    ledgers = []
    for text in texts:
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


def _ledger_cell(trial_dir: Path, texts=None) -> str:
    """gh-1412: the trial's checklist-coverage cell.

    The FinalizeGate contract makes the agent persist a hidden
    `task_ledger` record (requirement, verify command, expected vs actual,
    status) before its final answer; the LAST ledger wins — the agent
    re-verifies after fixes, so the final state is the near-miss
    telemetry. `pass`/`fixed` items count as verified; everything else
    (fail/unverified) is unmet. A trial with no ledger (legacy sessions,
    ledger-less tasks) renders `checklist: none`.

    Tolerates the corrupt payloads the Dart fold deliberately tolerates
    ("a corrupt ledger payload never throws"): a non-dict `data`, or an
    `items` that is not a list, degrades to `checklist: none` — never an
    AttributeError. An items-less ledger is `none` too: it verifies
    nothing, and rendering 0/0 would count as fully verified downstream.
    `texts` = pre-read session texts (gh-1646 review single-read fold).
    Duplicate of the sibling parser in bench/harbor_fa/summary.py (the
    scripts are standalone-by-design) — change both together.
    """
    ledgers = _ledger_records(trial_dir, texts)
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


def _ledger_unmet_count(trial_dir: Path, texts=None):
    """Unmet items in the trial's LAST `task_ledger` record (gh-1646 C3).

    The FinalizeGate contract's honest-surrender telemetry: the agent
    re-verifies after fixes, so the LAST ledger is the state it exited
    with. None = the session carries no parseable ledger (legacy runs,
    ledger-less tasks); an items-less ledger is None too — it verifies
    nothing, and counting 0 unmet would read as fully verified.
    Reuses the gh-1412 parse point (`_ledger_records`); `texts` = pre-read
    session texts (gh-1646 review single-read fold).
    """
    ledgers = _ledger_records(trial_dir, texts)
    if not ledgers:
        return None
    data = ledgers[-1].get("data")
    rows = data.get("items") if isinstance(data, dict) else None
    items = rows if isinstance(rows, list) else []
    if not items:
        return None
    verified = sum(
        1
        for item in items
        if isinstance(item, dict)
        and str(item.get("status") or "").lower() in _LEDGER_VERIFIED
    )
    return len(items) - verified


def _trial_agent_duration(trial_dir: Path, texts=None):
    """(last − first) fa session record timestamp, in seconds (gh-1646).

    The agent's own wall-clock from the synced session logs — the tb
    results.json rows carry no duration field. None when the trial has
    no timestamped session records. `texts` = pre-read session texts
    (gh-1646 review single-read fold).
    """
    if texts is None:
        texts = _trial_session_texts(trial_dir)
    stamps = []
    for text in texts:
        stamps.extend(bench_metrics.session_record_stamps(text))
    if not stamps:
        return None
    return max(stamps) - min(stamps)


def _audit_cap_sec(trial_dir: Path):
    """The trial's effective cap from its fa-agent-timeout.json audit
    (the gh-1576 `cap_resolution` block); None when the audit is absent
    or carries no cap (older/unsupervised runs — the trial is then
    unclassifiable, never an early exit)."""
    try:
        data = json.loads((trial_dir / "fa-agent-timeout.json").read_text())
    except (OSError, json.JSONDecodeError):
        return None
    cap = data.get("cap_resolution") if isinstance(data, dict) else None
    value = cap.get("effective_cap_sec") if isinstance(cap, dict) else None
    if isinstance(value, (int, float)) and value > 0:
        return float(value)
    return None


def _early_exit_facts(trial_dir: Path, texts=None):
    """(ledger_unmet, duration_secs, cap_secs) for the gh-1646 guard.

    Any None element leaves the trial unclassified (`classify_early_
    exit_unmet` returns None) — missing data never fabricates the class.
    Clean exit is NOT folded in here: it is a results.json fact (the
    harness's failure_mode), not a trial-dir fact. `texts` = pre-read
    session texts (gh-1646 review single-read fold).
    """
    return (
        _ledger_unmet_count(trial_dir, texts),
        _trial_agent_duration(trial_dir, texts),
        _audit_cap_sec(trial_dir),
    )


def _score_honesty(runs_dir: Path, rows) -> list:
    """AC8: agent_timeout trials killed while progressing are contradictions.

    Justified kills: the trial's fa-agent-timeout.json audit names a stall
    or ceiling outcome (round-3 adapters), or — legacy artifacts — the
    session's max inter-record gap reached the shipped stall threshold
    (bench_metrics.DEFAULT_STALL_GAP_SEC, 360s since gh-1430).
    Missing session data degrades to "unverifiable", never a contradiction.
    """
    contradictions = []
    trial_dirs = _trial_dirs(runs_dir)
    for row in rows:
        if row.mode != "agent_timeout":
            continue
        trial_dir = trial_dirs.get(row.trial)
        if trial_dir is None:
            continue
        audit = trial_dir / "fa-agent-timeout.json"
        if audit.exists():
            try:
                outcome = json.loads(audit.read_text()).get("outcome")
            except (OSError, json.JSONDecodeError):
                outcome = None
            # The audit IS the round-3 contract: the watch itself decided
            # the kill (stall at the configured gap, or a ceiling), so its
            # verdict justifies the row and the legacy gap cross-check is
            # intentionally skipped — a legitimate abs-ceiling kill has
            # sub-threshold gaps BY DESIGN (E2) and must not read as a
            # contradiction. The gap scan below remains for artifacts
            # WITHOUT an audit (round-2 runs / tb flat-cap fabrication).
            if outcome in _AUDIT_JUSTIFIED:
                continue
            contradictions.append(row.trial)
            continue
        max_gap = _trial_max_gap(trial_dir)
        if max_gap is None:
            continue  # E4: unverifiable, degrade silently
        if max_gap < bench_metrics.DEFAULT_STALL_GAP_SEC:
            contradictions.append(row.trial)
    return contradictions


def render(runs_dir: Path, expected=None, model_override=None, concurrency=None,
           run_label=None):
    """Build the summary (lines, problems) for a runs dir — pure, testable."""
    runs_dir = Path(runs_dir)
    paths = sorted(glob.glob(str(runs_dir / "*" / "results.json")))
    lines = ["### fa on terminal-bench", ""]
    problems = []
    if run_label:
        # gh-1471: the report names the provider+model (BENCH_RUN_LABEL,
        # set by bench.yml's resolve step) — glm and kimi runs must never
        # blend in the ledger/cost views.
        lines.append(f"Provider: {run_label} (gh-1471).")
    if concurrency is not None:
        # Issue #1392: the report tags the run's concurrency level — the
        # 8-shard/2-concurrent experiment is only comparable when tagged.
        lines.append(f"Run at max-concurrency {concurrency} (issue #1392).")

    if not paths:
        lines.append("**No results.json produced — the tb run did not complete.**")
        problems.append("no results.json produced")
        return lines, problems

    pricing = fa_usage.load_pricing(_PRICING_PATH)
    facts = _session_facts(runs_dir)
    trial_dirs = _trial_dirs(runs_dir)
    # gh-1646 review: read each trial's session files ONCE — the
    # checklist fold and the early-exit guard share the same texts.
    session_texts = {
        trial: _trial_session_texts(trial_dir)
        for trial, trial_dir in trial_dirs.items()
    }
    # gh-1412: per-trial checklist coverage from the synced fa sessions.
    checklist_facts = {
        trial: _ledger_cell(trial_dir, session_texts[trial])
        for trial, trial_dir in trial_dirs.items()
    }
    # gh-1646 C3: per-trial early-exit facts — (unmet, duration, cap).
    early_facts = {
        trial: _early_exit_facts(trial_dir, session_texts[trial])
        for trial, trial_dir in trial_dirs.items()
    }
    rows = []
    unpriced_models = set()
    unpriced_unknown = 0
    for p in paths:
        data = json.loads(Path(p).read_text())
        for r in data.get("results", []):
            resolved = r.get("is_resolved")
            mode = r.get("failure_mode") or ""
            # Issue #1339 AC2: a finished trial must never read as the
            # non-terminal bare `pending`. Only test_timeout speaks to a
            # verdict (the verify phase ran and burned its budget —
            # gh-1206); other None-resolved modes stay honest: pending,
            # named — not claimed as no.
            if resolved is True:
                mark = "yes"
            elif resolved is False:
                mark = "no"
            elif mode == "test_timeout":
                mark = "no (test_timeout)"
            else:
                mark = f"pending ({mode})" if mode else "pending"
            fact = facts.get(r.get("trial_name", "?")) or {}
            rec_in = r.get("total_input_tokens")
            rec_out = r.get("total_output_tokens")
            # Issue #1339 AC1: tb's flat-cap timeout fabrication discards
            # the adapter's usage fold (gh-1209) — the trial's real usage
            # then only survives in the synced fa session logs; re-fold.
            tin = rec_in if rec_in else (fact.get("input_tokens") or rec_in)
            tout = rec_out if rec_out else (fact.get("output_tokens") or rec_out)
            model = fact.get("model") or model_override
            entry = fa_usage.price_entry(pricing, model) if model else None
            cost = fa_usage.cost_usd(entry, tin or 0, tout or 0) if entry else None
            if (tin or tout) and cost is None:
                # Only rows that recorded tokens but carry no price count;
                # zero-token rows render n/a but are not unpriced spend.
                # Issue #1339 AC3: the warning names the ids (or their absence).
                if model:
                    unpriced_models.add(model)
                else:
                    unpriced_unknown += 1
            rows.append(Row(
                task=r.get("task_id", "?"), trial=r.get("trial_name", "?"),
                mark=mark, mode=mode,
                rec_in=rec_in, rec_out=rec_out, tin=tin, tout=tout, cost=cost,
                checklist=checklist_facts.get(
                    r.get("trial_name", "?"), "checklist: none"
                ),
            ))
    n_resolved = sum(1 for row in rows if row.mark == "yes")
    accuracy = n_resolved / len(rows) if rows else 0.0
    missing = expected - len(rows) if expected is not None else 0
    note = (
        f" — {expected - len(rows)} of {expected} expected tasks missing"
        " (shard lost or timed out)" if expected is not None and len(rows) < expected else ""
    )
    lines.append(
        f"**{n_resolved}/{len(rows)} resolved — accuracy {accuracy:.0%}{note}**"
    )

    # Failure families (issue #142): the re-run delta is reported per
    # cluster, not just as one accuracy number. `unset` covers both
    # resolved trials (tb's default mode) and unresolved ones whose
    # tests ran and failed — the model side.
    #
    # gh-1308 (NG2/AC3): agent_timeout rows split by recorded tokens —
    # a 0-token timeout is a provider hang (the endpoint accepted the
    # request and streamed nothing), not a trial that ran out of clock
    # doing real work. The explicit count is the provider-health
    # regression guard across bench runs.
    modes = {}
    hang = work = recovered = 0
    for row in rows:
        key = row.mode or "unset"
        if key == "agent_timeout":
            if row.rec_in or row.rec_out:
                key = "agent_timeout (real work, cap exhausted)"
                work += 1
            elif row.tin or row.tout:
                # Recorded 0/0 but the session logs carry real usage: the
                # zero-byte attempt was recovered by replay/takeover
                # (#1311) — neither a provider hang nor cap exhaustion.
                key = "agent_timeout (recovered — replay/takeover)"
                recovered += 1
            else:
                key = "agent_timeout (0 tokens — provider hang)"
                hang += 1
        modes[(key, row.mark)] = modes.get((key, row.mark), 0) + 1
    lines.append("Failure families (mode x resolved):")
    for (mode, mark), n in sorted(modes.items()):
        lines.append(f"- {mode or 'unset'} / {mark}: {n}")
    if hang or work or recovered:
        lines.append(
            f"**zero-token timeouts (provider hang): {hang}**"
            f" — agent_timeout split: {hang} with 0 tokens (provider hang),"
            f" {recovered} recovered after zero-byte takeover (usage folded"
            f" from fa session logs),"
            f" {work} with real work (cap exhausted)"
        )

    # gh-1646 C3: the early-exit-with-unmet-ledger guard — the
    # FinalizeGate contract must never read as an early-exit license.
    # A failure that ended on its own (empty failure mode — tb's default
    # for a trial that ran to its own verdict), whose FINAL task ledger
    # still carries unmet items, ending at least the margin before the
    # cap is an "honest surrender": reported per run so the class is
    # visible (and, post-wording-fix, collapsible). Denominator = scored
    # failures: `pending` rows (lost/crashed shard, no verdict) stay out
    # — the harbor sibling's scored_failures excludes its errored/
    # compromised rows, and the gh-1646 share is compared across runs.
    # Clean exit is an ALLOW-LIST (review gh-1646, conservative
    # direction): an empty failure mode only — agent_timeout kills,
    # verifier time-outs and any future mode are never clean exits.
    failures = [
        row
        for row in rows
        if row.mark != "yes" and not row.mark.startswith("pending")
    ]
    early_exits = []
    unclassified = 0
    for row in failures:
        unmet, duration, cap = early_facts.get(row.trial, (None, None, None))
        verdict = classify_early_exit_unmet(
            row.mode == "", unmet, duration, cap
        )
        if verdict is None:
            unclassified += 1
        elif verdict:
            early_exits.append((row, duration, cap))
    if failures:
        share = f"{len(early_exits) / len(failures):.0%}"
        lines.append("")
        lines.append(
            f"**early-exit-with-unmet-ledger (gh-1646): {len(early_exits)}/"
            f"{len(failures)} failures ({share})** — clean exit + unmet task"
            f" ledger + ≥{_EARLY_EXIT_MARGIN_SEC:.0f}s budget left"
        )
        for row, duration, cap in early_exits:
            lines.append(f"- {row.trial} ({duration:.0f}s/{cap:.0f}s)")
        if unclassified:
            lines.append(
                f"{unclassified} failure(s) unclassifiable — no cap,"
                " duration, or ledger data (never counted as early exits)"
            )

    # gh-1652 C4: the CLEAN-WRONG class — the mirror image of the
    # surrender guard above. The agent exited cleanly BELIEVING it was
    # done (zero-unmet ledger) and the verifier still scored reward 0:
    # it validated through its own oracle (file exists, move is legal),
    # never the grader's invocation. Disjoint from the guard above by
    # construction (ledger_unmet <= 0 vs > 0) — a trial is counted once.
    # gh-1652: denominator = every non-resolved row INCLUDING pending
    # (a pending trial is never claimed clean-wrong, but stays visible
    # in the share) — the branch's original semantics, kept for the
    # clean_exit_wrong guard only.
    all_failures = [row for row in rows if row.mark != "yes"]
    clean_wrongs = []
    clean_unclassified = 0
    for row in all_failures:
        unmet = early_facts.get(row.trial, (None, None, None))[0]
        reward_zero = True if row.mark == "no" else None
        verdict = classify_clean_exit_wrong(
            row.mode != "agent_timeout", unmet, reward_zero
        )
        if verdict is None:
            clean_unclassified += 1
        elif verdict:
            clean_wrongs.append(row)
    if all_failures:
        share = f"{len(clean_wrongs) / len(all_failures):.0%}"
        lines.append(
            f"**clean_exit_wrong (gh-1652): {len(clean_wrongs)}/"
            f"{len(all_failures)} failures ({share})** — clean exit +"
            " zero-unmet task ledger + verifier reward 0"
        )
        for row in clean_wrongs:
            lines.append(f"- {row.trial}")
        if clean_unclassified:
            lines.append(
                f"{clean_unclassified} failure(s) unclassifiable for"
                " clean_exit_wrong — no ledger or verifier-reward data"
                " (never counted)"
            )
    lines.append("")
    lines.append("")

    # Token/cost totals (issue #1123): sums over exactly the rows above.
    total_in = sum(row.tin or 0 for row in rows)
    total_out = sum(row.tout or 0 for row in rows)
    priced = [row.cost for row in rows if row.cost is not None]
    # Same unpriced rule as the harbor summary: only rows that recorded
    # tokens but carry no price count. Zero-token rows render n/a but are
    # not unpriced spend.
    unpriced = sum(
        1 for row in rows if (row.tin or row.tout) and row.cost is None
    )
    if any(row.tin or row.tout for row in rows):
        cost_total = f"${sum(priced):.4f}" if priced else "n/a"
        suffix = ""
        if unpriced:
            # Issue #1339 AC3: name the ids with no price entry; when even
            # the id is unknown, say that instead of a bare count.
            if unpriced_models and unpriced_unknown:
                detail = (
                    "no pricing.json entry for "
                    f"{', '.join(sorted(unpriced_models))} + "
                    f"{unpriced_unknown} with unknown model id"
                )
            elif unpriced_models:
                detail = (
                    f"no pricing.json entry for {', '.join(sorted(unpriced_models))}"
                )
            else:
                detail = "model id unknown (no fa session logs, no --model)"
            suffix = f" — {unpriced} trial(s) unpriced: {detail}"
        lines.append(f"**tokens in/out: {total_in}/{total_out} — est. cost: {cost_total}{suffix}**")
        estimated = sum((facts.get(row.trial) or {}).get("estimated", 0) for row in rows)
        if estimated:
            lines.append(
                f"includes ~{estimated} estimated tokens (chars/4 where the provider omitted usage)"
            )
    lines.append("| task | trial | resolved | failure mode | checklist | tokens in/out | est cost |")
    lines.append("|---|---|---|---|---|---|---|")
    for row in rows:
        tokens = (
            f"{row.tin}/{row.tout}"
            if row.tin is not None or row.tout is not None else ""
        )
        cost_cell = "n/a" if row.cost is None else f"${row.cost:.4f}"
        lines.append(
            f"| {row.task} | {row.trial} | {row.mark} | {row.mode}"
            f" | {row.checklist} | {tokens} | {cost_cell} |"
        )

    if missing > 0:
        # Issue #1392 AC6: a lost/cancelled shard is a coverage note, not
        # a failure — the report stays green-with-note so a partially
        # completed experiment still ships its data.
        lines.append(
            f"coverage: {len(rows)}/{expected}"
            f" ({missing} missing — shard lost, cancelled, or timed out)"
        )
    _render_latency_block(runs_dir, lines)
    contradictions = _score_honesty(runs_dir, rows)
    if contradictions:
        # AC8: the round-2 contradiction (agent_timeout on steady gaps)
        # must never recur silently.
        lines.append(
            f"score honesty: {len(contradictions)} contradiction(s) —"
            " agent_timeout trials whose session gaps never reached the"
            " stall threshold: " + ", ".join(sorted(contradictions))
        )
        problems.append(
            "score-honesty contradictions: " + ", ".join(sorted(contradictions))
        )
    else:
        lines.append("score honesty: 0 contradictions")
    return lines, problems


def main():
    no_fail, runs_dir, expected, model = _parse_args(sys.argv[1:])
    concurrency = None
    raw = os.environ.get("BENCH_CONCURRENCY", "").strip()
    if raw:
        try:
            concurrency = int(raw)
        except ValueError:
            print(
                f"[summary] warning: BENCH_CONCURRENCY={raw!r} is not an"
                " integer — ignoring the concurrency tag",
                file=sys.stderr,
            )
    run_label = os.environ.get("BENCH_RUN_LABEL", "").strip() or None

    lines, problems = render(runs_dir, expected, model, concurrency,
                             run_label=run_label)

    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("\n".join(lines) + "\n")
    else:
        print("\n".join(lines))

    sys.exit(0 if no_fail or not problems else 1)


if __name__ == "__main__":
    main()
