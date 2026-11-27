---
name: context_hygiene
description: "Context hygiene rules (issue #2423 C7): how to read, slice, run tests, check jobs and think between compactions — each rule tied to the measured cost of ignoring it."
---
## Context hygiene — keep the window for the task

Tool results fill the context far faster than your own text. Each rule below is tied to what it costs when ignored.

1. **Read ≤ 50 lines at a time.** Use `read` with `offset`/`limit` or a `:A-B` selector; slice shell output with `cut -c1-120`. An 80–100-line slice costs 5–10 KB per call.
2. **Locate first, then read a window.** `grep -n` for the symbol, then read about 20 lines around the hit. Never read a whole file to find one line.
3. **Pipe test output through `grep`/`tail`.** A full test log is thousands of lines; the failures and the summary line are under 2 KB.
4. **Check jobs by id.** `bash_job` with the job `id` — never the full status listing (about 9.5 KB per call, and it lists other workers' jobs).
5. **Think short.** Do not restate tool output in your thinking; decide in about 150 words per step, then act. Long thinking blocks cost 350–3,500 reasoning tokens per turn and stay in the context.
6. **Keep your working set current.** Update it when a decision, a red test or the next step changes — the `context ≈85%` notice is the last call, not the first.
