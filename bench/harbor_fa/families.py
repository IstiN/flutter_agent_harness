#!/usr/bin/env python3
"""Terminal-Bench family manifest for the Harbor bench surface (issue #1124).

One dispatch surface (`.github/workflows/bench-harbor.yml`) runs every live
Terminal-Bench dataset family next to the legacy 0.1.1 regression set
(`bench.yml`, tb CLI — board closed):

    family  harbor dataset id                            tasks  smoke
    ------  -------------------------------------------  -----  ------------------
    2.0     terminal-bench/terminal-bench-2@latest       89     fix-git
    2.1     terminal-bench/terminal-bench-2-1@latest     89     fix-git
    3.0     terminal-bench/terminal-bench@3.0.0          74     bun-sourcemap-leak
    4.0     terminal-bench/terminal-bench@4.0.0          66     bun-sourcemap-leak

Ids verified against the Harbor Hub registry on 2026-09-30 (issue OQ1):
harbor resolves `<org>/<name>@<ref>` through the Hub's tag table — the
`terminal-bench` package tags `4.0.0` (content v3.0.1) and `3.0.0` carry
the 4.0/3.0 datasets, while the 2.x sets live under separate package
names (`terminal-bench-2`, `terminal-bench-2-1`) whose only tag is
`latest`. `@latest` is mutable; a ledger row's run date pins it (the
resolved content hash appears in the harbor download log).

Usage (workflow setup step):

    families.py resolve DATASET

DATASET is a family label (`2.1`), a bare version (`4.0.0`, `v4`), or a
full Harbor dataset id (`terminal-bench/terminal-bench@4.0.0`). Emits
`family=` / `dataset=` / `smoke=` to $GITHUB_OUTPUT (or stdout). An
unknown, out-of-family, or version-less spec fails loudly on stderr with
a `::error::` annotation and exit 1 — never a silent fallback to 4.0.
"""
import argparse
import os
import sys

# family label -> canonical Harbor dataset id (see module docstring, OQ1).
FAMILIES = {
    "2.0": "terminal-bench/terminal-bench-2@latest",
    "2.1": "terminal-bench/terminal-bench-2-1@latest",
    "3.0": "terminal-bench/terminal-bench@3.0.0",
    "4.0": "terminal-bench/terminal-bench@4.0.0",
}

# One-task smoke per family (verified present in each dataset's task set);
# dispatch with tasks=<smoke>, attempts=1 before any full run.
SMOKE_TASKS = {
    "2.0": "fix-git",
    "2.1": "fix-git",
    "3.0": "bun-sourcemap-leak",
    "4.0": "bun-sourcemap-leak",
}

# Task count per family (Harbor Hub snapshot, 2026-09-30). Consumed by
# `resolve` (surfaces run size in the log + cost guard). The 2.x ids are
# @latest-mutable, so treat these as informational, not load-bearing;
# docs/bench.md cites them in prose.
TASK_COUNTS = {
    "2.0": 89,
    "2.1": 89,
    "3.0": 74,
    "4.0": 66,
}


class FamilyError(ValueError):
    """Dataset spec is not part of the pinned Terminal-Bench family."""


def _known_ids() -> str:
    return ", ".join(f"{k}={v}" for k, v in FAMILIES.items())


def _normalize_label(text: str) -> str:
    """'4.0.0' / 'v4.0' / '4' -> '4.0'; anything else raises FamilyError."""
    t = text.strip().lower().removeprefix("v")
    parts = t.split(".")
    if not parts or not parts[0].isdigit():
        raise FamilyError(f"'{text}' is not a Terminal-Bench family version")
    major = parts[0]
    minor = parts[1] if len(parts) > 1 and parts[1].isdigit() else "0"
    return f"{major}.{minor}"


def _sanitize(spec: str) -> str:
    """Single-line, truncated spec for embedding in error text/annotations."""
    return " ".join(str(spec).split())[:160]


def resolve(spec: str) -> tuple[str, str]:
    """Map a dataset input to (family label, canonical Harbor dataset id)."""
    s = (spec or "").strip()
    if s in FAMILIES:
        return s, FAMILIES[s]
    # Canonical ids round-trip (incl. the @latest 2.x sets): copying a run's
    # printed dataset id back into the next dispatch just works, with no
    # fallback ambiguity — it IS one of the pinned values.
    if s in FAMILIES.values():
        return next(k for k, v in FAMILIES.items() if v == s), s
    if "@" in s:
        name, _, tag = s.partition("@")
        try:
            label = _normalize_label(tag)
        except FamilyError:
            label = None
        if label and label in FAMILIES and FAMILIES[label] == s:
            return label, s
    else:
        try:
            label = _normalize_label(s)
        except FamilyError:
            label = None
        if label and label in FAMILIES:
            return label, FAMILIES[label]
    raise FamilyError(
        f"dataset spec '{_sanitize(spec)}' is not part of the pinned "
        f"Terminal-Bench family; pass a family label (2.0, 2.1, 3.0, 4.0) or "
        f"one of the exact Harbor ids: {_known_ids()}. Version-less specs "
        f"are rejected (no silent fallback to 4.0)."
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p_resolve = sub.add_parser("resolve", help="Resolve a dataset input")
    p_resolve.add_argument("dataset", help="Family label, version, or full id")
    args = parser.parse_args()

    try:
        family, dataset = resolve(args.dataset)
    except FamilyError as e:
        print(f"::error::{e}", file=sys.stderr)
        return 1

    pairs = [
        ("family", family),
        ("dataset", dataset),
        # Hub-snapshot count (see TASK_COUNTS): surfaces run size in the
        # resolve log and the cost-guard error (full run ≈ tasks × attempts).
        ("tasks", str(TASK_COUNTS[family])),
        ("smoke", SMOKE_TASKS[family]),
    ]
    # Human-readable line for the run log (machine output goes to
    # GITHUB_OUTPUT / stdout below).
    print(
        f"resolved: family={family} dataset={dataset} "
        f"tasks={TASK_COUNTS[family]} smoke={SMOKE_TASKS[family]}",
        file=sys.stderr,
    )
    target = os.environ.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a") as f:
            f.writelines(f"{k}={v}\n" for k, v in pairs)
    else:
        for k, v in pairs:
            print(f"{k}={v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
