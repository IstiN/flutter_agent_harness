# Backend Agent Mode — fa as the Engine Behind Product Backends

**Status: [WIP] research / design — no code yet.**
Goal: answer *"can fa (this harness) run server-side behind a Go backend, with a
thin Flutter client and remotely stored sessions — without changing the client
API?"* Short answer: **yes**, at three integration depths. This document works
it through against a real consumer app (learn.ai) and generalizes to
familylearn.ai-class products.

---

## 1. Problem statement

Consumer Flutter apps (learn.ai today, familylearn.ai next) already ship a chat
with a stable client API. The desired end state:

- **Thin client** — sends a user message, renders the streaming reply, lists
  history. No agent logic, no prompts, no model config in the app.
- **fa lives on the backend** — the agent loop, tools, prompts, compaction and
  memory run server-side, behind the product's Go API service.
- **Sessions stored remotely** — the client can switch devices mid-conversation;
  server owns persistence.
- **Sandbox** — "task execution" (tools) must be contained: a per-chat
  workspace, an allowlisted toolset, budgets and denials by default. For a
  kids' product this is a hard requirement, not a nice-to-have.
- **Client API unchanged** — the Flutter app keeps talking to the same
  endpoints with the same event grammar. fa is a *replacement of the engine
  behind* the contract, not a change of the contract.

## 2. Feasibility

fa is a Dart package (`flutter_agent_harness`) with an already-decoupled core:

| Piece | Where | Backend relevance |
|---|---|---|
| Agent loop + typed event stream | `lib/src/agent/agent_loop.dart` (`AgentEvent` hierarchy: `AgentStartEvent`, `MessageStartEvent`, `MessageUpdateEvent`, `ToolExecution{Start,Update}Event`, …) | This is exactly the event vocabulary a server streams to a UI |
| Single-turn headless | `AgentCli.runHeadless(prompt)` — boots/resumes session, runs one turn, persists, exits with code | The "one user message in → turn done" primitive; spawnable as a subprocess today |
| Session persistence | `JsonlSessionRepo`, append-only JSONL under a sessions root; resumable | The server-side source of truth; trivially hydratable/relocatable |
| Per-session tool scoping | `tools.yaml` next to the session file | The sandbox allowlist mechanism already exists per session |
| LLM adapters | `packages/fa_llm` (OpenAI-compatible, OpenRouter, Ollama) | Server picks model policy centrally; no keys in the client |
| UI kit | `packages/fa_ui`, `packages/fa_llm_flutter` | A thin client can reuse them; or keep its own UI entirely |

So the question is not *whether* fa can be the backend engine — the loop is
already a library with a typed event stream. The design work is: **who hosts
the loop, how events cross the Go boundary, and how sessions become remote.**

## 3. Case study: the contract we must not break (learn.ai)

Current client-facing chat API (Go / Fiber):

```
POST /api/v2/chat/stream          SSE streaming turn
POST /api/v2/chat/                non-streaming turn
GET  /api/v2/chat/:chatId/history history
DELETE /api/v2/chat/:chatId       delete chat
GET  /api/v2/users/:userId/chat/learn-ai/history   parent → child chat
```

SSE event grammar (client-parsed):

| event `type` | payload | rendered as |
|---|---|---|
| `status` | `{status, tool_name?}` | activity indicator |
| `chunk` | `{content}` | streaming text |
| `chunk` | `{tool_calls:[…]}` | tool activity (compat) |
| `content_block` | `{data: ContentBlock}` | text / structured (`test`) blocks |
| `error` | `{error}` | error banner |
| `done` | `{}` | end of turn |
| `reconnect` / `cancelled` | — | recovery paths |

Plus: `StreamManager` already handles chat→stream mapping, reconnection and
chunk accumulation; messages persist as `ContentBlock`s in Postgres; chat IDs
are stable per user (`user-chat-<userId>`), parents may read children's chats.

**Implication:** the integration is an *adapter*, not a rewrite. Whatever emits
`AgentEvent`s must be translated 1:1 into this grammar (§6), and the canonical
user-visible history must keep landing in Postgres (§5).

