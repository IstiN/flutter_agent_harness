#!/usr/bin/env python3
"""ProgramBench results renderer (gh-182): ledger -> README section +
the fa1.dev results page.

Usage:
    pbench_render.py [--ledger pbench_results.json] \
        [--readme README.md] [--html build/pages/root/programbench.html] \
        [--check]

Renders ONE section per surface:

  README   the marked region of README.md, right next to the
           Terminal-Bench leaderboard:

      <!-- pbench-leaderboard:begin (gh-182) -->
      ...generated...
      <!-- pbench-leaderboard:end (gh-182) -->

           inserted after the Terminal-Bench region (the gh-1682 end
           marker), falling back to before "## What's inside" and then
           to appending.

  --html   a standalone page for fa1.dev (pages.yml renders it into the
           deploy root from the COMMITTED ledger — a deploy-time
           product, never committed; gh-1476 convention).

Honesty contract (gh-182 R1): every row carries the ⭐ self-reported
marker, its mode, and its run link. Smoke rows are labeled "pipeline
proof ... not a leaderboard row" and never sort above full runs — the
full-run headline (pass@1 over the official set) always leads. Rows
link the GitHub Actions run AND the analysis artifacts (trajectories,
eval logs, _stats); the ledger itself is committed and outlives artifact
expiry, while artifact links expire with GitHub's retention window —
the renders say so, and a row without resolved artifact ids falls back
to an explicit "see the run page" link instead of a dead link.

Nothing here submits anything to the official ProgramBench registry.

Deterministic: no clock, no network — regenerating with an unchanged
ledger leaves both files byte-identical (the workflows' commit steps
rely on that). Stdlib only.
"""
import argparse
import html
import json
import sys
from pathlib import Path

import pbench_record

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
README_PATH = REPO_ROOT / "README.md"
LEDGER_PATH = pbench_record.LEDGER_PATH

MARKER_BEGIN = "<!-- pbench-leaderboard:begin (gh-182) -->"
MARKER_END = "<!-- pbench-leaderboard:end (gh-182) -->"
# fa1.dev homepage (gh-182 R2): the Benchmarks section's generated
# region. The committed source page ships the markers around an honest
# placeholder; pages.yml re-renders the block into the built deploy
# copy (--homepage). The Terminal-Bench self-reported rows come from
# the gh-1682 ledger, same proof-links discipline.
HOME_MARKER_BEGIN = "<!-- benchmarks:begin (gh-182) -->"
HOME_MARKER_END = "<!-- benchmarks:end (gh-182) -->"
FA_LEDGER_PATH = LEDGER_PATH.parent / "fa_results.json"
# Insert point when the marked region doesn't exist yet: right after the
# Terminal-Bench leaderboard block (the sections read as one board).
AFTER_ANCHOR = "<!-- leaderboard:end (gh-1682) -->"
INSERT_BEFORE_HEADING = "## What's inside"
SECTION_HEADER = "## Leaderboard: ProgramBench (fa, self-reported ⭐)"
FA_MARKER = "⭐"
UPSTREAM_REPO = "facebookresearch/ProgramBench"

# Presentation order: the headline-worthy mode leads; a smoke proof
# never renders above a full run regardless of ledger order.
MODE_RANK = {"full": 0, "lite": 1, "globs": 2, "smoke": 3}

UPSTREAM_TREE_URL = f"https://github.com/{UPSTREAM_REPO}/tree"


def mode_label(row: dict) -> str:
    attempted, total = row.get("attempted", 0), row.get("total", 0)
    span = f"{attempted} of {total}"
    if row.get("mode") == "full":
        return f"full — pass@1, all {total} instances"
    if row.get("mode") == "smoke":
        return f"smoke — pipeline proof ({span}), not a leaderboard row"
    if row.get("mode") == "lite":
        return f"lite — deterministic slice ({span})"
    return f"subset — selected globs ({span})"


def _run_id(url: str) -> str:
    return url.rstrip("/").rsplit("/", 1)[-1]


