#!/usr/bin/env python3
"""Leaderboard renderer: merge official rows + fa self-reported rows into
the README table (gh-1682).

Usage:
    render.py [--version 2.1]... [--top 15] [--offline] [--readme README.md]

Renders one subsection per dataset version into the marked region of
README.md:

    <!-- leaderboard:begin -->
    ...generated...
    <!-- leaderboard:end -->

Honesty contract (gh-1682 AC2): official rows and fa rows live in
SEPARATE tables under separate headers — fa rows carry a ⭐ marker, the
"self-reported, not on the official leaderboard" label, and a footnote
with run date, fa version, dataset version, and the GitHub run link(s).
They are never sorted into or styled like official rows.

Official rows come from fetch.py (Harbor Hub API -> tbench.ai page-JSON
fallback). `--offline` reads the committed snapshots instead — the
snapshots keep README regeneration reproducible and let the auto-update
step degrade to the last captured board instead of failing when the hub
is unreachable. A version with no official rows and no snapshot renders
an explicit "no official rows" note — never an empty table that could
read as an empty field.

Regenerating with unchanged inputs leaves README.md untouched (the
workflow's commit step relies on that for idempotency).

Stdlib only.
"""
import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

import fetch
import record

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
README_PATH = REPO_ROOT / "README.md"
SNAPSHOT_DIR = HERE / "snapshots"

MARKER_BEGIN = "<!-- leaderboard:begin (gh-1682) -->"
MARKER_END = "<!-- leaderboard:end (gh-1682) -->"
INSERT_BEFORE_HEADING = "## What's inside"
# README section header lives inside the marked region, so removing the
# markers removes the whole section.
SECTION_HEADER = "## Leaderboard: fa vs. the field"
FA_MARKER = "⭐"

DEFAULT_OFFICIAL_VERSIONS = ("4.0",)


def pct(part: int, total: int) -> str:
    return f"{100.0 * part / total:.1f}%" if total else "n/a"


def _link(label: str, url: str) -> str:
    return f"[{label}]({url})" if url else label


def _run_link(url: str) -> str:
    """A GitHub Actions run URL renders by its run id (the stable,
    auditable handle) — full URLs in every cell would drown the table."""
    run_id = url.rstrip("/").rsplit("/", 1)[-1]
    return _link(run_id, url)


def render_official_table(doc: dict, top: int) -> "list[str]":
    rows = doc.get("rows") or []
    shown = rows[:top]
    lines = [
        "| # | Agent | Model | Accuracy | Trials | Date |",
        "|---|---|---|---|---|---|",
    ]
    for i, r in enumerate(shown, 1):
        lines.append(
            "| {rank} | {agent} | {model} | {acc} | {n} | {date} |".format(
                rank=r.get("rank") or i,
                agent=_link(r["agent"], r.get("agent_url")) or "—",
                model=_link(r["model"], r.get("model_url")) or "—",
                acc=pct_1(r.get("accuracy")),
                n=r.get("n_trials") or "—",
                date=r.get("date") or "—",
            )
        )
    fetched = (doc.get("fetched_at") or "")[:10]
    note = (
        f"Official rows: Harbor Hub leaderboard "
        f"`{doc.get('package')}/{doc.get('leaderboard')}` — "
        f"backing [tbench.ai](https://www.tbench.ai/)"
    )
    if len(rows) > len(shown):
        note += f", top {len(shown)} of {len(rows)}"
    if fetched:
        note += f", fetched {fetched}"
    lines.append("")
    lines.append(f"<sub>{note}.</sub>")
    return lines


def pct_1(accuracy) -> str:
    """Hub accuracy is a 0-100 percentage; render one decimal."""
    if accuracy is None:
        return "n/a"
    return f"{float(accuracy):.1f}%"


def render_fa_table(rows: "list[dict]", version: str) -> "list[str]":
    lines = [
        "| Model | Accuracy | Trials | Date | fa | Runs |",
        "|---|---|---|---|---|---|",
    ]
    for r in rows:
        runs = " + ".join(_run_link(u) for u in r.get("run_urls") or []) or "—"
        fa = r.get("fa_version") or "—"
        lines.append(
            f"| {FA_MARKER} {r.get('model', '—')} "
            f"| {pct(r.get('resolved', 0), r.get('total', 0))} "
            f"| {r.get('resolved', '—')}/{r.get('total', '—')} "
            f"| {r.get('date', '—')} "
            f"| `{fa}` "
            f"| {runs} |"
        )
    lines.append("")
    lines.append(
        f"<sub>{FA_MARKER} Self-reported: measured by our own "
        f"`bench-harbor` runs on Terminal-Bench {version}, **not** an "
        "official leaderboard submission (community submissions are "
        "closed — #1681). Every row links its GitHub Actions run(s); fa "
        "rows never blend into the official table above. Source: "
        "`bench/leaderboard/fa_results.json`.</sub>"
    )
    return lines


def render_version_section(version: str, official: dict,
                           fa_rows: "list[dict]", top: int,
                           offline_note: bool) -> str:
    title = (official or {}).get("title") or f"Terminal-Bench {version}"
    lines = [f"### {title} (official)", ""]
    if official and official.get("rows"):
        lines += render_official_table(official, top)
    else:
        source = "committed snapshot" if offline_note else "live fetch"
        lines += [
            f"*No official leaderboard rows for Terminal-Bench {version} "
            f"right now ({source} returned none — the board may not exist "
            "yet or the hub may be unreachable). See the fa self-reported "
            "rows below and [tbench.ai](https://www.tbench.ai/).*",
        ]
    if fa_rows:
        lines += [
            "",
            f"#### fa on Terminal-Bench {version} — self-reported "
            f"{FA_MARKER} (not on the official leaderboard)",
            "",
        ] + render_fa_table(fa_rows, version)
    return "\n".join(lines)


