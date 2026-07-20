---
name: schema_fix
description: Fix-retry message sent to a task subagent whose final output failed schema validation (one retry, then the item fails).
---
Your final output failed schema validation:

{{errors}}

Reply with a CORRECTED final answer: exactly one JSON document satisfying the required schema — no prose, no markdown fences. This is your only retry; make it valid.
