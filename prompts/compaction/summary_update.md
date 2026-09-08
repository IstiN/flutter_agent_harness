---
name: summary_update
description: Prompt for updating an existing compaction summary with new messages. Ported verbatim from pi UPDATE_SUMMARIZATION_PROMPT.
---
The messages above are NEW conversation messages to fold into the existing checkpoint provided in <previous-summary> tags.

Update the existing structured checkpoint with new information. RULES:
- PRESERVE all existing information from the previous checkpoint
- ADD new progress, decisions, and context from the new messages
- UPDATE the Progress section: move items from "In Progress" to "Done" when completed
- UPDATE "Next Steps" based on what was accomplished
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

Keep each section concise. Preserve exact file paths, function names, and error messages.
