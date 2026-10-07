#!/usr/bin/env python3
"""Post-mortem pass over a tb run dir (issue #1392 AC4/AC7, E4/E6).

When a trial ends — ANY reason — its token spend must land in
results.json. tb's flat-cap timeout fabrication discards the adapter's
usage fold (gh-1209), so the costliest rows (the killed ones) recorded
0/0; attribution depended on graceful stream shutdown. This pass re-owns
attribution after the fact:

- every trial row whose recorded totals are 0/missing gets them summed
  from the exported fa session JSONL (deduped by record id, so a
  pre-kill + takeover file pair never double-counts — E6);
- corrupt or missing session files degrade to `tokens: null` + a
  warning, never a crash (E4);
- rows that recorded real totals (graceful trials) are never touched —
  live accounting stays the source of truth (AC4);
- ExportGuard: the adapter writes export-guard.json per trial (session
  records seen vs files exported); a trial with a session but an empty
  export yields a loud warning row naming it (AC7).

aggregate_latency() folds the per-trial bench_metrics.json files into the
per-run p50/p95 latency the run report prints per concurrency level (AC2).

Run: python3 bench/post_mortem_usage.py <runs-dir>   (after tb run,
before summary.py; also importable — pure functions over the run dir).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

_BENCH_DIR = Path(__file__).resolve().parent
if str(_BENCH_DIR) not in sys.path:
    sys.path.insert(0, str(_BENCH_DIR))

import bench_metrics
import fa_usage

# Outcomes where fa cannot have produced a session — the same set the
# adapter skips its usage fold for (gh-1209).
_NEVER_STARTED_MODES = frozenset(
    {"agent_installation_failed", "unknown_agent_error"}
)

# The two shipped session-log layouts under a trial dir (summary.py's
# _session_facts pins the same pair).
_SESSION_LAYOUTS = ("agent-logs/fah-sessions", "agent/fah-sessions")


def trial_session_dirs(run_dir, task_id, trial_name):
    """Existing fa-session dirs for one trial (either shipped layout)."""
    base = Path(run_dir) / str(task_id) / str(trial_name)
    found = []
    for layout in _SESSION_LAYOUTS:
        candidate = base / layout
        if candidate.is_dir():
            found.append(candidate)
    return found


def _dedup_session_text(session_dirs):
    """Concatenated session lines, deduped by record id (E6).

    A replay/takeover trial ships two session files whose overlapping
    turns re-record the same assistant records under the same ids; usage
    must be counted once per record, not once per file.
    """
    seen_ids = set()
    lines = []
    for sessions in session_dirs:
        for path in sorted(sessions.glob("*.jsonl")):
            try:
                text = path.read_text(errors="replace")
            except OSError as exc:
                print(
                    f"[post-mortem] warning: unreadable session file "
                    f"{path}: {exc}",
                    file=sys.stderr,
                )
                continue
            for line in text.splitlines():
                if not line.strip():
                    continue
                rid = None
                try:
                    record = json.loads(line)
                    if isinstance(record, dict):
                        rid = record.get("id")
                except json.JSONDecodeError:
                    pass
                if rid is not None:
                    if rid in seen_ids:
                        continue
                    seen_ids.add(rid)
                lines.append(line)
    return "\n".join(lines)


def _fold_row(row, session_dirs):
    """(input, output, warning) for one row from its session files.

    (None, None, warning) means the session files exist but say nothing
    usable — tokens: null, the E4 degradation.
    """
    text = _dedup_session_text(session_dirs)
    if not text.strip():
        return None, None, "session files present but empty/unreadable"
    try:
        usage = fa_usage.extract_from_text(text)
    except Exception as exc:  # noqa: BLE001 — E4: degrade, never crash
        return None, None, f"session usage extraction failed ({exc})"
    if not (usage.input_tokens or usage.output_tokens
            or usage.estimated_input_tokens or usage.estimated_output_tokens):
        # Nothing usable parsed (corrupt lines only, E4): tokens: null.
        return None, None, "no usable usage records in the session files"
    if usage.warnings:
        print(
            f"[post-mortem] warning: {row.get('trial_name')}: "
            f"{usage.warnings[0]}",
            file=sys.stderr,
        )
    return (
        usage.input_tokens + usage.estimated_input_tokens,
        usage.output_tokens + usage.estimated_output_tokens,
        None,
    )


def _export_guard(trial_dir, row):
    """ExportGuard gap row (AC7) for one trial, or None.

    Primary signal: the adapter's export-guard.json (session records seen
    at trial end vs files actually exported). Fallback: a never-started
    trial is expected to have no logs; anything else with zero session
    files in BOTH layouts is a gap.
    """
    trial_dir = Path(trial_dir)
    guard_path = trial_dir / "export-guard.json"
    if guard_path.is_file():
        try:
            guard = json.loads(guard_path.read_text())
        except (json.JSONDecodeError, OSError):
            guard = None
        if isinstance(guard, dict):
            records = guard.get("session_records") or 0
            files = guard.get("export_files") or 0
            if records and not files:
                return {
                    "trial": guard.get("trial") or row.get("trial_name"),
                    "session_records": records,
                    "export_files": files,
                }
            return None
    mode = (row.get("failure_mode") or "").lower()
    if mode in _NEVER_STARTED_MODES:
        return None
    if row.get("total_input_tokens") or row.get("total_output_tokens"):
        return None
    if not trial_session_dirs(trial_dir.parent, row.get("task_id"),
                              row.get("trial_name")):
        return {
            "trial": row.get("trial_name"),
            "session_records": None,
            "export_files": 0,
        }
    return None


def post_mortem(runs_dir, stall_gap_sec=240.0):
    """Fold session usage into every results.json under <runs_dir>.

    Returns the report dict: patched rows, warnings, export gaps, and the
    AC8 score-honesty violations (agent_timeout verdicts on trials whose
    sessions show only steady sub-threshold gaps — the round-2
    contradiction that can never again pass silently).
    """
    runs_dir = Path(runs_dir)
    report = {"patched": [], "warnings": [], "export_gaps": [],
              "honesty_violations": []}
    for results_path in sorted(runs_dir.glob("*/*/results.json")) + sorted(
        runs_dir.glob("*/results.json")
    ):
        run_dir = results_path.parent
        try:
            data = json.loads(results_path.read_text())
        except (json.JSONDecodeError, OSError) as exc:
            report["warnings"].append(
                f"unreadable {results_path}: {exc}"
            )
            continue
        changed = False
        for row in data.get("results", []):
            task_id = row.get("task_id")
            trial_name = row.get("trial_name")
            trial_dir = run_dir / str(task_id) / str(trial_name)
            gap = _export_guard(trial_dir, row)
            if gap:
                report["export_gaps"].append(gap)
            recorded_in = row.get("total_input_tokens")
            recorded_out = row.get("total_output_tokens")
            has_totals = bool(recorded_in or recorded_out)
            mode = (row.get("failure_mode") or "").lower()
            session_dirs = trial_session_dirs(run_dir, task_id, trial_name)
            if has_totals or mode in _NEVER_STARTED_MODES:
                if session_dirs:
                    # AC8 cross-check on rows that recorded spend.
                    text = _dedup_session_text(session_dirs)
                    max_gap = bench_metrics.max_session_gap(text)
                    if bench_metrics.score_honesty_violation(
                        mode, max_gap, stall_gap_sec
                    ):
                        report["honesty_violations"].append(
                            {
                                "trial": trial_name,
                                "failure_mode": mode,
                                "max_gap_sec": max_gap,
                            }
                        )
                continue
            if not session_dirs:
                continue
            tin, tout, warning = _fold_row(row, session_dirs)
            if warning:
                row["total_input_tokens"] = None
                row["total_output_tokens"] = None
                report["warnings"].append(
                    f"{trial_name}: {warning} (tokens: null)"
                )
            else:
                row["total_input_tokens"] = tin
                row["total_output_tokens"] = tout
                report["patched"].append(
                    {"trial": trial_name, "input": tin, "output": tout}
                )
            changed = True
        if changed:
            results_path.write_text(json.dumps(data, indent=2))
    return report


def aggregate_latency(runs_dir):
    """Per-run p50/p95 latency over the trial bench_metrics.json files.

    One concurrency level per run (the report tags it, AC2): the aggregate
    pools the per-trial figures — percentile over the p50 list for p50,
    over the p95 list for p95, max of maxes, n summed.
    """
    runs_dir = Path(runs_dir)
    per_run = {}
    for metrics_path in sorted(runs_dir.glob("*/*/*/bench_metrics.json")):
        run_dir = metrics_path.parents[2]
        try:
            metrics = json.loads(metrics_path.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        entry = per_run.setdefault(
            run_dir.name, {"run_id": run_dir.name, "concurrency_level": None,
                           "p50s": [], "p95s": [], "maxes": [], "n": 0,
                           "watchdog_events": 0, "trials": 0}
        )
        latency = (metrics.get("latency") or {}).get("first_byte") or {}
        if isinstance(latency, dict) and latency.get("n"):
            entry["p50s"].append(latency.get("p50"))
            entry["p95s"].append(latency.get("p95"))
            entry["maxes"].append(latency.get("max"))
            entry["n"] += latency.get("n") or 0
        level = metrics.get("concurrency_level")
        if entry["concurrency_level"] is None and level is not None:
            entry["concurrency_level"] = level
        entry["watchdog_events"] += len(metrics.get("watchdog_events") or [])
        entry["trials"] += 1
    report = []
    for name in sorted(per_run):
        entry = per_run[name]
        report.append(
            {
                "run_id": entry["run_id"],
                "concurrency_level": entry["concurrency_level"],
                "latency": {
                    "first_byte": (
                        None
                        if not entry["n"]
                        else {
                            "p50": bench_metrics.percentile(entry["p50s"], 50),
                            "p95": bench_metrics.percentile(entry["p95s"], 95),
                            "max": max(m for m in entry["maxes"] if m is not None),
                            "n": entry["n"],
                        }
                    )
                },
                "watchdog_events": entry["watchdog_events"],
                "trials": entry["trials"],
            }
        )
    return report


def main(argv):
    if len(argv) != 2:
        print("usage: post_mortem_usage.py <runs-dir>", file=sys.stderr)
        return 2
    report = post_mortem(argv[1])
    print(
        f"post-mortem: {len(report['patched'])} row(s) re-attributed, "
        f"{len(report['warnings'])} warning(s), "
        f"{len(report['export_gaps'])} export gap(s), "
        f"{len(report['honesty_violations'])} score-honesty violation(s)"
    )
    for warning in report["warnings"]:
        print(f"[post-mortem] warning: {warning}", file=sys.stderr)
    for gap in report["export_gaps"]:
        print(
            f"[post-mortem] EXPORT GAP: trial {gap['trial']} had "
            f"{gap.get('session_records')} session record(s) but the export "
            f"produced {gap.get('export_files')} file(s)",
            file=sys.stderr,
        )
    for violation in report["honesty_violations"]:
        print(
            f"[post-mortem] SCORE HONESTY VIOLATION: {violation['trial']} "
            f"failed {violation['failure_mode']} but its session shows only "
            f"steady gaps (max {violation['max_gap_sec']}s < 240s) — "
            "the run killed a productive agent",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
