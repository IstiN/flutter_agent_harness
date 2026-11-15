#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  AGENTS.md SIZE CEILING — gh-2181. DO NOT RAISE WITHOUT TEAM APPROVAL      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# AGENTS.md is the agent ENTRY document: the harness carries it into the
# system prompt with a ~19 KB entry budget, so anything past that is
# invisible to agents in practice (gh-2181 measured the pre-slim file at
# 146405 B / 2201 lines — ~75% of it silently disabled its own tail).
#
# Ceiling: <= 300 lines AND <= 20480 bytes (20 KB). Comparison is <=
# (at-cap passes) — this is a documented divergence from
# scripts/check_changelog_size.sh, whose pub.dev cap is a strict
# less-than. Regrowth fix: move essays into docs/ (index:
# docs/README.md); the slim file stays a map + invariants + pointers.
#
# Callers (keep both wired — test/agents_md_size_guard_test.dart asserts
# the wiring):
#   - scripts/ci_fast_gate.sh stage_analyze — pre-commit hook path; runs
#     on docs/*.md commits, the exact commits that regrow the file;
#   - .github/workflows/ci.yml `static` job — whole-tree authority when
#     hooks are skipped (--no-verify).
#
# Usage: check_agents_md_size.sh [file] [max_lines] [max_bytes]
#   file       defaults to AGENTS.md;
#   max_lines  defaults to 300;
#   max_bytes  defaults to 20480 — overrides exist for tests.
#
# Exit 0 = within both ceilings. Exit 1 = missing file or over either
# ceiling, with a ::error:: annotation naming the fix.
set -euo pipefail

file="${1:-AGENTS.md}"
max_lines="${2:-300}"
max_bytes="${3:-20480}"

if [ ! -f "$file" ]; then
  echo "::error::check_agents_md_size.sh: $file does not exist — the agent entry document is missing."
  exit 1
fi

lines=$(wc -l < "$file")
bytes=$(wc -c < "$file")

if [ "$lines" -gt "$max_lines" ] || [ "$bytes" -gt "$max_bytes" ]; then
  echo "::error::$file is $lines lines / $bytes bytes — ceiling is <= ${max_lines} lines and <= ${max_bytes} bytes (gh-2181: the harness entry budget is ~19 KB, a larger file silently disables its own tail). Move the essays into docs/ (index: docs/README.md) and keep AGENTS.md a map + invariants + pointers."
  exit 1
fi
echo "$file: $lines lines / $bytes bytes <= ${max_lines}x${max_bytes} ceiling — ok"
