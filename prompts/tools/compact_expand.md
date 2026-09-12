---
name: compact_expand
description: Description of the compact_expand tool that pulls a hidden or compacted context segment back into the conversation by its numeric marker id (issue #148 structured compaction).
---
Expand a hidden or compacted context segment back into the conversation.

Context markers like `[3:hidden·tool_result·4.2k]` or `[2-6:ckpt·38k→40tok·covers:3,5]` are doors, not gravestones: the underlying records stay on disk. Pass the marker's numeric id or range as `target` (e.g. `5` or `2-6`) to read the original content back.

- Giant segments are paged: pass `page` (1-based) to continue past the first page.
- Expanded content counts toward a per-turn budget; when exhausted the result says so — expand selectively instead.
- The session file never changes; an expanded segment may be re-hidden later by compaction.

Prefer a targeted expand over re-reading files when the fact was already in context once.
