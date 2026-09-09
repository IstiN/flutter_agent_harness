---
name: summary_update
description: Prompt for folding new messages into an existing compaction checkpoint. Forked from pi's UPDATE_SUMMARIZATION_PROMPT; body wording diverges deliberately (no s-word framing).
---
The messages above are NEW conversation messages to fold into the existing checkpoint provided in <previous-checkpoint> tags.

Update the existing structured checkpoint with new information. RULES:
- PRESERVE all existing information from the previous checkpoint
- ASSESS tool results: important outputs (test verdicts, command results, error traces) go into the checkpoint; trivial banners may go
- PRESERVE exact file paths, function names, and error messages
- If something is no longer relevant, you may remove it

Use this EXACT format:

## Open User Requests
- [ ] <keep every open ask>
  Here "no longer relevant" NEVER removes; ONLY explicit user cancel or Done+evidence. No evidence = "(Partial — acceptance pending)", stays.

## Goal
[Preserve existing goals, add new ones if the task expanded]

## Constraints & Preferences
- [Preserve existing, add new ones discovered]

## Progress
### Done
- [x] [Include previously done items AND newly completed items]

### In Progress
- [ ] [Current work - update based on progress]

### Blocked
- [Current blockers - remove if resolved]

## Key Decisions
- **[Decision]**: [Brief rationale] (preserve all previous, add new)

## Next Steps
1. [Update based on current state]

## Critical Context
- [Preserve important context, add new if needed]

Keep each section tight but complete. Preserve exact file paths, function names, and error messages.
