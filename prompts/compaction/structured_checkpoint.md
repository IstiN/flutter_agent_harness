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
- Timeless content only: never record ephemeral, second-person, or
  time-scoped statements ("your last tool call's result was dropped", "you
  just ran X") — harness notes about dropped or trimmed context are one-time
  delivery events, not facts; record only the durable outcome. Durable
  temporal wording ("the last release was v1.0.492") is fine.
- Keep it dense prose or tight bullets; no preamble, no restating these
  instructions.
