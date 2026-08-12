# Phase 1 — Memory Foundation in `flutter_agent_harness`

Depends on: phase 0 (published `flutter_agent_memory`).

## Goal

Give the agent durable, cross-session, cross-project memory backed by
`flutter_agent_memory`, exposed as three tools (`memory_add`,
`memory_search`, `memory_list`), with a compact routing-hints section in the
system prompt. Works identically in the CLI (`fah`) and the Flutter app
because everything goes through `ExecutionEnv`.

## Design

### Storage layout

Memory is Markdown KV managed by `KBMemoryStore`; files live under two
scopes (mirroring the skill-roots convention):

- **Project scope**: `<projectRoot>/.fah/memory/` — project facts,
  decisions, conventions. Agent- and user-shared, committable if the team
  wants (we do NOT gitignore it ourselves).
- **User scope**: `~/.fah/memory/` — cross-project preferences and facts.

Resolution order on search: project first, then user (both searched, project
hits ranked above on ties). Writes default to project scope; `scope: "user"`
opts into user scope — same ergonomics as skills.

### New code (all pure Dart, `lib/src/memory/`)

| File | Content |
|------|---------|
| `lib/src/memory/execution_env_kb_storage.dart` | `ExecutionEnvKbStorage implements KbStorage` — maps `readEntity/writeEntity/deleteEntity/listEntityIds(type)` and `readFile/writeFile/listFilePaths(prefix)` onto `ExecutionEnv.readFile/writeFile/listFiles` under a base dir; paths are POSIX-joined strings; missing file = clean null/empty, never throw. `loadContext()` reads `MEMORY.md` if present. |
| `lib/src/memory/memory_controller.dart` | `MemoryController` — session-scoped facade: owns one `KBMemoryStore` + `KBSearchEngine` per scope, lazily created; exposes `add/search/list/formatPromptSection`; subscribes to nothing by itself (no `prepareNextTurn` wrap needed in phase 1 — memory is pull-based). Follows the `TtsrController` construction pattern (created in `AgentCli`, sink-injected). |
| `lib/src/memory/memory_sink.dart` | `MemorySessionSink` host-seam (pattern of `CheckpointSessionSink`/`TtsrSessionSink`): `{ExecutionEnv Function() env, String Function() projectRoot, LlmProvider Function()? searchProvider}` — the host supplies env + roots; null env = controller disabled (in-memory fallback for tests). |
| `lib/src/memory/memory_tools.dart` | `memoryTools(controller)` → three `AgentTool`s (see below). |
| `lib/src/memory/memory_prompt.dart` | `formatMemoryPromptSection(...)` — renders the routing-hints block. |

LLM access for tag generation / rerank: reuse the session's **smol role**
(`smolModelRole` from `lib/src/model_roles/`) — memory queries must not burn
the main model. `KBSearchEngine` takes a `LlmProvider`; build a thin
`LlmProvider` adapter over the harness `StreamFunction`/provider stack (the
memory package's `LlmProvider` is re-exported from `fa_llm`, so the adapter
is a small delegation class in `lib/src/memory/memory_llm_adapter.dart`).

### Tools

- `memory_add {text, type?, topics?, tags?, area?, importance?, scope?}` —
  write tier. `type` maps to `MemoryType` (fact/decision/rule/observation/
  event/belief/experience/generic, default `fact`). Dedup is capture-time
  inside `KBMemoryStore` — the tool reports `created` vs `duplicate`.
- `memory_search {query, limit?, scope?}` — read tier. Returns compact rows:
  `id | type | date | title/preview`. Full bodies are fetched with `read`
  (files are ordinary Markdown under `.fah/memory/` — progressive
  disclosure, same as skills).
- `memory_list {topics?, scope?, limit?}` — read tier, browse by topic.

Description texts: `prompts/tools/memory_add.md`, `memory_search.md`,
`memory_list.md` (frontmatter + `{{placeholders}}` where needed), generated
via `scripts/gen_prompts.dart`. Descriptions must teach: when to write
(durable decisions, user preferences, project conventions — NOT ephemeral
task state), the scope rule, and the dedup behavior.

