---
name: task
description: Description of the task tool that fans work out to parallel subagents with schema-validated results, ported from oh-my-pi's task tool prompt.
---
Run subagents in parallel by passing multiple items in a single `tasks[]` batch. Execution blocks until every item finishes unless `background` is true — then you receive job ids immediately and results deliver as jobs settle.

# Task Design
- **Agent typing:** Pick each item's `agent` type. Read-only research MUST use `agent: "explore"`. Use the default worker only when no specialist fits.
- **No overhead:** Each `task` MUST instruct its subagent to skip formatters, linters, and project-wide test suites. Run those once at the end.
- **One pass:** Prefer subagents that investigate AND edit in one pass; spin a read-only `explore` only when the affected files are genuinely unknown.

# Inputs
- `context`: Shared project state, constraints, and contracts. Applies to the entire batch; do not duplicate this background into individual tasks.
- `tasks[]`: Array of subagents to spawn.
  - `name`: A stable identifier (`[A-Za-z0-9_-]`), used to address the agent (`agent://` urls, job ids). Uniquified per session; generated from the agent type if omitted.
  - `agent`: The agent type running this item. Omitting it gives you the general-purpose worker (`{{defaultAgent}}`) — NEVER pass that name explicitly. Only omit it after checking the agent list below and finding no specialist that fits.
  - `task`: Complete, self-contained instructions. One-liners or missing acceptance criteria are PROHIBITED.
  - `outputSchema`: Invocation-specific JSON Schema. The subagent's final message must then be a JSON document satisfying it; invalid output gets ONE fix retry, then the item fails.
- `background`: Run items as background jobs (default: host configuration). Blocking calls return every item's output in the result.

# Communication
Subagents start blank — no conversation history. Put everything they need into `context` (shared) and `task` (per item).

# Format Contracts
`context` format:
# Goal         ← what the batch accomplishes
# Constraints  ← rules and session decisions
# Contract     ← shared interfaces

`task` format:
# Target       ← exact files and symbols; explicit non-goals
# Change       ← step-by-step add/remove/rename; APIs and patterns
# Acceptance   ← observable result; no project-wide commands

# Results
Each item's full output is addressable as `agent://<id>`. For items with an `outputSchema`, the stored output IS the validated JSON object, so typed fields are addressable as `agent://<id>/<dot.path>` (e.g. `agent://Explore/findings.0.path`).

# Available Agents
{{agents}}
