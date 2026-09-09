---
name: summary_update
description: Prompt for folding new messages into an existing compaction checkpoint. Forked from pi's UPDATE_SUMMARIZATION_PROMPT; body wording diverges deliberately (no s-word framing).
---
The messages above are NEW conversation messages to fold into the existing checkpoint provided in <previous-checkpoint> tags.

Update the existing structured checkpoint with new information. RULES:
- PRESERVE all existing information from the previous checkpoint
- ADD new progress, decisions, and context from the new messages
- UPDATE Progress: move "In Progress" items to "Done" when completed; update "Next Steps"
- ASSESS tool results: keep important outputs (verdicts, command results, errors); trivial banners may go
- PRESERVE exact paths, names, and errors
- If something is no longer relevant, you may remove it

Use this EXACT format:

## Open User Requests
- [ ] <keep every open ask>
  Here "no longer relevant" NEVER removes; ONLY explicit user cancel or Done+evidence. No evidence = "(Partial — acceptance pending)", stays.

## Goal
[Goals — preserve, add if the task expanded]

## Constraints & Preferences
- [Constraints — preserve, add new]

## Progress
### Done
- [x] [Previously done + newly completed]

### In Progress
- [ ] [Current work]

### Blocked
- [Blockers — remove if resolved]

## Key Decisions
- **[Decision]**: [Rationale] (preserve all, add new)

## Next Steps
1. [Refresh the next steps]

## Critical Context
- [Important context — preserve, add new]

Keep each section tight but complete.