def _cell(text: str) -> str:
    """A table cell never breaks the table: pipes are escaped."""
    return text.replace("|", "\\|")


def _sorted_rows(ledger: dict) -> "list[dict]":
    rows = list(ledger.get("results") or [])
    # Three stable passes (record.py's convention): mode rank (a smoke
    # proof never leads), then newest first, then model name.
    rows.sort(key=lambda r: r.get("model", ""))
    rows.sort(key=lambda r: r.get("date") or "", reverse=True)
    rows.sort(key=lambda r: MODE_RANK.get(r.get("mode"), 9))
    return rows


def _run_links(row: dict) -> str:
    return " + ".join(
        f"[{_run_id(u)}]({u})" for u in row.get("run_urls") or []) or "—"


def _cost(v) -> str:
    return f"${v:.2f}" if isinstance(v, (int, float)) else "n/a"


def render_row_table(rows: "list[dict]") -> "list[str]":
    lines = [
        "| Model | Mode | Solved | Test-pass % | Cost | Calls | Date | fa "
        "| Run |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for r in rows:
        fa = r.get("fa_version") or "—"
        solved = r.get("solved")
        attempted = r.get("attempted", 0)
        pct = r.get("score_pct")
        pct_s = f"{pct}%" if isinstance(pct, (int, float)) else "n/a"
        solved_s = (f"{solved}/{attempted}" if isinstance(solved, int)
                    else f"—/{attempted}")
        calls = r.get("calls")
        calls_s = str(calls) if isinstance(calls, int) else "n/a"
        lines.append(
            f"| {FA_MARKER} {_cell(r.get('model', '—'))} "
            f"| {mode_label(r)} "
            f"| {solved_s} "
            f"| {pct_s} "
            f"| {_cost(r.get('cost_usd'))} "
            f"| {calls_s} "
            f"| {r.get('date', '—')} "
            f"| `{fa}` "
            f"| {_run_links(r)} |"
        )
    return lines


def _instance_cells(iid: str, e: dict) -> str:
    pct = f"{e['score_pct']}%" if isinstance(e.get("score_pct"),
                                             (int, float)) else "no score"
    tests = e.get("tests", "—")
    solved = "✅" if e.get("solved") is True else "—"
    cost = _cost(e.get("cost_usd")) if "cost_usd" in e else "—"
    calls = str(e["calls"]) if isinstance(e.get("calls"), int) else "—"
    return (f"| {_cell(iid)} | {pct} | {tests} | {solved} | {cost} "
            f"| {calls} |")


def render_detail_blocks(rows: "list[dict]") -> "list[str]":
    """One collapsible per-row detail: instances + task-set + artifacts."""
    blocks: "list[str]" = []
    for r in rows:
        lines = [
            "<details>",
            f"<summary>Per-instance detail — {_cell(r.get('model', '—'))}"
            f" · {mode_label(r)} · {r.get('date', '—')}</summary>",
            "",
            "| Instance | Test-pass % | Tests | Solved | Cost | Calls |",
            "|---|---|---|---|---|---|",
        ]
        for iid, e in sorted((r.get("instances") or {}).items()):
            lines.append(_instance_cells(iid, e))
        lines.append("")
        ref = r.get("taskset_ref", "")
        lines.append(
            f"Task set: [{UPSTREAM_REPO}@{ref}]({UPSTREAM_TREE_URL}/{ref})"
            f" · programbench {r.get('pbench_version', '—')}")
        links = [f"[{a['label']}]({a['url']})"
                 for a in r.get("artifact_urls") or [] if a.get("url")]
        if links:
            # The submission artifact carries the whole run dir:
            # trajectories (fa session logs), eval logs, _stats. The
            # artifact itself expires on GitHub's retention schedule —
            # say so (gh-182 review); the run link stays.
            lines.append("Artifacts: " + " · ".join(links)
                         + " — the submission artifact holds the run "
                           "dir: trajectories, eval logs, _stats. "
                           "(Artifact links expire with GitHub's "
                           "retention window; the run page stays.)")
        else:
            for u in r.get("run_urls") or []:
                lines.append(f"Artifacts: see the [run page]({u}) — the "
                             "run's artifacts (trajectories, eval logs) "
                             "ride it.")
        lines.append("")
        lines.append("</details>")
        blocks.append("\n".join(lines))
    return blocks


def render_section(ledger: dict) -> str:
    rows = _sorted_rows(ledger)
    lines = [
        SECTION_HEADER,
        "",
        f"fa's results on [{UPSTREAM_REPO}]"
        f"(https://github.com/{UPSTREAM_REPO}) — rebuild a complete "
        "codebase from a compiled binary + its docs. Pass@1: one attempt "
        "per instance — the **Solved** column (solved/attempted) is the "
        "pass@1 fraction the official board ranks by; **Test-pass %** is "
        "the mean share of scored tests that passed per instance "
        "(a 100% test-pass row can still fail an instance). Measured by "
        f"our own `bench-programbench` runs. Rows marked {FA_MARKER} are "
        "**self-reported** and never auto-submitted to the official "
        "ProgramBench registry (that stays a manual owner decision). "
        "Smoke rows are pipeline proofs, not leaderboard rows. Every row "
        "links its run; the per-instance detail carries the analysis "
        "artifacts (trajectories, eval logs).",
        "",
    ]
    if rows:
        lines += render_row_table(rows)
        lines.append("")
        lines += render_detail_blocks(rows)
    else:
        lines.append("*No ProgramBench results recorded yet — the ledger "
                     "(`bench/leaderboard/pbench_results.json`) fills on "
                     "the first green `bench-programbench` run.*")
    lines.append("")
    lines.append("<sub>Source: "
                 "`bench/leaderboard/pbench_results.json`, rendered by "
                 "`bench/leaderboard/pbench_render.py` (gh-182).</sub>")
    return "\n".join(lines) + "\n"


def splice_readme(text: str, section: str) -> str:
    """Replace the marked region (or insert after the gh-1682 block).

    Raises ValueError on an orphaned begin marker — the generated
    region is corrupt (merge-conflict remnant), and appending a second
    block would dual-section the README (gh-182 review).
    """
    begin = text.find(MARKER_BEGIN)
    end = text.find(MARKER_END)
    block = f"{MARKER_BEGIN}\n{section}{MARKER_END}\n"
    if begin >= 0 and (end < 0 or end < begin):
        raise ValueError(
            "orphaned pbench-leaderboard:begin marker — the generated "
            "region is corrupt (the end marker is missing or precedes "
            "it); remove the stale block and re-run")
    if begin >= 0 and end > begin:
        # Consume only a single newline right after the end marker —
        # never the character(s) that follow when the marker sits at
        # EOF without its trailing newline (gh-182 review).
        after = end + len(MARKER_END)
        tail = (text[after + 1:] if text[after:after + 1] == "\n"
                else text[after:])
        return text[:begin] + block + tail
    anchor = text.find(AFTER_ANCHOR)
    if anchor >= 0:
        anchor_end = text.find("\n", anchor)
        if anchor_end >= 0:
            return (text[:anchor_end + 1] + "\n" + block
                    + text[anchor_end + 1:])
        return text + "\n\n" + block
    heading = text.find(INSERT_BEFORE_HEADING)
    if heading < 0:
        return text.rstrip() + "\n\n" + block
    return text[:heading] + block + "\n" + text[heading:]


def render_homepage(ledger: dict, fa_ledger) -> str:
    """The fa1.dev homepage Benchmarks section body (gh-182 R2).

    The ticket: "a `Benchmarks` section (nav link included), rendered
    from the committed snapshot(s) — result rows where every number
    links to its proof". ProgramBench rows come from the gh-182 ledger,
    Terminal-Bench self-reported rows from the gh-1682 ledger (where
    snapshots exist). Site-styled: reuses the page's .matrix table; the
    deploy splice fills the marked region in the built index.html —
    the source page keeps an honest placeholder between the markers.
    Deterministic, stdlib only.
    """
    rows = _sorted_rows(ledger)
    fa_rows = sorted(
        list((fa_ledger or {}).get("results") or []),
        key=lambda r: -(r.get("resolved", 0) / r.get("total", 1) or 0))
    if not rows and not fa_rows:
        return ("*No benchmark results recorded yet — the committed "
                "ledgers (`bench/leaderboard/pbench_results.json`, "
                "`bench/leaderboard/fa_results.json`) fill on green CI "
                "runs.*")

    def esc(text) -> str:
        return html.escape(str(text), quote=True)

    def run_link(url: str) -> str:
        return (f'<a href="{esc(url)}">run {esc(_run_id(url))}</a>')

    def run_links(row: dict) -> str:
        return " · ".join(run_link(u) for u in row.get("run_urls") or [])

    def metric(value: str, url) -> str:
        if not url:
            return esc(value)
        return f'<a href="{esc(url)}">{esc(value)}</a>'

    def artifact_links(row: dict) -> "list[str]":
        return [f'<a href="{esc(a["url"])}">'
                f'{esc(a.get("label") or "artifacts")}</a>'
                for a in row.get("artifact_urls") or [] if a.get("url")]

    parts: "list[str]" = []
    if rows:
        parts += ["<h3>ProgramBench — rebuild the codebase "
                  "(self-reported ⭐)</h3>",
                  "",
                  '<div class="matrix-wrap">',
                  '<table class="matrix bench-matrix">',
                  "  <thead><tr><th>Benchmark</th><th>Model</th>"
                  "<th>Mode</th><th>Solved</th><th>Test-pass %</th>"
                  "<th>Date</th><th>Proof</th></tr></thead>",
                  "  <tbody>"]
        for r in rows:
            first = (r.get("run_urls") or [None])[0]
            attempted, solved = r.get("attempted", 0), r.get("solved", 0)
            pct = r.get("score_pct")
            proof = artifact_links(r) + [run_links(r)] if run_links(r) \
                else artifact_links(r)
            ref = r.get("taskset_ref", "")
            bench = (f'<a href="{UPSTREAM_TREE_URL}/{esc(ref)}">'
                     f"ProgramBench@{esc(ref)}</a>") if ref else "ProgramBench"
            parts.append(
                "  <tr>"
                f"<td>{bench}</td>"
                f"<td>⭐ {esc(r.get('model', '—'))}</td>"
                f"<td>{esc(mode_label(r))}</td>"
                f"<td>{metric(f'{solved}/{attempted}', first)}</td>"
                f"<td>{metric(f'{pct}%' if pct is not None else '—', first)}</td>"
                f"<td>{esc(r.get('date', '—'))}</td>"
                f"<td>{' · '.join(proof) or '—'}</td></tr>")
        parts += ["  </tbody>", "</table>", "</div>", ""]
    if fa_rows:
        parts += ["<h3>Terminal-Bench (self-reported ⭐)</h3>",
                  "",
                  '<div class="matrix-wrap">',
                  '<table class="matrix bench-matrix">',
                  "  <thead><tr><th>Bench</th><th>Model</th>"
                  "<th>Accuracy</th><th>Trials</th><th>Date</th>"
                  "<th>fa</th><th>Runs</th></tr></thead>",
                  "  <tbody>"]
        for r in fa_rows:
            first = (r.get("run_urls") or [None])[0]
            resolved, total = r.get("resolved", 0), r.get("total", 0)
            acc = (f"{100.0 * resolved / total:.1f}%" if total else "n/a")
            fa = r.get("fa_version") or "—"
            parts.append(
                "  <tr>"
                f"<td>TB {esc(r.get('dataset_version', ''))}</td>"
                f"<td>⭐ {esc(r.get('model', '—'))}</td>"
                f"<td>{metric(acc, first)}</td>"
                f"<td>{metric(f'{resolved}/{total}', first)}</td>"
                f"<td>{esc(r.get('date', '—'))}</td>"
                f"<td><code>{esc(fa)}</code></td>"
                f"<td>{run_links(r) or '—'}</td></tr>")
        parts += ["  </tbody>", "</table>", "</div>", ""]
    else:
        parts += ["<p><em>No Terminal-Bench snapshots recorded yet — "
                  "`bench/leaderboard/fa_results.json` fills via "
                  "`bench-harbor` runs.</em></p>", ""]
    parts.append(
        "<sub>Every number links its proof — the GitHub Actions run and "
        "the analysis artifacts. Artifact links expire with GitHub's "
        "retention window; the run pages stay. Self-reported ⭐: never "
        'auto-submitted to the official boards. Per-instance detail: '
        '<a href="./programbench.html">full ProgramBench results</a>.'
        "</sub>")
    return "\n".join(parts) + "\n"


def splice_homepage(text: str, block: str) -> str:
    """Replace the homepage Benchmarks marked region.

    The region is committed in site/index.html — a missing or corrupt
    region is a loud ValueError (main turns it into the clean exit-2
    path): the deploy step must never ship a page whose board silently
    vanished, and it must never append a second section.
    """
    begin = text.find(HOME_MARKER_BEGIN)
    end = text.find(HOME_MARKER_END)
    if begin < 0 or end < 0 or end < begin:
        raise ValueError(
            "benchmarks markers missing or corrupt — expected a "
            "<!-- benchmarks:begin (gh-182) --> … <!-- benchmarks:end "
            "(gh-182) --> region in the homepage")
    after = end + len(HOME_MARKER_END)
    tail = (text[after + 1:] if text[after:after + 1] == "\n"
            else text[after:])
    return (text[:begin] + f"{HOME_MARKER_BEGIN}\n{block}"
            + f"{HOME_MARKER_END}" + tail)


_PAGE_STYLE = """
    body { font-family: -apple-system, 'Segoe UI', Roboto, sans-serif;
           margin: 2rem auto; max-width: 68rem; padding: 0 1rem;
           background: #0d1117; color: #e6edf3; }
    a { color: #58a6ff; }
    table { border-collapse: collapse; margin: 1rem 0; font-size: 0.92rem; }
    th, td { border: 1px solid #30363d; padding: 0.35rem 0.6rem;
             text-align: left; }
    th { background: #161b22; }
    sub, summary { color: #8b949e; }
    details { margin: 0.6rem 0 0.6rem 1rem; }
    code { background: #161b22; padding: 0.1rem 0.3rem;
           border-radius: 4px; }
"""


def render_html(ledger: dict) -> str:
    """The fa1.dev page — the same block, standalone HTML."""
    rows = _sorted_rows(ledger)

    def e(text) -> str:
        return html.escape(str(text))

    parts = [
        "<!doctype html>",
        '<html lang="en">',
        "<head>",
        '<meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, '
        'initial-scale=1">',
        "<title>ProgramBench results — Fa (flutter_agent_harness)</title>",
        '<meta name="description" content="Fa\'s self-reported '
        'ProgramBench results: score, tests, cost and calls per '
        'instance, with run and artifact links.">',
        f"<style>{_PAGE_STYLE}</style>",
        "</head>",
        "<body>",
        "<main>",
        "<h1>ProgramBench — Fa results "
        f"({e(FA_MARKER)} self-reported)</h1>",
        f"<p>Fa's results on <a href=\"https://github.com/{UPSTREAM_REPO}\">"
        f"{e(UPSTREAM_REPO)}</a> — rebuild a complete codebase from a "
        "compiled binary + its docs. Pass@1: one attempt per instance — "
        "the Solved column (solved/attempted) is the pass@1 fraction the "
        "official board ranks by; Test-pass % is the mean share of "
        "scored tests that passed per instance. Measured by our own "
        "<code>bench-programbench</code> runs. Every "
        "row is self-reported and never auto-submitted to the official "
        "registry; smoke rows are pipeline proofs, not leaderboard rows. "
        "Each row links its run and the analysis artifacts (trajectories, "
        "eval logs).</p>",
    ]
    if rows:
        parts.append("<table>")
        parts.append("<tr><th>Model</th><th>Mode</th><th>Solved</th>"
                     "<th>Test-pass %</th><th>Cost</th><th>Calls</th>"
                     "<th>Date</th>"
                     "<th>fa</th><th>Run</th></tr>")
        for r in rows:
            fa = r.get("fa_version") or "—"
            runs = " + ".join(
                f'<a href="{html.escape(u)}">{e(_run_id(u))}</a>'
                for u in r.get("run_urls") or []) or "—"
            pct = r.get("score_pct")
            pct_s = (f"{pct}%" if isinstance(pct, (int, float)) else "n/a")
            solved = r.get("solved")
            solved_s = (f"{e(solved)}/{e(r.get('attempted', 0))}"
                        if isinstance(solved, int)
                        else f"—/{e(r.get('attempted', 0))}")
            calls = r.get("calls")
            calls_s = str(calls) if isinstance(calls, int) else "n/a"
            parts.append(
                f"<tr><td>{e(FA_MARKER)} {e(r.get('model', '—'))}</td>"
                f"<td>{e(mode_label(r))}</td>"
                f"<td>{solved_s}</td>"
                f"<td>{e(pct_s)}</td>"
                f"<td>{e(_cost(r.get('cost_usd')))}</td>"
                f"<td>{e(calls_s)}</td>"
                f"<td>{e(r.get('date', '—'))}</td>"
                f"<td><code>{e(fa)}</code></td>"
                f"<td>{runs}</td></tr>")
        parts.append("</table>")
        for r in rows:
            parts.append("<details>")
            parts.append(
                f"<summary>Per-instance detail — {e(r.get('model', '—'))}"
                f" · {e(mode_label(r))} · {e(r.get('date', '—'))}</summary>")
            parts.append("<table>")
            parts.append("<tr><th>Instance</th><th>Test-pass %</th>"
                         "<th>Tests</th>"
                         "<th>Solved</th><th>Cost</th><th>Calls</th></tr>")
            for iid, entry in sorted((r.get("instances") or {}).items()):
                pct = (f"{entry['score_pct']}%"
                       if isinstance(entry.get("score_pct"), (int, float))
                       else "no score")
                tests = entry.get("tests", "—")
                solved = "✅" if entry.get("solved") is True else "—"
                cost = (_cost(entry["cost_usd"])
                        if isinstance(entry.get("cost_usd"), (int, float))
                        else "—")
                calls = (str(entry["calls"])
                         if isinstance(entry.get("calls"), int) else "—")
                parts.append(
                    f"<tr><td>{e(iid)}</td><td>{e(pct)}</td>"
                    f"<td>{e(tests)}</td><td>{solved}</td>"
                    f"<td>{e(cost)}</td><td>{e(calls)}</td></tr>")
            parts.append("</table>")
            ref = r.get("taskset_ref", "")
            parts.append(
                f'<p>Task set: <a href="{UPSTREAM_TREE_URL}/{e(ref)}">'
                f"{e(UPSTREAM_REPO)}@{e(ref)}</a> · programbench "
                f"{e(r.get('pbench_version', '—'))}</p>")
            # gh-182 review: emit the run-page fallback when NO artifact
            # link actually rendered — the Markdown condition — not when
            # artifact_urls merely exists (a url-less hand-edited entry
            # would otherwise leave the page linkless AND fallbackless).
            artifact_links = 0
            for a in r.get("artifact_urls") or []:
                if a.get("url"):
                    artifact_links += 1
                    parts.append(
                        f'<p>Artifacts: <a href="{html.escape(a["url"])}">'
                        f'{e(a["label"])}</a> — the submission artifact '
                        "holds the run dir: trajectories, eval logs, "
                        "_stats. (Artifact links expire with GitHub's "
                        "retention window.)</p>")
            if not artifact_links:
                for u in r.get("run_urls") or []:
                    parts.append(
                        f'<p>Artifacts: see the <a href="{html.escape(u)}">'
                        "run page</a> — the run's artifacts (trajectories, "
                        "eval logs) ride it.</p>")
            parts.append("</details>")
    else:
        parts.append("<p>No ProgramBench results recorded yet — the "
                     "ledger fills on the first green "
                     "<code>bench-programbench</code> run.</p>")
    parts.append(
        "<p><sub>Source: <code>bench/leaderboard/"
        "pbench_results.json</code>, rendered by "
        "<code>bench/leaderboard/pbench_render.py</code> (gh-182) — "
        'deploy-time product of <a href="https://fa1.dev">fa1.dev</a>.</sub></p>')
    parts.append("</main>")
    parts.append("</body>")
    parts.append("</html>")
    return "\n".join(parts) + "\n"


def _write_if_changed(path: Path, text: str) -> bool:
    if path.exists() and path.read_text() == text:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return True


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", type=Path, default=LEDGER_PATH)
    parser.add_argument("--readme", type=Path, default=None,
                        help="README to splice the section into (opt-in — "
                             "a bare run renders nothing)")
    parser.add_argument("--html", type=Path, default=None,
                        help="write the standalone fa1.dev page here")
    parser.add_argument("--homepage", type=Path, default=None,
                        help="splice the Benchmarks section (gh-182 R2) "
                             "into this page's <!-- benchmarks:begin/end "
                             "(gh-182) --> region (opt-in)")
    parser.add_argument("--fa-ledger", type=Path, default=FA_LEDGER_PATH,
                        help="Terminal-Bench self-reported ledger for the "
                             "homepage section (a missing file renders the "
                             "explicit no-snapshots note)")
    parser.add_argument("--check", action="store_true",
                        help="exit 1 if any target would change (CI "
                             "hygiene) — writes nothing")
    args = parser.parse_args(argv)

    if not args.readme and not args.html and not args.homepage:
        parser.print_usage(sys.stderr)
        print("error: nothing to render — pass --readme and/or --html "
              "and/or --homepage",
              file=sys.stderr)
        return 2

    ledger = pbench_record.load_ledger(args.ledger)
    stale = False
    if args.readme:
        section = render_section(ledger)
        old = args.readme.read_text() if args.readme.exists() else ""
        try:
            new = splice_readme(old, section)
        except ValueError as exc:
            # Corrupt generated region (orphaned marker) — a clean
            # exit-2, never a duplicated section written behind the
            # caller's back.
            print(f"error: {exc}", file=sys.stderr)
            return 2
        if new != old:
            stale = True
            if not args.check:
                args.readme.write_text(new)
                print(f"pbench-leaderboard: updated {args.readme}")
    if args.html:
        page = render_html(ledger)
        if args.check:
            stale = stale or not (args.html.exists()
                                  and args.html.read_text() == page)
        elif _write_if_changed(args.html, page):
            stale = True
            print(f"pbench-leaderboard: wrote {args.html}")
    if args.homepage:
        # gh-182 R2: the homepage Benchmarks section — ProgramBench rows
        # plus the Terminal-Bench self-reported snapshots, every number
        # linked to its proof. Missing markers are a loud exit-2 (the
        # deploy page must not silently lose its board), mirroring the
        # README splice's corrupt-region handling.
        fa = None
        if args.fa_ledger is not None and args.fa_ledger.is_file():
            fa = json.loads(args.fa_ledger.read_text())
        block = render_homepage(ledger, fa)
        old = args.homepage.read_text() if args.homepage.exists() else ""
        try:
            new = splice_homepage(old, block)
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        if new != old:
            stale = True
            if not args.check:
                args.homepage.write_text(new)
                print(f"pbench-leaderboard: updated {args.homepage}")
    if stale and args.check:
        print("pbench-leaderboard: outputs are stale — run "
              "bench/leaderboard/pbench_render.py", file=sys.stderr)
        return 1
    if not stale:
        print("pbench-leaderboard: already up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
