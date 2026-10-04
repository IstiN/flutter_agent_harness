---
name: turn_prefix
description: Prompt for checkpointing the prefix of a split turn during compaction. Forked from pi's TURN_PREFIX_SUMMARIZATION_PROMPT; body wording diverges deliberately (no s-word framing).
---
This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.

Checkpoint the prefix so the retained suffix stays understandable. Preserve every fact, path, error message, open request, and important tool results (test verdicts, command outputs, error traces) — the kept suffix has no other source for them. This is a lossless handoff, not a digest. Keep uncertainty qualifiers attached to their claims ("may", "suspect", "unconfirmed" stay verbatim — never state a hedged claim as fact), and keep each conclusion's evidence line or an "unverified — re-verify" marker. Timeless content only: never record ephemeral, second-person, or time-scoped statements ("your last tool call's result was dropped", "you just ran X") — harness notes about dropped or trimmed context are one-time delivery events, not facts; record only the durable outcome:

## Original Request
[What did the user ask for in this turn?]

## Early Progress
- [Key decisions and work done in the prefix]

## Context for Suffix
- [Information needed to understand the retained recent work]

Stay tight in wording, never in the facts the kept suffix depends on.
