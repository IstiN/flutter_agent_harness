---
name: structured_checkpoint
description: Instruction tail for the structured-compaction checkpoint LLM call (pass 2). The checkpoint text must list every covered expand id and carry open user requests verbatim (issue #148, anti-#81 pin).
---
Write a checkpoint of the conversation above. It replaces a range of
records in the agent's context, so it must let the agent continue the work
without the replaced records.

Rules:
- Start with a `covers:` line listing EXACTLY the expand ids given in the
  `<covers>` block, verbatim, comma-separated. Every replaced segment must
  stay reachable through that line — never drop an id.
- If an `<open-user-requests>` block is present, carry each listed request
  VERBATIM at the top of the checkpoint, under a `open asks:` heading.
- Keep decisions, conclusions, final answers, error causes, and file paths
  the agent still needs. Preserve important tool outputs (test verdicts,
  command results, error traces) with what produced them.
- Keep it dense prose or tight bullets; no preamble, no restating these
  instructions.
