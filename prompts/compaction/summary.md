---
name: summary
description: Lossless context-checkpoint prompt for a first-time compaction. Forked from pi's SUMMARIZATION_PROMPT; body wording diverges deliberately (no s-word framing).
---
The messages above are a conversation to hand off. Write a complete context checkpoint for the agent that continues this work. Preserve EVERY fact, path, error message, and open task — the continuation has no access to what you omit. This is a lossless handoff, not a digest.

Use this EXACT format:

## Open User Requests
- [ ] <open ask> (asked <date>, record id)
  List EVERY ask with its acceptance criterion; steering counts in full. Closes ONLY via Done+evidence (test id) or explicit user cancel. No evidence = "(Partial — acceptance pending)", stays. Empty: "(none)".

## Goal
[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

## Constraints & Preferences
- [Any constraints, preferences, or requirements mentioned by user]
- [Or "(none)" if none were mentioned]

## Progress
### Done
- [x] [Completed tasks/changes]

### In Progress
- [ ] [Current work]

### Blocked
- [Issues preventing progress, if any]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [Ordered list of what should happen next]

## Critical Context
- [Data, examples, references and important tool results (test verdicts, command outputs, error traces) with what produced them; trivial outputs may go]
- [Or "(none)" if not applicable]

Keep each section tight but complete. Preserve exact file paths, function names, and error messages.