def render_section(versions: "list[str]", official_by_version: "dict[str, dict]",
                   ledger: dict, top: int, offline_notes: "set[str]") -> str:
    fa_by_version = {}
    for row in ledger.get("results") or []:
        fa_by_version.setdefault(row.get("dataset_version"), []).append(row)
    for rows in fa_by_version.values():
        rows.sort(key=lambda r: -(r.get("resolved", 0) / r.get("total", 1) or 0))

    now = datetime.now(timezone.utc).date().isoformat()
    parts = [
        SECTION_HEADER,
        "",
        "fa's own Terminal-Bench results next to the official field. "
        "Official rows are read from the Harbor Hub leaderboard that "
        "backs [tbench.ai](https://www.tbench.ai/); rows marked "
        f"{FA_MARKER} are **self-reported** — measured by our own "
        "bench-harbor runs, not submitted to the official board.",
        "",
        f"<sub>Regenerated {now} by "
        "`bench/leaderboard/render.py` (gh-1682).</sub>",
        "",
    ]
    for version in versions:
        parts.append(
            render_version_section(
                version, official_by_version.get(version),
                fa_by_version.get(version, []), top,
                version in offline_notes,
            )
        )
        parts.append("")
    return "\n".join(parts).rstrip() + "\n"


def splice_readme(text: str, section: str) -> str:
    """Replace the marked region (or insert before the anchor heading)."""
    begin = text.find(MARKER_BEGIN)
    end = text.find(MARKER_END)
    block = f"{MARKER_BEGIN}\n{section}{MARKER_END}\n"
    if begin >= 0 and end > begin:
        return text[:begin] + block + text[end + len(MARKER_END) + 1:]
    anchor = text.find(INSERT_BEFORE_HEADING)
    if anchor < 0:
        return text.rstrip() + "\n\n" + block
    return text[:anchor] + block + "\n" + text[anchor:]


def _write_snapshot(version: str, doc: dict) -> None:
    """Refresh the committed snapshot after a successful live fetch.

    `fetched_at` is preserved when the board itself is unchanged, so a
    refresh with identical rows stays byte-identical — the workflow's
    commit step only picks up real changes.
    """
    import json

    snap = SNAPSHOT_DIR / f"{version}.json"
    new = dict(doc)
    if snap.exists():
        try:
            old = json.loads(snap.read_text())
        except json.JSONDecodeError:
            old = None
        if (
            isinstance(old, dict)
            and old.get("rows") == doc.get("rows")
            and old.get("leaderboard") == doc.get("leaderboard")
        ):
            new["fetched_at"] = old.get("fetched_at")
    text = json.dumps(new, indent=2) + "\n"
    if not snap.exists() or snap.read_text() != text:
        snap.parent.mkdir(parents=True, exist_ok=True)
        snap.write_text(text)


def _official_for_version(version: str, offline: bool) -> "tuple[dict | None, bool]":
    """-> (fetch doc or None, used_snapshot). None = no rows available."""
    import json

    if offline:
        snap = SNAPSHOT_DIR / f"{version}.json"
        if snap.exists():
            return json.loads(snap.read_text()), True
        return None, True
    try:
        doc = fetch.fetch_official(version)
        _write_snapshot(version, doc)
        return doc, False
    except Exception as exc:  # hub down / board gone — degrade to snapshot
        snap = SNAPSHOT_DIR / f"{version}.json"
        if snap.exists():
            print(
                f"::warning::live fetch for {version} failed "
                f"({exc}); using committed snapshot",
                file=sys.stderr,
            )
            return json.loads(snap.read_text()), True
        print(
            f"::warning::live fetch for {version} failed ({exc}); "
            "no snapshot — rendering an explicit no-rows note",
            file=sys.stderr,
        )
        return None, False


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", dest="versions", action="append",
                        help="dataset version (repeatable; default: 4.0 "
                             "plus every version in the fa ledger)")
    parser.add_argument("--top", type=int, default=15,
                        help="official rows shown per version (default 15)")
    parser.add_argument("--offline", action="store_true",
                        help="read committed snapshots instead of fetching")
    parser.add_argument("--readme", type=Path, default=README_PATH)
    parser.add_argument("--ledger", type=Path, default=record.LEDGER_PATH)
    parser.add_argument("--check", action="store_true",
                        help="exit 1 if the README would change (CI hygiene)")
    args = parser.parse_args(argv)

    ledger = record.load_ledger(args.ledger)
    versions = args.versions or list(
        dict.fromkeys(
            list(DEFAULT_OFFICIAL_VERSIONS)
            + sorted({r["dataset_version"] for r in ledger["results"]},
                     reverse=True)
        )
    )

    official = {}
    offline_notes = set()
    for version in versions:
        doc, used_snapshot = _official_for_version(version, args.offline)
        official[version] = doc
        if used_snapshot:
            offline_notes.add(version)

    section = render_section(versions, official, ledger, args.top,
                             offline_notes)
    old = args.readme.read_text() if args.readme.exists() else ""
    new = splice_readme(old, section)
    if new == old:
        print("leaderboard: README already up to date")
        return 0
    if args.check:
        print("leaderboard: README is stale — run bench/leaderboard/render.py",
              file=sys.stderr)
        return 1
    args.readme.write_text(new)
    print(f"leaderboard: updated {args.readme}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
