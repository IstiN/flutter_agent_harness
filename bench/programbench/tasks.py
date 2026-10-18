#!/usr/bin/env python3
"""ProgramBench task inventory + shard split for bench-programbench.yml.

Enumerates the official task set from a pinned facebookresearch/ProgramBench
checkout (src/programbench/data/tasks/<org>__<repo>.<sha>/ — the same ids
`programbench eval` matches against <run_dir>/<iid>/), resolves the dispatch
`tasks` selector, and writes the shard matrix to $GITHUB_OUTPUT (or stdout),
the same convention as bench/harbor_fa/split_tasks.py.

Selector grammar (single `tasks` input, gh-1685):
  ''            full set (~200 instances; the workflow gates this behind
                confirm-full-run — hours of LLM spend)
  smoke         the smoke pair: the two lexicographically first ids
                (deterministic, cheap pipeline proof — AC1)
  lite          a deterministic ~20-instance stride over the sorted set
                (the "full lite-equivalent" AC2 surface)
  <fnmatch,...> comma fnmatch globs, e.g. '__cmatrix*'.* or ffmpeg__*

Output keys: matrix (JSON {include:[{i, tasks, count}]}), count, mode,
total (the FULL inventory size — the summary's dilution guard: a partial
package run's headline divides by the full set, never the selected one).

This script only reads directory names — it never touches docker or the
network, so it runs green in setup on any runner.
"""

from __future__ import annotations

import fnmatch
import json
import os
import sys
from pathlib import Path

LITE_TARGET = 20
SMOKE_SIZE = 2


def _inventory(tasks_dir: Path) -> list[str]:
    if not tasks_dir.is_dir():
        raise SystemExit(f"tasks dir not found: {tasks_dir}")
    # Task ids are the per-task dir names; one dir per instance, no nesting.
    ids = sorted(p.name for p in tasks_dir.iterdir() if p.is_dir())
    if not ids:
        raise SystemExit(f"no task instances under {tasks_dir}")
    return ids


def _select(ids: list[str], spec: str) -> tuple[list[str], str]:
    spec = (spec or "").strip()
    if spec == "":
        return ids, "full"
    if spec == "smoke":
        return ids[:SMOKE_SIZE], "smoke"
    if spec == "lite":
        stride = max(1, len(ids) // LITE_TARGET)
        return ids[::stride][:LITE_TARGET], "lite"
    globs = [g.strip() for g in spec.split(",") if g.strip()]
    picked = [i for i in ids if any(fnmatch.fnmatch(i, g) for g in globs)]
    if not picked:
        raise SystemExit(f"no ProgramBench instances match: {spec}")
    return picked, "globs"


def _chunk(tasks: list[str], shards: int) -> list[list[str]]:
    shards = max(1, min(shards, len(tasks) or 1))
    size, extra = divmod(len(tasks), shards)
    out, at = [], 0
    for i in range(shards):
        end = at + size + (1 if i < extra else 0)
        out.append(tasks[at:end])
        at = end
    return out


def _emit(pairs: list[tuple[str, str]]) -> None:
    target = os.environ.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a") as f:
            f.writelines(f"{k}={v}\n" for k, v in pairs)
    else:
        for k, v in pairs:
            print(f"{k}={v}")


def main() -> int:
    args = sys.argv[1:]
    if len(args) < 1:
        print("usage: tasks.py <tasks_dir> [--filter SPEC] [--shards N]", file=sys.stderr)
        return 2
    tasks_dir = Path(args[0])
    flt = ""
    shards = 1
    rest = args[1:]
    for i, a in enumerate(rest):
        if a == "--filter":
            flt = rest[i + 1] if i + 1 < len(rest) else ""
        elif a == "--shards":
            shards = int(rest[i + 1])
    ids = _inventory(tasks_dir)
    picked, mode = _select(ids, flt)
    include = [
        {"i": i, "tasks": " ".join(chunk), "count": len(chunk)}
        for i, chunk in enumerate(_chunk(picked, shards))
        if chunk
    ]
    _emit(
        [
            # Single-line JSON (json.dumps never emits newlines) — same
            # shape split_tasks.py writes, consumed via fromJSON().
            ("matrix", json.dumps({"include": include})),
            ("count", str(len(picked))),
            ("total", str(len(ids))),
            ("mode", mode),
        ]
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
