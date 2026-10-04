#!/usr/bin/env python3
"""Apply the gh-1199 AC6 flake quarantine to a set of test targets.

Reads candidate test paths (one per line) from stdin, or as positional
arguments, and prints the paths that STAY in the gate to stdout. Files
listed in scripts/test_quarantine.json are dropped — with a `::warning::`
per skip, so the gate log always shows what the quarantine is shielding
(E3: a quarantine must never swallow a real regression silently).

Usage (the CI legs pipe their shard selection through it):

    python3 scripts/shard_files.py scripts/test_integration_shards.json 0 \
        --tags integration --exclude browser_ext --exclude-tag llm \
      | python3 scripts/apply_quarantine.py

    find test/integration -name '*_test.dart' \
      | python3 scripts/apply_quarantine.py

    python3 scripts/apply_quarantine.py --check
        validates the quarantine list itself: entries must reference
        existing files that are tagged `integration` and carry an issue
        link — a stale or under-documented entry fails the static gate.

The list is checked in and reviewed in the fix PR; flake_watch.py
(auto-filed flake issues) proposes entries with the proving runs attached.

Pure stdlib. Exit 0 on success, 1 on a malformed list or --check failure.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shard_files import file_has_tag

LIST_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "test_quarantine.json")

REQUIRED_FIELDS = ("file", "issue", "since", "runs")


def load_quarantine(path: str = LIST_PATH) -> list:
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    entries = doc.get("quarantined")
    if not isinstance(entries, list):
        raise ValueError(f"{path}: 'quarantined' must be a list")
    return entries


def quarantined_files(entries: list) -> set:
    return {e["file"] for e in entries}


def check(path: str = LIST_PATH) -> int:
    """Validate the list; a stale/under-documented entry fails the gate."""
    ok = True
    try:
        entries = load_quarantine(path)
    except (OSError, json.JSONDecodeError, ValueError) as e:
        print(f"::error::{e}", file=sys.stderr)
        return 1
    for e in entries:
        name = e.get("file", "<missing file>")
        for field in REQUIRED_FIELDS:
            if not e.get(field):
                ok = False
                print(f"::error::quarantine entry {name}: missing '{field}' "
                      f"(every entry needs {list(REQUIRED_FIELDS)})",
                      file=sys.stderr)
        file = e.get("file")
        if file and not os.path.isfile(file):
            ok = False
            print(f"::error::quarantine entry {name}: file does not exist — "
                  f"remove the entry (fix landed) or fix the path",
                  file=sys.stderr)
        elif file and not file_has_tag(file, "integration"):
            ok = False
            print(f"::error::quarantine entry {name}: file is not tagged "
                  f"'integration' — the quarantine only shields the "
                  f"integration gate legs", file=sys.stderr)
        runs = e.get("runs") or []
        if runs and len({str(r) for r in runs}) < 2:
            ok = False
            print(f"::error::quarantine entry {name}: 'runs' must carry the "
                  f">=2 distinct proving gate runs (gh-1199 AC6/E3)",
                  file=sys.stderr)
    print(f"Quarantine list OK: {len(entries)} entr(ies), all documented")
    return 0 if ok else 1


def main() -> int:
    argv = sys.argv[1:]
    if argv == ["--check"]:
        return check()
    list_path = LIST_PATH
    if "--list" in argv:
        i = argv.index("--list")
        try:
            list_path = argv[i + 1]
        except IndexError:
            print("ERROR: --list needs a value", file=sys.stderr)
            return 2
        del argv[i:i + 2]
    try:
        entries = load_quarantine(list_path)
    except (OSError, json.JSONDecodeError, ValueError) as e:
        print(f"::error::{e}", file=sys.stderr)
        return 1
    quarantined = quarantined_files(entries)

    paths = argv if argv else [ln.strip() for ln in sys.stdin if ln.strip()]
    kept = []
    for p in paths:
        norm = p.replace(os.sep, "/")
        if norm in quarantined:
            entry = next(e for e in entries if e["file"] == norm)
            print(f"::warning::quarantined (gh-1199 AC6), skipping {norm} — "
                  f"{entry.get('issue', 'no issue link')}", file=sys.stderr)
            continue
        kept.append(p)
    for p in kept:
        print(p)
    if not kept:
        print("::warning::quarantine removed every target — the shard runs "
              "nothing this round", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
