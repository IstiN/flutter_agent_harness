**Both halves addressed.**

**1. Source workspace resolved and committed.** The nested stash-conflict blocks are gone from `input/gh-671/ticket.json`, `input/gh-671/ticket.md`, and `input/ticket.md` (the most complete `## Machine jobs` version kept in each). Verified in this workspace:

- `python3 -c "import json; json.load(open('input/gh-671/ticket.json'))"` → parses.
- `git diff --check` → clean; a repo-wide grep for conflict-marker glyphs on the resolved tree → no hits.
- The resolution is staged from a **conflict-free** workspace — the next auto-save commits the resolution, not the markers (the round-2 regression happened because the *review* workspace still carried the unmerged merge, and its auto-save `git add -A`-ed the broken content over the fix from `5842d86d`).

**2. Auto-save path filter.** Confirmed factory-side: `grep -rn "WIP auto-save" lib/ bin/` over this repository's source finds nothing — the auto-save is the factory pipeline that wraps these jobs, not code in this PR. Requested behavior for it: before staging, refuse conflicted state — e.g.

```bash
test -z "$(git ls-files -u)" || { echo "auto-save: unmerged paths present, refusing"; exit 1; }
```

plus skipping any file whose staged content starts with a conflict-marker line (seven `<` characters, or the matching `>` terminator). Until that ships, every round risks the ping-pong; this round's resolution is committed from a clean workspace so it sticks for this branch.
