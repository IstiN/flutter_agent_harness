---
name: branch_summary
description: Structured summary instructions for the branch abandoned during session-tree navigation, ported verbatim from oh-my-pi's branch-summary compaction prompt.
---
You MUST create a structured checkpoint of the conversation branch for context when returning.

You MUST use EXACT format:

## Goal

[What is the user trying to accomplish in this branch?]

## Constraints & Preferences
- [Constraints, preferences, requirements mentioned]
- [(none) if none mentioned]

## Progress

### Done
- [x] [Completed tasks/changes]

### In Progress
- [ ] [Work started but not finished]

### Blocked
- [Issues preventing progress]

## Observed State
- [Only what is directly witnessed: tool verdicts, command outputs, events — each with what produced it]
- [(none) if nothing was directly observed]

## Interpreted State
- [What you inferred from the observations — each line names the observation it rests on; no direct observation = "unverified — re-verify"]
- [(none) if nothing was interpreted]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [What should happen next to continue]

Sections stay tight but complete. You MUST preserve exact file paths, function names, error messages. Important tool results (test verdicts, command outputs, error traces, fetched data) are preserved with what produced them; trivial outputs may go. An uncertainty qualifier ("may", "suspect", "unconfirmed") stays verbatim with its claim — never detach or upgrade a hedge; claims without a direct observation are tagged [assumed] or [hearsay: source], never laundered into Observed State.

Timeless content only: this checkpoint is a durable fact sheet re-read on every later turn. NEVER record ephemeral, second-person, or time-scoped statements ("your last tool call's result was dropped", "you just ran X") — harness notes about dropped or trimmed context are one-time delivery events, not facts; record only the durable outcome. Durable uses of temporal words ("the last release was v1.0.492") are fine.
