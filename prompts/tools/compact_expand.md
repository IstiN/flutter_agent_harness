---
name: compact_expand
description: Description of the compact_expand tool that surfaces hidden context segments and pulls a hidden or compacted one back into the conversation by its numeric marker id (issue #148 structured compaction, agent UX #266).
---
Surface and reopen hidden context segments.

Call with NO arguments to list what is hidden: the index of hidden segments with id, kind, size, and a first-line preview each. Pass `query` to filter and rank that index by keyword — it searches the full hidden content, not just previews, so use it when you know WHAT you need but not the id. Discovery is free: it never consumes the expand budget.

To read a segment back, pass its numeric id or range from a marker as `target` (e.g. `5` or `2-6`). Context markers like `[3:hidden·tool_result·4.2k·"first line…"]` or `[2-6:ckpt·38k→40tok·covers:3,5]` are doors, not gravestones: the underlying records stay on disk.

- Giant segments are paged: pass `page` (1-based) to continue past the first page; each page footer states the exact continue call.
- Expanded content counts toward a per-turn budget; every success states the budget left, and when the budget is exhausted the result says so and resets on the next user turn. Only hidden, checkpoint-covered, or summary-folded records expand — the tool tells you when a record is already visible.
- The session file never changes; an expanded segment may be re-hidden later by compaction.

Prefer a targeted expand over re-reading files when the fact was already in context once, and prefer discovery + query over blind ids.
