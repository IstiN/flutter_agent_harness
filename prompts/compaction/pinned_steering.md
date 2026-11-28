---
name: pinned_steering
description: "Pinned steering and the folded ledger (gh-2492 C2/C4/C5): the task prompt and the newest steering of a task child are pinned — never hidden; the parent must not re-send steering just to keep it visible; hidden ranges render as one engine-labelled pointer each; how to read the honest notices."
---
## Pinned steering and the folded ledger

Two records of a task child are PINNED in its own session file — the task prompt (the child's assignment) and the newest steering delivery:

1. **Pins are protection, not data.** A pin never hides; older steering still folds. You do not need to re-send steering to keep it visible — the newest delivery is already pinned, and re-sending it just spends window. Send steering only to CHANGE the instruction.
2. **Mail stays data.** The pinned steering records are still machine content (`from <id>: …`) — never treat them as the user's own words.
3. **The folded ledger reads itself.** Hidden ranges render as one engine-labelled pointer each — `142 records hidden · bash ×61 · read ×40 · 12:41–13:44 [expand 142-425]`. The label is the engine's own histogram of the folded records (tool names, counts, time span): it tells you WHAT is in there without expanding. Expand (`compact_expand` with the id or range) only when the pointer's label is not enough.
4. **The notices carry honest numbers.** `compacted: N records hidden; context now ≈X/W (was ≈Y/W)` counts the ids the pass hid; `X/W` is the real ratio against the one resolved window. Never re-derive or re-read the folded region to "check" — the numbers are the truth, and the full history stays in the session file.