## 4. Integration options

### Option A — fa sidecar: subprocess per turn (works today)

```
Flutter app ──SSE──▶ Go api-service ──spawn──▶ fah --session <key> --print "<msg>"
                     (translates)   ◀─events──  (session JSONL on disk)
```

- Go spawns `runHeadless`-equivalent per user message; harness emits machine-
  readable events on stdout (needs a small `--output jsonl` flag — *the only
  harness change* in this option).
- Session key = `<product>:<userId>:<chatId>`; JSONL lives on the server disk;
  Go mirrors user/assistant messages into Postgres for history/parent view.
- Pros: zero long-running infra; OS-level isolation per turn is free; the
  existing `StreamManager` reconnect logic stays authoritative.
- Cons: per-turn cold start (session boot + model cache warm ≈ hundreds of ms);
  streaming tokens need the loop's events piped through — fine with the flag
  above; process-per-turn limits horizontal density.

### Option B — fa agent service: long-lived Dart daemon (recommended target)

```
Flutter app ──SSE──▶ Go api-service ──WS/gRPC──▶ fa-agentd (Dart)
                     edge: auth, quota,          pool of harness instances
                     family rules, moderation,   per-chat session in memory
                     SSE translation             + JSONL persistence
```

- A small daemon wraps the harness *library* (not the CLI): one harness
  instance per active chat, `AgentEvent` stream relayed over WS/HTTP; sessions
  spill to JSONL; idle instances evicted, resumed on demand from disk.
- Go keeps being the **edge**: JWT auth, subscription/quota gates, family
  visibility rules, moderation, and the SSE grammar translation. The daemon
  never sees end-user tokens.
- Pros: native token streaming, no cold start per turn, compaction/memory
  stay warm per chat; one new moving part (a single stateless-ish daemon).
- Cons: needs a supervisor (systemd/container), health checks, and the WS
  protocol design (small, typed, versioned).

### Option C — port the loop into Go — rejected

The value of fa *is* the Dart harness (tools, compaction, providers, MCP,
approvals, the packaging). A Go port is a rewrite with a permanent fidelity
tax. If a Go process must own everything, Option B keeps that boundary honest:
Go owns HTTP, Dart owns agent.

**Recommendation:** spike A (days: `--output jsonl` + Go spawner + SSE
translator), evolve to B when concurrency/cold-start hurts. Both share §5–§7
unchanged, so the spike is not throwaway.

## 5. Remote session storage

Principle: **the harness keeps its native format; the server owns the copies.**

1. **Agent truth** — per-chat JSONL (append-only, crash-safe). Lives on the
   node that runs the chat's harness instance (Option B) or in a per-user
   workspace volume (Option A).
2. **Product truth** — Postgres (existing chat tables / `ContentBlock`s).
   After each turn (and at `done`), the Go side upserts user + assistant
   messages, mapped from the JSONL tail / end-of-turn events. History,
   parent-view and moderation read *this*, not the JSONL.
3. **Hydration / mobility** — device switch or node rescheduling = read JSONL
   from object storage (or regenerate from Postgres for display-only needs),
   drop it into the workspace, resume. Sticky routing `chatId → node` via the
   existing stream/chat map; fallback rehydrate makes nodes interchangeable.
4. **Retention** — JSONL is rebuildable state; Postgres is canonical. Deleting
   a chat (`DELETE /:chatId`) deletes both, plus the workspace.

This answers "мы хранили сессию удалённо" without inventing a new session
format: remote = the same JSONL, relocated and mirrored.

## 6. Event mapping (harness → client grammar)

| Harness `AgentEvent` | learn.ai SSE | familylearn-class SSE (v2, proposed) |
|---|---|---|
| `AgentStartEvent` | `status{status:"thinking"}` | same |
| `MessageStartEvent` | `status{status:"typing"}` | same |
| `MessageUpdateEvent` (text delta) | `chunk{content}` | same |
| `ToolExecutionStartEvent` | `status{status:"tool", tool_name}` | `tool{name, args-summary}` |
| `ToolExecutionUpdateEvent` | `chunk{tool_calls:[…]}` (compat) | `tool_delta` |
| turn complete (`done`) | `done` | `done` + usage |
| abort/cancel | `cancelled` | same |
| compaction events | `status{status:"consolidating"}` | same |

