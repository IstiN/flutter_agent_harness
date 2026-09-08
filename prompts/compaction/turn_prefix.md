---
name: turn_prefix
description: Prompt for checkpointing the prefix of a split turn during compaction. Forked from pi's TURN_PREFIX_SUMMARIZATION_PROMPT; body wording diverges deliberately (no s-word framing).
---
This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.

Checkpoint the prefix so the retained suffix stays understandable — drop nothing load-bearing:

## Original Request
[What did the user ask for in this turn?]

## Early Progress
- [Key decisions and work done in the prefix]

## Context for Suffix
- [Information needed to understand the retained recent work]

Be brief in wording, never in facts needed to understand the kept suffix.
