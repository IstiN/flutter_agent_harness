---
name: user_read_instruction
description: Instruction riding a user message whose verbatim text was spilled to a file (issue #1760) — tells the model the request was too large for the context window and must be read in parts with the read tool before acting.
---
The user request is too long for the context window and was written to `{{path}}` ({{bytes}} bytes).

Read it in parts with the read tool (offset/limit/ranges selectors) until you fully understand the request, then act on it.
