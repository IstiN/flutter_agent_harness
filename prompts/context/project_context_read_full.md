---
name: project_context_read_full
description: >-
  Appended after a truncated project-context excerpt (AGENTS.md/CLAUDE.md and
  friends over the merged byte budget): points the model at the full file on
  disk and requires reading it in parts before acting on project-specific
  rules. Issue #1761 — parity with the oversized-user-message wording.
---
The full version of this file is on disk. You MUST read it with the read tool (in parts: offset/limit/ranges) before acting on project-specific rules — the excerpt above may cut off mid-section.
