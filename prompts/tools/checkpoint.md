---
name: checkpoint
description: Description of the checkpoint tool that marks the current conversation state before exploratory work so a later rewind can collapse the detour into a concise report, ported from oh-my-pi's checkpoint tool prompt.
---
Creates a context checkpoint before exploratory work so you can later rewind and keep only a concise report.

Use this when you need to investigate with many intermediate tool calls (read/grep/glob/etc.) and want to minimize context cost afterward.

Rules:
- You MUST call `rewind` before finishing after starting a checkpoint.
- You NEVER call `checkpoint` while another checkpoint is active.

Typical flow:
1. `checkpoint(goal: …)`
2. Perform exploratory work
3. `rewind(report: …)` with concise findings

After rewind, intermediate checkpoint messages are removed from active context and replaced by the report. The dropped history stays in the session tree; nothing is lost.
