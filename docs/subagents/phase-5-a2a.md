# Phase 5 — A2A (Agent2Agent) Protocol Interop

Depends on: phase 3 (the subagent runtime it exposes). Independent of
phases 1–2.

## Goal

Our agents stop being a closed in-process family and become interoperable
with the wider agent ecosystem via the **A2A protocol** — Google's
agent-to-agent standard (announced April 2025, donated to the Linux
Foundation June 2025, **v1.0 early 2026**, 150+ supporting organizations).

Two directions, independently shippable:

1. **A2A client** — our agent delegates to *remote* A2A agents (any vendor,
   any framework) exactly like it spawns local subagents.
2. **A2A server** — our CLI/app *exposes* its agent (or selected subagent
   types) as A2A endpoints that other agents can discover and delegate to.

## Protocol facts (v1.0, verified 2026-08-09)

- Transport: **JSON-RPC 2.0 over HTTP**, **SSE** for streaming,
  **gRPC binding** (`a2a.proto`) as an alternative; push-notification
  webhooks for long tasks.
- Discovery: **Agent Card** — JSON document at
  `/.well-known/agent.json` advertising capabilities, skills, modalities,
  auth schemes, and the endpoint.
- Data model: **Task** (stateful lifecycle: `submitted → working →
  input-required → completed | failed | canceled`, addressable by id,
  supports follow-up messages within the same task), **Message** with
  **Parts** (text / file / structured data), **Artifact** (task outputs).
- Auth: declared in the Agent Card (API key / OAuth2 / mTLS), enforced at
  the HTTP layer.
- Key methods: `message/send`, `message/stream` (SSE),
  `tasks/get`, `tasks/cancel`, plus task resubscription.
- Positioning vs MCP: MCP = agent↔tools; A2A = agent↔agent. They compose —
  we already have MCP, A2A fills the delegation side.
- Dart SDK status: **no official Dart SDK** as of this writing; the
  community `a2a` packages on pub.dev are partial. Expect to implement the
  client/server over `package:http` + SSE parsing ourselves — it is plain
  JSON-RPC, comparable in effort to our MCP transport layer. Re-check
  pub.dev before starting; if a maintained SDK appeared, prefer it.

## Design

### 5a — A2A client: remote agents as subagents

The trick: **a remote A2A agent is just another `SubagentHandle`**. Phase 3
gives us retained, addressable, observable children with sessions;
`ChildAgentFactory` (3a) becomes an abstraction with two implementations:

```
ChildAgentFactory
├── LocalChildAgentFactory   (phase 3: in-process Agent + own Session)
└── A2aChildAgentFactory     (phase 5: remote agent via JSON-RPC/SSE)
```

- **Config**: `a2a:` section in `~/.fah/config.yaml` (strict
  `ConfigException` parsing, same as `mcp:`):

```yaml
a2a:
  servers:
    translator:
      url: https://agents.example.com/translator
      token: ${A2A_TRANSLATOR_KEY}   # env-resolved, never config literals
```

- **Discovery**: on lazy first use, fetch `GET <url>/.well-known/agent.json`,
  validate, cache in-memory (per-session) — mirroring `McpManager`'s lazy
  background connect with per-server connecting/connected/failed status.
- **Spawning**: the `task` tool's `agent:` field accepts `a2a:<name>`
  (alongside local types). The runtime POSTs `message/send` (or
  `message/stream` for live progress), maps the returned **Task id** into a
  `SubagentHandle`, and creates a **local shadow session** that records the
  exchanged messages — so `task_status`, `task_observe`, `task_send`, usage
  reporting, and `/tasks` work uniformly across local and remote children.
- **Lifecycle mapping**: A2A Task states → our `SubagentStatus`
  (`submitted/queued→queued`, `working→running`,
  `input-required→idle` (+ the question surfaced to the parent),
  `completed→completed`, `failed→failed`, `canceled→aborted`).
  `task_send` to a remote child = follow-up `message/send` with the same
  A2A task id (native A2A semantics — retained children map perfectly).
  Dispose = `tasks/cancel`.
- **Results**: Artifacts → text/ImageContent results under the shared
  100k-char budget (same rule as MCP content mapping); streaming SSE
  events → `SubagentEvent`s so the UI/Live Activity shows remote progress
  like local.
- **Approval**: `a2a:` spawns are exec tier; server list is config-only
  (like MCP — no CLI add command in v1).
- Pure Dart over injectable `package:http` (web gets remote A2A for free);
  no `dart:io` in `lib/`.

### 5b — A2A server: expose our agent

- `fah serve --a2a [--port 8787] [--agent <type>]` — a headless mode that:
  - serves `/.well-known/agent.json` (name, description, skills = our
    agent-type menu from phase 4, modalities text+image);
  - implements `message/send`, `message/stream` (SSE), `tasks/get`,
    `tasks/cancel` — each incoming A2A Task = a new local session (or a
    subagent of a designated supervisor session), task id ↔ session id
    mapping persisted so follow-ups resume the right session;
  - auth: optional bearer token from env; without one, bind localhost only
    and say so loudly in the card/logs.
- Lives in `bin/` + `lib/io.dart` (HTTP server is `dart:io` — the pure-Dart
  core provides a transport-agnostic `A2aRequestHandler` that the IO layer
  mounts, same split as MCP's `McpByteChannel`).
- App side (flutter_app): **not in v1** — running an HTTP server on a phone
  is a battery/NAT question we defer; the app gets the client (5a) only.

## Testing

- `test/a2a/` — JSON-RPC codec, Agent Card parse/validate, Task-state
  mapping, artifact→content mapping, SSE event → `SubagentEvent`.
- Client integration: fake `package:http` client (same seam as MCP tests)
  scripting `message/send` → `working` → `completed` with artifacts;
  `input-required` surfacing; cancel.
- Uniformity: `task_status`/`task_observe`/`task_send` behave identically
  for local and `a2a:` children (shared test suite over both factories).
- Server: `A2aRequestHandler` unit tests (pure Dart, no sockets) + one IO
  smoke test behind the integration tag.

## Checklist

### 5a client

- [ ] `a2a:` config section (schema, strict validation, env-token
      resolution) + tests
- [ ] `A2aClient` (Agent Card fetch/validate/cache, `message/send`,
      `message/stream` SSE, `tasks/get/cancel`) over injectable http + tests
- [ ] `A2aChildAgentFactory` + shadow sessions + lifecycle mapping + tests
- [ ] `task` tool `agent: a2a:<name>` + `task_send`/`task_status`/
      `task_observe` uniformity + shared test suite
- [ ] Artifact→content mapping under the 100k-char budget + tests
- [ ] `/a2a` CLI status command (per-server connecting/connected/failed)
- [ ] Prompts: `prompts/tools/task.md` documents `a2a:` agent types
- [ ] Check pub.dev for a maintained Dart A2A SDK before writing the codec

### 5b server

- [ ] `A2aRequestHandler` (pure Dart): card, send/stream/get/cancel + tests
- [ ] `fah serve --a2a` IO mount (`bin/`, `lib/io.dart`), task↔session
      persistence, bearer auth, localhost-only default
- [ ] Integration-tagged smoke test: curl the card, send a message, get SSE
- [ ] Docs + `AGENTS.md` bullets for `lib/src/a2a/`

## Out of scope (v1)

- gRPC binding (JSON-RPC + SSE covers the ecosystem mainstream).
- Push-notification webhooks (poll/SSE is enough for our runtime).
- A2A server in the Flutter app.
- Agent Card **signing** / trust-on-first-use registries — v1 trusts
  configured URLs, full stop (documented in the card description).
