# Memory usage (moved from AGENTS.md)

> Moved verbatim from `AGENTS.md` (gh-2181 — the slim-AGENTS.md card). Canonical reference; the slim AGENTS.md carries the one-line summary and points here.

## Memory is part of the system prompt

Before starting any non-trivial task, **search memory first** to pick up
durable facts the user has accumulated across sessions — preferences,
gotchas, conventions, prior decisions. Cheap to query, often the
difference between re-deriving a rule and silently violating it:

- `memory_search <topic>` for keyword search across both scopes
  (project = this repo, committed; user = global, private). Read the
  top results before acting.
- `memory_list` to skim recent entries when the topic is fuzzy or the
  user asks "what do you know about X".
- Project-scope notes under `memory/note/` are **the user's** — read
  freely, write only via `memory_add` (which goes through the package's
  policy: durable facts, supersede via delete+add, never leave solved
  problems to rot).
- User-scope notes are global across projects — facts about the user,
  their environment, their habits. Always relevant.

Common things memory already covers for this repo: worktree placement,
shared-checkout rules, agent messaging fabric, known fragile files,
prior false-blame incidents. If the task touches one of those, search
before you start.

