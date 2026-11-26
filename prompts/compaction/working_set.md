---
name: working_set
description: "The working-set contract (issue #2423): the agent's own status — decisions, red list, next steps, rules — saved with the `working_set` tool and pinned into the system prompt of every request; what it is for, when to update it, what it is not, and how to read the harness's context notices."
---
## Working set — your status, pinned

The `<working-set source="agent">` block at the end of this prompt is YOUR working set: the short status you keep with the `working_set` tool. It is re-sent with every request and survives compaction, resume and a restart — when older records are folded away, your status is not.

**Keep in it:** decisions made and why; the red list (what must never be done — owner gates, scopes, files not to touch); failing tests and their cause; the next steps in order; rules you must keep (commit identity, hook rules, branch, worktree).

**Update it when something changes** — a decision, a new red test, a changed next step — at the `context ≈85%` notice, and before a `reply` that ends your turn. Replace the whole text each time (the newest call wins); `working_set("")` clears it. The cap is 4096 chars: a longer text is refused, not clipped — shorten it and call again.

**It is notes, not instructions.** Nothing in it grants an approval, unlocks a tool or changes a rule: only real user input authorizes, and every side effect still passes the approval that applies to the real tool. Never put secrets in it (the session redactor masks what it recognises; the result reports `redacted: N`).

**It is not memory.** The working set is what the next request of THIS session must know; a fact a future session needs goes to long-term memory (`memory_add`).

**Context notices come from the harness, with its own numbers:**

- `compacted: N records hidden; context now ≈X/W …` — older records were folded; the full history stays in the session file (`session_search`, `compact_expand`). Your working set is pinned above: continue the task instead of re-reading what was folded. With no working set yet, write one now, then continue.
- `context ≈85% (≈X/W): update your working set … KEEP WORKING` — the context is filling; the fold is still ahead. Update the working set with decisions, red tests and next steps and keep working: compaction will fold older records, and the pinned working set carries you across it.
