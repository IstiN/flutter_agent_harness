# GOAL — flutter_agent_harness

## Objective

Build the **ideal cross-platform AI agent harness in Dart**, ported from the
architecture of **pi-mono** (`packages/ai` + `packages/agent`), publishable on
pub.dev and runnable everywhere Dart runs: **VM, Flutter desktop, iOS/Android,
and web**. The core package must stay **pure Dart** — no `dart:io`, no Flutter
imports in `lib/` (platform specifics live behind abstractions).

This repo is the successor to the adk_dart-based assistant stack in the
`yoclip` project; once mature it will power the yoclip Studio AI assistant.

## Reference codebases (read these first)

### Primary architecture reference — pi-mono

`/Users/Uladzimir_Klyshevich/git/references/pi/`

- `packages/ai/` (~8.7k LOC TS) — provider adapters behind one contract:
  `stream(model, context, options) → AssistantMessageEventStream`.
  Study these files before writing any provider code:
  - `packages/ai/src/providers/openai-completions.ts` (~1205 LOC) — the
    canonical adapter; also covers OpenRouter (`baseUrl` swap, first-class).
  - `packages/ai/src/providers/anthropic.ts` (~1242 LOC) — includes a
    hand-rolled SSE decoder at lines 260–409; port this to Dart.
  - `packages/ai/src/stream.ts` — event contract:
    `start → text/thinking/toolcall_{start,delta,end} → done|error`, every
    delta event carries the **live partial message** (partial-first design).
  - `packages/ai/src/utils/overflow.ts` — provider-specific context-overflow
    detection via error-message regexes.
  - **Invariant to preserve: providers never throw.** All failures —
    network, 429, abort, malformed SSE — arrive as an `error` event with
    `stopReason: error|aborted`. The agent loop never sees an exception from
    a provider.
- `packages/agent/` (~8.1k LOC TS):
  - `packages/agent/src/agent-loop.ts` (748 LOC) — the low-level async loop;
    port its shape, not its incidental JS-isms.
  - `packages/agent/src/agent.ts` (557 LOC) — stateful `Agent` with
    **steering / follow-up queues** (inject user messages mid-run — this is
    first-class behavior we must keep) and hooks (`beforeToolCall`,
    `afterToolCall`, `transformContext`, `prepareNextTurn`).
  - session layer — sessions as an **append-only JSONL tree** of records
    (branching, labels). Flat linear history is not acceptable.
  - compaction pipeline (~760 LOC) — `estimateTokens` (chars/4 heuristic,
    images ≈ 1200 tokens) → `shouldCompact` (reserve 16384 tokens) →
    `findCutPoint` (keep ~20k recent tokens) → `generateSummary` via LLM with
    a fixed structured prompt. Token-based, never message-count-based.
  - `ExecutionEnv` abstraction (FileSystem + Shell) — our portability
    boundary: default implementation uses `dart:io`, a web implementation
    can be backed by browser storage, all behind one interface.

### Dart-idiom reference — agenix

`/Users/Uladzimir_Klyshevich/git/references/agenix/packages/agenix/`

Steal idioms, **not architecture** (agenix has no streaming, no events, no
native tool calling, message-count memory — all rejected):

- `lib/src/static/agenix_exceptions.dart` — sealed exception hierarchy with
  `cause`/`causeStack`; adopt this shape (used for non-provider errors:
  config, tool validation, session IO).
- `lib/src/llm/_openai.dart:150-155` — parse `Retry-After` into a structured
  field on rate-limit errors.
- `lib/src/llm/llm.dart:69-125` — **one OpenAI-compatible adapter reused via
  `baseUrl`** for OpenRouter/DeepSeek/Grok/Groq/Mistral instead of N adapters.
- `lib/src/agent/_memory_manager.dart:91-118` — rolling summarization with
  failure-safe batch restore; candidate for a "lite" compaction mode.
- `lib/src/tools/_param_validator.dart` — param validation/coercion layer.
- Monorepo discipline: core package + separate backend packages
  (`agenix_firebase`) — mirror this when we add Flutter-specific helpers.

### Downstream consumer (context only, do not couple)

