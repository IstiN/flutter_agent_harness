# Changelog

## 0.1.0

- Initial project setup: package skeleton, quality gates (analyze, tests,
  coverage ≥ 80%, duplication < 1%), GOAL.md with the pi-mono port roadmap.
- Seeded `CancelToken` / `CancelTokenSource` / `CancelledException` — the
  universal cancellation primitive (Dart counterpart of web `AbortSignal`).

## 0.1.1


- Ported pi-mono `packages/ai`: EventStream contract (partial-first deltas,
  errors-as-events), SSE line decoder, openai-completions (OpenRouter-ready),
  Anthropic and Google provider adapters, usage/cost accounting,
  context-overflow detection, `Retry-After` parsing.
- Ported pi-mono `packages/agent`: low-level agent loop, stateful `Agent`
  with steering/follow-up queues and hooks, `AgentTool` registry with
  JSON-schema param validation.
- Sessions and context management: `ExecutionEnv` abstraction (pure-Dart
  memory impl + `dart:io` impl in `lib/io.dart`), append-only JSONL session
  tree with branching/labels, token estimation and LLM compaction pipeline.
- CLI harness (`bin/fah.dart`): a pi-like terminal agent with built-in
  `read`/`write`/`ls`/`bash` tools on the `ExecutionEnv` abstraction
  (`lib/src/tools/builtin_tools.dart`), a pure-Dart REPL core with injectable
  IO (`lib/src/cli/agent_cli.dart`) — live streaming output, slash commands
  (`/exit`, `/reset`, `/compact`, `/stats`, `/model`, `/help`), steering,
  Ctrl-C abort, JSONL session persistence, and auto-compaction.

## Unreleased
