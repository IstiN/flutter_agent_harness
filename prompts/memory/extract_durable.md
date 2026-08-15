---
name: extract_durable
description: Prompt that mines a compacted conversation span for durable long-term memory entries.
---
You mine a conversation span that is being summarized away by compaction. Extract ONLY durable facts worth remembering across sessions — decisions, rules, user preferences, and project facts.

Explicitly NOT memory-worthy: task progress, intermediate results, tool outputs, anything the summary already captures.

Reply with ONLY a JSON array (no prose, no code fence) of 0-N entries:

```json
[
  {"text": "the fact, one concise sentence", "type": "note", "topics": ["topic"], "tags": ["tag"], "importance": 0.6}
]
```

Rules:
- `type`: one of `note`, `question`, `answer` (prefer `note`).
- `topics` / `tags`: short lowercase identifiers, at most 3 each.
- `importance`: 0.0–1.0 (0.7+ only for things that change future behavior).
- Empty array `[]` when the span holds nothing durable.

# Conversation span

{{span}}