`/Users/Uladzimir_Klyshevich/git/yoclip/` — `packages/yoclip_core` assistant
stack will migrate onto this library. Current pains to verify we solve:
adk_dart held via 6 implementation_imports, no context management, images
replayed forever in context, not portable to web.

## Architecture contract (non-negotiable)

1. **Pure Dart core.** No `dart:io`, no `package:flutter/*` in `lib/` of the
   core package. Platform capabilities behind abstract interfaces
   (`ExecutionEnv`-style); `dart:io` impl in a separate library entry point
   (`lib/io.dart`) so web compilation of the core stays clean.
2. **Errors-as-events from providers** (pi invariant above).
3. **Streaming-first**: `Stream<AgentEvent>` everywhere; `Future`-only APIs
   are conveniences built on top.
4. **Partial-first deltas**: every event carries the current partial message.
5. **Cancellation**: `CancelToken` (seeded in `lib/src/cancel_token.dart`) is
   the universal abort mechanism — providers, loop, tools.
6. **Token accounting inline** in provider responses; overflow detection
   ported from `utils/overflow.ts`.
7. **Native tool calling** per provider (OpenAI `tools`, Anthropic
   `tool_use`, Google `functionCalling`); prompt-based tool calling is
   explicitly rejected.
8. **Multi-provider subset for v1**: openai-completions (covers OpenRouter),
   anthropic, google. Others later via the same contract.

## Roadmap

- **Phase 0 — spike (prove the hard parts):** `EventStream` +
  SSE line decoder + openai-completions adapter streaming real deltas from
  OpenRouter + CancelToken abort mid-stream. Manual smoke in `example/`.
- **Phase 1 — ai subset:** anthropic + google adapters, usage/cost
  accounting, overflow detection, retry-after handling.
- **Phase 2 — agent core:** agent loop, `Agent` with steering/follow-up
  queues, tool registry + validation, hooks.
- **Phase 3 — sessions & compaction:** JSONL session tree behind
  `ExecutionEnv` storage, token estimation, compaction pipeline.
- **Phase 4 — consumer migration:** switch yoclip Studio assistant behind a
  feature flag; extract Flutter helpers into a sibling package if needed.
- **Phase 5 — pub.dev release** (see below).

## Quality gates (enforced by git pre-commit hook)

Hook: `scripts/pre-commit` — canonical copy, also installed in
`.git/hooks/pre-commit`. Every commit must pass:

1. **File size guard** — no `.dart` file over 2800 lines (generated files
   exempt).
2. **`dart analyze`** — zero issues (infos allowed unless fatal-infos).
3. **`dart test --coverage`** — all tests green. LLM-calling integration
   tests are tagged `integration` and excluded from the hook (run in CI /
   manually with `dart test --tags integration`).
4. **Coverage ratchet** — line coverage of `lib/` ≥ **80%**
   (`scripts/check_coverage.py`).
5. **Duplication guard** — jscpd over `lib/` < **1.0%**.

Emergency skip: `git commit --no-verify` (not recommended).

## pub.dev release checklist

Modelled on `/Users/Uladzimir_Klyshevich/git/flutter_agent_memory`.

Before every publish:

1. Bump `version` in `pubspec.yaml`; add a `CHANGELOG.md` entry.
2. `dart pub publish --dry-run` — must be clean.
3. `dart run pana` (or check pub.dev score after upload) — target 160/160:
   keep `README.md` with usage example, `example/` with a runnable main,
   valid `LICENSE`, `topics`, up-to-date deps.
4. Tag the release in git: `v<version>`.

Publishing normally happens via **Automated publishing (OIDC)** — pushing a
`v<version>` tag triggers the GitHub Actions publish job, no secrets needed.
Manual `dart pub publish` from an agent is allowed **only on explicit user
instruction** (e.g. the first publish, which must exist before OIDC can be
configured).

## Conventions

- Commits in English, one logical change per commit, commit freely.
- Public API documented (`dart doc` comments) — pub.dev scores it.
- Tests mirror `lib/` structure; fake HTTP via `http.testing.MockClient`,
  never real network in unit tests.
- Keep provider code mechanically close to the pi originals — when pi fixes
  a provider bug we want a trivial port, not an archaeological dig.