Non-streaming `POST /chat/` = same loop, join the stream, return the final
message. Structured outputs (tests, flashcards) ride `content_block` — the
harness can emit them as first-class blocks (e.g. via a `render_block` tool or
a structured-output convention) so `TestEntity` flows keep working.

## 7. Sandbox & safety

Layered, default-deny — mandatory for a kids' product:

1. **Tool allowlist per session** — `tools.yaml` next to the session file
   (already supported). Default set for learn.ai: *no shell, no filesystem
   outside the workspace*; only product tools (homework lookup, notebook,
   test-generator) exposed as a narrow tool API.
2. **Workspace isolation** — each chat gets a scratch dir; file tools are
   chroot'd there (Option B: enforced in the daemon; Option A: OS user per
   product, bind-mounted dir). Heavier "task execution" (code, media) goes to
   ephemeral containers with CPU/RAM/time budgets — the daemon treats the
   container as just another tool backend.
3. **Network egress** — model provider + product APIs only; per-tool egress
   rules; no arbitrary URLs by default.
4. **Approvals** — harness approval flow maps to `deny` (or to a parent-consent
   product flow) server-side; never surfaced raw to a child.
5. **Moderation** — Go edge moderates user input and assistant output
   pre-`chunk` flush; a `status{status:"blocked"}` + `done` keeps the grammar
   intact when a turn is cut.
6. **Budgets** — per-chat/per-day token and request ceilings in Go (quota is
   already a product concept); the daemon enforces a per-turn wall clock.

## 8. familylearn.ai-class integration (the "smooth and beautiful" part)

The same three pieces compose per product with **zero product code in the
harness**:

- **Server:** Go edge = the product (auth, family rules, subscriptions) +
  `harness-edge` library: config (system prompt, tool allowlist, model policy,
  languages), SSE/WS translation, session mirroring. New product = new config,
  not a new engine.
- **Client:** two modes. (a) keep the product's own chat UI, feed it the same
  grammar (learn.ai mode — literally no client change); (b) drop in
  `packages/fa_ui` chat widgets themed to the brand — that's the fast path for
  familylearn.ai and future apps.
- **Ops:** `fa-agentd` as one container/systemd unit per node; scale = node
  count; sticky-by-chatId routing + rehydration; metrics per chat (tokens,
  latency, tool denials).

Integration checklist per new product: pick contract mode (existing SSE or
v2), write the harness config (prompt/tools/model), mount product tools,
wire moderation + quotas, theme the UI. Nothing else.

## 9. Roadmap (research → pilot)

1. **This doc** — agreement on Option A spike, event mapping, storage split.
2. **Spike (Option A, days):** `--output jsonl` event flag on the CLI; Go
   spawner + SSE translator against a learn.ai staging route behind a flag;
   JSONL→Postgres mirror. No client changes anywhere.
3. **Pilot:** one non-critical chat surface (e.g. onboarding chat) served by
   the harness; compare latency/cost/quality vs solution_chat v2.
4. **Option B daemon:** WS protocol v1, pool/supervisor, rehydration, then
   migrate surfaces one by one.
5. **familylearn.ai:** start directly at B with `fa_ui` client mode.

## 10. Open questions

- Structured blocks: tool-emitted `content_block` vs post-hoc parsing of the
  final message (learn.ai tests/flashcards need the former).
- Multi-turn steering mid-stream (the REPL allows queued input; do product
  clients need "append while running"?)
- Session JSONL size growth → compaction cadence server-side; who pays for
  compaction latency (background vs pre-turn guard — the CLI already does a
  pre-flight guard).
- Obsolete-fork policy: product tools as MCP servers (harness already speaks
  MCP) vs in-process Dart tool registration.
