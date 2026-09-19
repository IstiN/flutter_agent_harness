**Resolved** — and this round the resolution was committed from a clean workspace, so it sticks (see the round-2 re-post on `input/gh-671/ticket.json` for the root cause).

State at HEAD:

- Both nested stash-conflict blocks removed from `input/gh-671/ticket.json`, `input/gh-671/ticket.md`, and `input/ticket.md` — the most complete version (full `## Machine jobs` list) kept in each.
- `python3 -c "import json; json.load(...)"` → parses (3 job entries).
- `git diff --check` → clean; `git grep -e '<<<<<<<' -e '>>>>>>>' HEAD` → no hits.
