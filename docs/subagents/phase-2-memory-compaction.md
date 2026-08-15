# Phase 2 — Memory-Aware Compaction and Consolidation

**Status: done** (shipped on main).

Depends on: phase 1.

## Goal

Knowledge stops dying with compaction. When the harness compacts a session,
the dropped span is mined for durable facts *before* it is summarised away,
and memory is periodically consolidated so the prompt section stays small
and current. This is the harness-level analogue of prime-agent's
"kernel state survives compaction" — our durable state is the memory store.

## Design

### 2.1 Compaction-time extraction

Current flow (`lib/src/compaction/compaction.dart` +
`lib/src/cli/agent_cli.dart:1715-1719`): auto-trigger on token threshold →
`CompactionManager.compactSession(session)` → LLM summary →
`CompactionRecord` appended to JSONL; dropped messages leave the live
context (they stay in the JSONL file, but nothing reads them back).

New flow: `CompactionManager` gains an optional `MemoryExtractionHook`:

```dart
typedef MemoryExtractionHook = Future<void> Function(
  List<Message> droppedMessages,   // the span leaving the context
  CompactionRecord record,         // the summary that replaces them
  CancelToken? cancel,
);
```

- Called **after** the summary succeeds, **before** the compaction is
  committed to the session — extraction failure must never block compaction
  (log + skip).
- Implementation `lib/src/memory/compaction_memory_hook.dart`: sends the
  dropped span to the **smol** model with
  `prompts/memory/extract_durable.md`, which asks for 0–N JSON entries
  `{text, type, topics, tags, importance}` — ONLY durable items (decisions,
  rules, user preferences, project facts), explicitly NOT task progress
  (that is what the summary is for). Parse defensively (same tolerant
  JSON-extraction approach as `task_executor.dart`'s schema parsing);
  malformed → skip silently.
- Each entry goes through `MemoryController.add` → capture-time dedup in
  `KBMemoryStore` makes re-extraction of overlapping spans idempotent.
- Budget guard: extraction input capped (head+tail of the dropped span,
  ~8k tokens) — a huge compaction must not produce a huge extra call.
- One extraction per compaction; manual `/compact` triggers it too.

### 2.2 Background consolidation

`KBMemoryStore.consolidate` (LLM-summarises top records into `MEMORY.md` +
skill cards) already exists in the package; `MemoryLevelService` +
`MemoryPromotionPolicy` (raw → consolidated after 14d → concept after 90d,
raw expiry 30d) exist too. We add:

- `MemoryController.maintain()` — runs `maintainMemoryLevels()` +
  `consolidate()` for both scopes, sequentially, on the smol role.
- Triggers (whichever comes first), all fire-and-forget, never mid-turn:
  - session start, if last maintenance > 24 h ago (stamp file
    `.fah/memory/.last_maintenance` / `~/.fah/memory/.last_maintenance`);
  - CLI command `/memory maintain` (also gives the user visibility:
    `/memory` shows store stats — counts per type/level, last maintenance);
  - after N≥20 `memory_add` calls in a session (cheap counter, debounced to
    idle via `agent.waitForIdle()`).
- Concurrency: a per-scope `bool _maintaining` guard; second trigger while
  running = no-op. Maintenance never blocks a user turn.

### 2.3 Prompt section freshness

After consolidation or extraction, the prompt section (phase 1) re-renders
on the next turn boundary — same cheap heuristic, no per-turn work.

## Testing

- `test/memory/compaction_memory_hook_test.dart` — extraction with scripted
  smol responses: 0 entries, N entries, malformed JSON, input cap,
  failure-is-non-blocking, dedup on overlapping spans.
- `test/memory/memory_maintenance_test.dart` — triggers (24h stamp, counter,
  manual), the running-guard, level promotion invoked with a fake clock.
- `test/compaction/compaction_test.dart` (extend) — hook called with the
  right dropped span, not called on summary failure.
- CLI: `/memory`, `/memory maintain` render tests.

## Checklist

- [x] `MemoryExtractionHook` typedef + optional param on `CompactionManager`
- [x] `lib/src/memory/compaction_memory_hook.dart` + prompt
      `prompts/memory/extract_durable.md` (+ `gen_prompts.dart`)
- [x] Token cap + tolerant JSON parse + non-blocking failure semantics
- [x] `MemoryController.maintain()` + stamp files + running guard
- [x] Triggers: session start, `/memory maintain`, add-counter
- [x] CLI `/memory` stats command
- [x] Prompt-section refresh after extraction/consolidation
- [x] Tests green, coverage ≥ 80%, `AGENTS.md` updated