### System prompt section

`AgentCliMcpWiring.composePrompt` (`lib/src/cli/agent_cli_mcp.dart:52`) is the
single composition point (`base + project-context + skills + mcp`). Add a
`memorySection` parameter, joined the same way, rebuilt whenever memory
content changes materially (cheap heuristic: rebuild on session start and
after any `memory_add`; cap staleness — do not re-render per turn).

Format (prime-agent "Continual Harness" pattern — routing hints, not full
texts): a `<memory>` block with up to ~15 most relevant entries (recency +
importance + accessCount), each ≤ 120 chars:

```
<memory>
Long-term memory is available via memory_search / memory_add.
- [decision] 2026-08-01 — SQLite, not Isar, for local cache (perf)
- [rule] prompts live in prompts/**, never in .dart files
…
</memory>
```

Budget: ≤ 2 KiB total. Empty store → section omitted entirely.

### Wiring

- **CLI** (`lib/src/cli/agent_cli.dart`): construct `MemoryController`
  alongside the TTSR controller (~`agent_cli.dart:383-433`), register
  `memoryTools` via `_toolRegistry.registerAll` +
  `_agent.state.tools = _toolRegistry.tools`, pass `memorySection` into
  `composePrompt`. Also register in `builtinTools(env, …)` with a `memory:`
  named parameter, following the `sqlite:`/`lsp:`/`mcp:` precedent — the app
  gets it through the same seam.
- **App** (`flutter_app/lib/services/agent_service.dart`): `AgentService`
  already wraps `builtinTools` with `SessionVarsExecutionEnv` — the env-scoped
  storage makes `.fah/memory` land inside the app sandbox automatically.
  Settings toggle "Long-term memory" (persisted JSON, tiny-store pattern) —
  default ON.

### What we deliberately do NOT do in phase 1

- No `prepareNextTurn` wrap, no automatic capture (phase 2).
- No session-content indexing / search over past sessions (separate
  follow-up; needs `SessionRepo.list` + `getEntries` crawling).
- No consolidation runs (phase 2), no memory-stored agent specs (phase 4).
- No changes to `KBOrchestrator` (dart:io-bound ingest pipeline) — unused.

## Testing

- `test/memory/execution_env_kb_storage_test.dart` — against
  `MemoryExecutionEnv` (already in `lib/src/env/`): CRUD, listing, missing
  files, nested paths, `loadContext`.
- `test/memory/memory_tools_test.dart` — add/search/list with a fake
  `LlmProvider` (scripted tag/rerank responses), dedup path, scope routing,
  approval tiers.
- `test/memory/memory_prompt_test.dart` — section format, budget cap, empty
  store omission, 120-char truncation.
- `test/cli/agent_cli_test.dart` (extend) — tools registered, prompt section
  composed, disabled-sink degradation.
- Prompt drift gate: `test/prompts/prompts_sync_test.dart` picks up the new
  prompt files automatically after `gen_prompts.dart`.

## Checklist

- [ ] `flutter_agent_memory: ^0.1.0` added to `pubspec.yaml` (hosted dep)
- [ ] `lib/src/memory/execution_env_kb_storage.dart` + tests
- [ ] `lib/src/memory/memory_llm_adapter.dart` (smol role → `LlmProvider`) + tests
- [ ] `lib/src/memory/memory_sink.dart`, `memory_controller.dart` + tests
- [ ] `lib/src/memory/memory_tools.dart` (`memory_add`/`memory_search`/`memory_list`) + tests
- [ ] `lib/src/memory/memory_prompt.dart` + tests
- [ ] Prompts: `prompts/tools/memory_*.md` + `dart run scripts/gen_prompts.dart`
- [ ] `builtinTools(env, memory:)` seam
- [ ] CLI wiring in `AgentCli` + `composePrompt` memory section
- [ ] App wiring in `AgentService` + settings toggle (with golden test for
      the settings row per the golden-test mandate)
- [ ] `dart analyze`, `dart format`, `dart test` green; coverage ≥ 80%
- [ ] `AGENTS.md` — new `lib/src/memory/` bullet
