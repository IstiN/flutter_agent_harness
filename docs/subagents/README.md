# Subagents 2.0 + Long-Term Memory — Master Plan

Status: **planning** (no code yet). Source of truth for the subagent-runtime
and memory work streams in `flutter_agent_harness`.

## Goal

Evolve the current one-shot `task` tool into a full subagent runtime and give
the agent a durable long-term memory:

1. **Subagents run in their own sessions.** Every spawned child gets a real
   JSONL session (via `SessionRepo`), not a naked in-memory `Agent` — its
   transcript persists, survives compaction of the parent, and can be
   inspected and resumed.
2. **Subagents are retained and addressable.** A finished child does not
   disappear: the parent (and the user) can send it follow-up messages,
   fork it, or dispose it explicitly.
3. **Subagents never block each other or the parent.** Spawning is
   fire-and-forget with an admission handle; results arrive as async events;
   a semaphore bounds concurrency.
4. **Subagents are observable.** Status (running / idle / completed /
   failed), token usage, last activity, and recent-message previews are
   queryable at any time from both the agent (`task_status` / `task_observe`
   tools) and the user (`/tasks` command, app UI).
5. **Bidirectional messaging.** Parent → child (steer new instructions into
   a live or idle child) and child → parent (explicit replies and terminal
   notices), delivered as async-result envelopes.
6. **Long-term memory.** Durable cross-session memory backed by the
   `flutter_agent_memory` package, exposed as agent tools, rendered into the
   system prompt, and fed by compaction.
7. **Per-subagent model/provider settings.** The orchestrator can run on a
   big model while each subagent type (or subagents as a whole) is pinned to
   a cheaper model and even a different provider — configured from the app
   settings UI and the CLI config, so delegation saves money by default.
8. **Agents talk to each other — inside and outside the process.**
   Sibling↔sibling messaging within the session family (rate-limited,
   hop-capped), plus A2A-protocol interop: delegate to remote A2A agents as
   if they were local subagents, and expose our own agent as an A2A
   endpoint.

## Inspiration and constraints

Design references (both MIT / ours):

- `references/prime-agent` (PrimeIntellect-ai/prime-agent, MIT) — retained
  children with admission handles, `agent_message` family messaging,
  `agent-observe` inspection, `completed_without_reply` terminal notices,
  usage attribution, and the "Continual Harness" JSON memory with
  prompt-rendered routing hints. We borrow **ideas, not code** (their
  `agent-session.ts` is an 11k-line monolith; their runtime is
  TypeScript + an IPython kernel).
- `/Users/Uladzimir_Klyshevich/git/flutter_agent_memory` (ours) — the memory
  engine. Markdown KV knowledge base (`Question`/`Answer`/`Note`), typed
  `MemoryType`, levels (raw → consolidated → concept), temporality, typed
  relations, dedup, LLM tag/keyword search + rerank. Key integration point:
  the `KbStorage` interface (~60 lines, string-oriented, `FutureOr`) maps
  1:1 onto our `ExecutionEnv`; its LLM layer already re-exports our
  `fa_llm`.

Hard constraints that shape the design:

- `lib/` stays pure Dart — **no `dart:io`**. All file access goes through
  `ExecutionEnv`. Memory storage is implemented as
  `ExecutionEnvKbStorage implements KbStorage`.
- All LLM prompts live in `prompts/**` as Markdown, generated into
  `lib/src/prompts/prompts.g.dart` via `dart run scripts/gen_prompts.dart`.
- Quality gates (pre-commit): `dart analyze`, `dart format`, `dart test`
  green, `lib/` coverage ≥ 80%, jscpd / CRAP ratchets, ≤ 2800 lines per
  `.dart` file. Any `flutter_app` UI change requires golden tests.
- Children never get the `task` tool (no nesting) — this stays.

## Phases

| Phase | Doc | Scope | Depends on |
|-------|-----|-------|------------|
| 0 | [phase-0-memory-package.md](phase-0-memory-package.md) | Harden + publish `fa_llm` and `flutter_agent_memory` to pub.dev | — |
| 1 | [phase-1-memory-foundation.md](phase-1-memory-foundation.md) | `KbStorage` over `ExecutionEnv`, memory tools, prompt section, CLI/app wiring | 0 |
| 2 | [phase-2-memory-compaction.md](phase-2-memory-compaction.md) | Compaction extracts durable facts into memory; background consolidation | 1 |
| 3 | [phase-3-subagent-runtime.md](phase-3-subagent-runtime.md) | Retained session-backed subagents: messaging, status, monitoring, non-blocking | — (1 for phase 4) |
| 4 | [phase-4-agent-types.md](phase-4-agent-types.md) | Agent-type menu: filesystem discovery + memory-stored subagent specs | 1, 3 |
| 5 | [phase-5-a2a.md](phase-5-a2a.md) | A2A protocol: remote agents as subagents (client), our agent as an A2A endpoint (server) | 3 |

Phases 0–1 and 3 are independent and can run in parallel. Phase 3 is the
largest; it is internally sliced (3a sessions, 3b messaging, 3c monitoring)
so each slice lands green.

## Master checklist

- [ ] **Phase 0**: `fa_llm` published to pub.dev
- [ ] **Phase 0**: `flutter_agent_memory` 0.1.0 published to pub.dev (hosted deps only, known issues fixed)
- [ ] **Phase 1**: `ExecutionEnvKbStorage` + `MemoryController` + `memory_add`/`memory_search`/`memory_list` tools + prompt section, wired in CLI and app
- [ ] **Phase 2**: compaction-time fact extraction + background consolidation
- [ ] **Phase 3a**: every subagent gets its own JSONL session; retained child registry persisted in the parent session
- [ ] **Phase 3b**: parent→child messaging (`task_send`), child→parent replies, `completed_without_reply` notice
- [ ] **Phase 3b+**: sibling↔sibling family messaging (`agent_message`, rate limits, hop cap)
- [ ] **Phase 3c**: `task_status` / `task_observe` tools, extended `/tasks`, usage attribution
- [ ] **Phase 3d**: per-subagent model/provider settings (app UI + CLI config), cheap-delegation defaults
- [ ] **Phase 3d+**: roles editable from UI (fa_ui `ModelRolesSection` + CLI `/settings`), per-role `description:`, project-level `.fah/roles.yaml` (project > user merge)
- [ ] **Phase 4**: agent-type discovery from `.fah/agents/*.md` + memory-backed specs
- [ ] **Phase 5a**: A2A client — remote A2A agents as subagents (`task agent: a2a:<name>`, shadow sessions, uniform status/observe/send)
- [ ] **Phase 5b**: A2A server — `fah serve --a2a` exposing our agent (Agent Card, send/stream/get/cancel)
- [ ] Docs + `AGENTS.md` updated as each phase lands
