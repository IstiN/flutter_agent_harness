# Phase 3 — Subagent Runtime: Sessions, Messaging, Monitoring

**Status: done** (shipped on main).

Depends on: nothing (parallel with phases 0–2). This is the core of the
"subagents 2.0" work and the largest phase; it is sliced into 3a / 3b / 3c,
each landing green independently.

## Current state (what we are replacing)

`lib/src/task/` today:

- `task_tool.dart` — `{context, tasks[], background?}` batch tool;
  `_runBlocking` (fan-out under a 32-permit semaphore) or `_spawnBackground`
  (detached, completions via `TaskJobManager.completions`).
- `task_executor.dart` — the child is a **naked `Agent`**
  (`task_executor.dart:165`): no session, no approval hooks, no
  `prepareNextTurn`, no sinks. Output = text of its last assistant message.
  When the call ends, the child is garbage.
- `output_manager.dart` — `AgentOutputStore` (in-memory), `agent://<id>`
  URL resolution.
- CLI (`agent_cli.dart:624`, `:2386`) — completions arrive as
  `<system-notice><task-result>` envelopes (steer mid-run, else new run);
  `/tasks` lists jobs.

Limitations to remove: children have no persistent session, are not
addressable after completion, cannot receive follow-ups, expose no
status/observability beyond a job list, and block the parent turn in
blocking mode.

## Target architecture

```
Parent AgentSession
└── SubagentManager (per parent session, owns the registry)
    └── SubagentHandle ×N
        ├── Agent          (full-featured: hooks, approval policy, sinks)
        ├── Session        (own JSONL tree, via SessionRepo)
        ├── status         running | idle | completed | failed | aborted
        ├── usage          tokens/requests, attributed to the parent
        └── lastActivity   timestamp + last-message preview
```

Key decisions:

- **Each subagent gets a real session.** Created through the existing
  `SessionRepo` under the same sessions root, in a child namespace:
  `<sessionsRoot>/<--encoded-cwd-->/subagents/<parentSessionId>/<ts>_<childId>.jsonl`.
  Child sessions are ordinary session trees (fork/label/compaction work),
  they survive the parent's compaction and restarts, and they are what
  "send a message later" resumes from.
- **Children are retained.** The registry (`SubagentHandle`s) is persisted
  into the **parent** session as a `CustomRecord` (`subagent_registry`,
  via `Session.appendCustomEntry` — the mechanism `ttsr_injection` and
  `branch_summary` already use), so it survives compaction. Handles are
  rehydrated on session open; finished children stay addressable until
  explicitly disposed.
- **Fire-and-forget is the default.** Spawn returns an admission handle
  immediately (`{id, name, status: running}`); the parent ends its turn.
  Blocking mode stays available (`background: false`) for deliberate
  fan-out-join, but the tool description steers the model to background.
- **Non-blocking is structural, not promised.** Each child runs its own
  `Agent` event loop in a detached `Future`; the existing `Semaphore`
  (default 32) bounds concurrency; the parent's loop never awaits a child
  except in explicit blocking mode; child events travel on streams
  (`SubagentManager.events`), never through shared mutable state.

## Slice 3a — Session-backed retained children

### New files

| File | Content |
|------|---------|
| `lib/src/task/subagent.dart` | `SubagentHandle` (id, name, agentType, sessionId, status, createdAt, lastActivity, usage, error?) — serializable (to/from the registry CustomRecord). `enum SubagentStatus {queued, running, idle, completed, failed, aborted}`. |
| `lib/src/task/subagent_manager.dart` | `SubagentManager` — superset of `TaskJobManager`: spawn/adopt/list/get/dispose, `Stream<SubagentEvent> get events` (spawned, statusChanged, message, completed, failed), persistence of the registry into the parent session, rehydration on open. |
| `lib/src/task/subagent_session.dart` | Child-session lifecycle: `createChildSession(repo, parentSessionId, cwd)`, `resumeChildSession(...)` — thin wrappers over `SessionRepo.create/open`. |

### Changes to existing files

- `task_executor.dart` — `TaskExecutor` now builds the child through a new
  `ChildAgentFactory` (injected via `TaskToolConfig`): full `Agent` with the
  parent's `beforeToolCall` (approval policy inherited — a child's writes
  are approved exactly like the parent's), a real `Session` from
  `createChildSession`, and event forwarding into `SubagentManager`.
  `task` tool stays excluded from the child's surface (no nesting) —
  `toolSurfaceFor` already enforces this.
- `task_tool.dart` — on completion the child is **not** dropped: the handle
  flips to `completed`/`idle` and stays in the registry. `TaskJob` becomes a
  thin view over `SubagentHandle` (keep the class name for API stability).
- `agent_cli.dart` — construct `SubagentManager` next to the agent (same
  place `TaskJobManager` is built today), rehydrate it when a session is
  opened (`_openSession` path), persist on every registry change.

### Session format

Registry record (appended on every change, last-wins on read):

```json
{"customType": "subagent_registry", "data": {"children": [
  {"id": "research-2", "name": "research", "agentType": "explore",
   "sessionId": "…", "status": "completed", "createdAt": "…",
   "lastActivity": "…", "usage": {"tokens": 12345, "requests": 7}}
]}}
```

### 3a checklist

- [x] `SubagentHandle` + status enum + JSON round-trip tests
- [x] `SubagentManager` (spawn/list/get/dispose/events/persist/rehydrate) + tests
- [x] `subagent_session.dart` child-session create/resume + tests
- [x] `ChildAgentFactory`: full-featured child Agent (approval inherited,
      session attached, events forwarded)
- [x] `TaskExecutor` migrated to the factory; `TaskJob` = view over handle
- [x] Registry persistence via `Session.appendCustomEntry`; rehydration on
      session open (CLI test: spawn → reopen session → `/tasks` still lists)
- [x] Child sessions visible in `SessionRepo.list` under the subagents
      namespace but excluded from the normal session picker

## Slice 3b — Messaging (parent ↔ child)

### Parent → child: `task_send`

New tool (write tier):

```
task_send {to: "<childId>", message: "...", wait?: false}
```

- Live (`running`/`idle`) child: the message is steered into its `Agent`
  (`steer()` mid-run, `followUp()`/new prompt when idle) — the child's own
  session records it as a user message.
- `completed` child: resumed — same handle, same session tree, status flips
  back to `running`. This is the "retained child" payoff.
- `wait: true` = synchronous request/reply (await the child's next settled
  state, return its reply text, capped like task outputs); default false
  (fire-and-forget, reply arrives as an async event).
- `failed`/`aborted` → clean error naming the terminal state and suggesting
  `task_send` is invalid / dispose and respawn.

### Sibling ↔ sibling: family messaging

In scope (user requirement, 2026-08-09): children of the same parent may
message each other, following prime-agent's `agent-messages.ts` model:

- Addressing is **family-scoped**: a child can address `parent` (via
  `reply`), a sibling by name/id, or `all-siblings` (broadcast, no loops —
  broadcasts are never re-broadcast). Anything outside the family → clean
  `AGENT_FAMILY_REACH`-style error.
- Child-side tool surface: `reply {message}` (to parent, see below) and
  `agent_message {to, message}` (to siblings). The parent-side tool is
  `task_send` — one mechanism, two tool names per role.
- Delivery: the recipient's `Agent` gets the message steered in as a
  `<system-notice><agent-message from="…">` envelope (same transport as
  parent notifications); if the recipient is `completed`, it is resumed
  (same semantics as `task_send`).
- Guards (borrowed from prime-agent, same numbers): rate limit capacity 3 /
  refill 1 msg/s per sender, pending queue ≤ 20 per recipient, message ≤
  16k chars, and a **hop counter** (max 4) on every envelope so
  ping-pong loops between siblings die deterministically instead of
  burning tokens forever.
- Observability: inter-agent messages are recorded in both sessions
  (sender + recipient) as `CustomRecord`s, so `task_observe` (3c) shows the
  conversation.

### Child → parent: replies and terminal notices

- Explicit reply: children get a `reply {message}` pseudo-tool (registered
  only on the child surface, not in the parent's registry) which emits
  `SubagentEvent.message` → delivered to the parent as the existing
  `<system-notice>` async envelope (`agent://<id>` ref included). The child
  doctrine prompt (below) teaches: "report through `reply`, not just your
  final message".
- **`completed_without_reply` notice** (prime-agent pattern): if a child
  settles without calling `reply`, the manager still delivers a terminal
  notice with a preview (≤ 500 chars) of its last assistant text. A silent
  child can never vanish quietly.
- Rate/shape guards (borrow prime-agent's limits): pending queue ≤ 20 per
  child, message ≤ 16k chars, only family addressing (parent only — no
  sibling messaging in v1; explicitly documented as out of scope).

### Child doctrine prompt

`prompts/task/child_doctrine.md` (new): "You are a subagent `<name>` spawned
by a parent agent. Work autonomously. Report results via the `reply` tool —
your final message is only a fallback. If you are blocked, say so via
`reply` and stop." Composed after the agent-type prompt in
`ChildAgentFactory`. (+ `gen_prompts.dart`.)

### 3b checklist

- [x] `task_send` tool: live/idle/completed/failed paths, `wait` mode,
      message cap, tests with scripted child streams
- [x] `reply` child-only tool + `SubagentEvent.message` → parent envelope
- [x] `completed_without_reply` terminal notice + preview + tests
- [x] Pending-queue and size guards + tests
- [x] `agent_message` child tool: sibling addressing, broadcast, family-reach
      errors, hop counter + tests
- [x] Inter-agent messages recorded in both sessions (visible via
      `task_observe`)
- [x] `prompts/task/child_doctrine.md` + generated + sync test picks it up
- [x] `prompts/tools/task_send.md`; `prompts/tools/task.md` updated
      (background-first guidance, `task_send` cross-reference)
- [x] Blocking mode kept working (regression tests on `_runBlocking`)

## Slice 3c — Status, monitoring, usage attribution

### Agent-facing tools

- `task_status {id?}` — read tier. One child or the whole registry: id,
  name, type, status, model, createdAt, lastActivity, tokens/requests,
  current tool (if running), error (if failed).
- `task_observe {id, tail?: 10}` — read tier (prime-agent's agent-observe):
  last N messages of the child's session as role + ≤ 200-char previews, plus
  whether it is currently streaming. Reads via
  `SessionStorage.getEntries` on the child's session — works even for
  completed children and after parent restart.

### User-facing surface

- `/tasks` (CLI, `agent_cli.dart:2449`) upgraded to the registry view:
  status icons, per-child token usage, last-activity age;
  `/tasks cancel <id>` (existing), **`/tasks dispose <id>`** (drop a
  retained child; running → confirm), `/tasks log <id>` (prints the
  `task_observe` tail to the transcript).
- `flutter_app`: the session chat sheet / settings gets a "Subagents" row
  per session (count + statuses; tap → list with the same fields).
  UI work ⇒ golden tests per the repo mandate (full frames, real fonts,
  `golden_guard_test.dart` entry).
- Live Activity / `FaWorkBar` status text already key off tool events;
  child tool events forwarded through `SubagentManager` keep them accurate
  during subagent runs (verify, no new surface).

### Usage attribution

- Child `Agent` events already yield per-turn usage; `SubagentManager`
  accumulates them into the handle and appends a cumulative
  `subagent_usage` `CustomRecord` to the parent session on child settle
  (origin: spawn). `/usage`-style reporting includes a "subagents: N tokens
  across M children" line.

### 3c checklist

- [x] `task_status` tool + tests (single/all, all statuses)
- [x] `task_observe` tool + tests (tail cap, previews, completed child,
      after-restart read)
- [x] `/tasks` registry view + `dispose` + `log` + tests
- [x] Usage accumulation + `subagent_usage` record + reporting line
- [x] App "Subagents" UI + golden tests + `golden_guard_test.dart` entry
- [x] Prompts for the new tools + `gen_prompts.dart`

## Slice 3d — Per-subagent model/provider settings

Motivation: run the orchestrator on a big model, delegate to cheaper models
by default — cost savings must be a settings toggle, not a prompt hack.

What already exists (build on it, do not duplicate):

- Model roles `default`/`smol`/`slow`/`plan` with fallback chains and key
  rotation (`lib/src/model_roles/`), configured via `roles:` /
  `modelOverrides:` / `retry:` in `~/.fah/config.yaml`.
- `TaskAgentDefinition.modelRole` (explore → smol, review → slow) and
  `TaskToolConfig.rolesResolver` — the single place where a child's model is
  resolved today.
- The `models:` config section (`lib/src/model_roles/models_config.dart`) —
  per-slot overrides + named custom model definitions, mutable + persisted
  by the host; the app's `MediaModelsStore` is the same pattern for media.

Design:

- **New config section `subagentModels:`** in `~/.fah/config.yaml`, strict
  `ConfigException` parsing like `models:`/`roles:`:

```yaml
subagentModels:
  default: {model: gpt-5-mini}                      # all subagent types
  explore: {model: gpt-5-nano}                      # per-type override
  review:  {model: claude-opus-4-1, baseUrl: https://api.anthropic.com}
```

  Precedence (highest wins): per-type entry > `default` entry >
  `TaskAgentDefinition.modelRole` resolution (today's behavior) > parent
  model. A `baseUrl` switches the provider for that entry; the key resolves
  through the existing endpoint-scoped store lookup (`FA_KEY_<HOST>` /
  `FA_KEY_<HOST>_<NAME>`) — env names never hijack a custom endpoint.
  Entry model names also resolve through `models.custom` named definitions.
- **Resolution point**: a `SubagentModelResolver` injected into
  `TaskToolConfig` (wraps the existing `rolesResolver`). It produces
  `{model, streamFunction}` for a given agent type — when `baseUrl` differs
  from the parent's endpoint it builds a separate `StreamFunction` (the
  provider stack already supports multiple endpoints via custom providers);
  otherwise it reuses the parent's with a different model id.
- **App settings UI** (`packages/fa_ui`): a `SubagentModelsSection` widget
  modeled on `MediaModelsSection` — a row per agent type (built-ins +
  discovered types from phase 4) plus a "All subagents (default)" row, each
  opening provider/model pickers (reuse `ProviderPreset` +
  `ModelIdAutocompleteField` machinery). Persisted through the same
  models-config seam the media slots use; the store must handle agent types
  that appear/disappear (unknown type row = shown dimmed with a remove
  action). Wired in the app's settings screen with an adapter, like
  `DefaultChatModelSection`. Golden tests per the repo mandate.
- **CLI surface**: `/models subagents` — list effective per-type
  resolutions (model, endpoint, source: config / role / parent);
  `/models subagents set <type|default> <model> [baseUrl]` and
  `/models subagents remove <type|default>` — persisted via
  `onModelsConfigChanged`, mirroring the media-slot commands.
- **Cost feedback**: the `subagent_usage` record (3c) includes the resolved
  model per child, so `/usage`-style reporting can show "subagents: N
  tokens on <model>, M on <model>" — the savings are visible.
- **Model autonomy stays**: the `task` item schema gains an optional
  `model` field (explicit per-spawn request) that beats config — used
  sparingly, documented in `prompts/tools/task.md` ("prefer defaults;
  request a specific model only when the task genuinely needs it").

### 3d checklist

- [x] `subagentModels:` config section: schema, strict validation, tests
      (incl. bad schema = `ConfigException`)
- [x] `SubagentModelResolver` (precedence chain, endpoint switching,
      `models.custom` resolution) + tests
- [x] `task` item `model` field (parse → resolver override) + tests
- [x] CLI `/models subagents [set|remove]` + persistence + tests
- [x] fa_ui `SubagentModelsSection` + pickers + store wiring
- [x] App settings adapter + golden tests + `golden_guard_test.dart` entry
- [x] Usage records carry resolved model; reporting shows per-model split
- [x] Docs: `prompts/tools/task.md` model guidance; `AGENTS.md` model_roles
      bullet amended

### 3d+ — Role editing: UI + project-level roles (added 2026-08-12)

3d assigns models to agent TYPES; the roles themselves
(`default`/`smol`/`slow`/`plan` → model chains) stay yaml-only in the
user-global `~/.fah/config.yaml`. Two gaps close here:

- **Roles UI**: roles get the same two-level provider→model editing as the
  chat/media slots. App: a `ModelRolesSection` in `packages/fa_ui` — one
  row per role (name, description, resolved model), each opening the
  provider/model pickers (`ProviderPreset` + `ModelIdAutocompleteField`).
  CLI: a "Model roles" entry in the `/settings` hub → role picker →
  `runProviderModelFlow` (`lib/src/cli/settings_flow.dart`), persisted via
  the roles-config seam. v1 edits the role's PRIMARY chain entry (full
  chain editing stays yaml); the `roles:` schema gains an optional per-role
  `description:` shown in the pickers (e.g. smol — "cheap fast tasks:
  explore, compaction").
- **Project-level roles**: `.fah/roles.yaml` in the project (cwd → git
  root, same convention as `.fah/rules.yaml` / `.fah/lsp.json`), same
  schema as the user-level `roles:` section with strict `ConfigException`
  validation; per-role merge, project winning over user-global — a repo
  pins its own default/smol without touching the developer's global
  config.

#### 3d+ checklist

- [x] `roles:` schema: optional per-role `description:` + tests
- [x] Project `.fah/roles.yaml` discovery + per-role merge (project > user)
      + tests (incl. bad schema = `ConfigException`)
- [x] fa_ui `ModelRolesSection` (provider→model pickers) + app adapter +
      golden tests
- [x] CLI `/settings` "Model roles" entry via `runProviderModelFlow` +
      persistence + tests

## Cross-cutting checklist (whole phase)

- [x] Semaphore/concurrency stress test: 8 background children, parent
      keeps responding, no interleaving corruption
- [x] Approval inheritance test: child write-tier call hits the parent's
      approval gate (auto-mode dependent), never bypasses it
- [x] No-nesting invariant test: child surface has no `task` (children never
      spawn); child messaging (`reply`/`agent_message`) reaches only its own
      family
- [x] Family-messaging loop test: two siblings ping-ponging die at the hop
      cap with a deterministic error, parent notified
- [x] Session-restart end-to-end: spawn → reply → kill CLI → reopen →
      status/observe/send all work
- [x] Compaction end-to-end: parent compacts mid-child-run → registry
      intact, late reply still delivered
- [x] `dart analyze` / format / `dart test` green; coverage ≥ 80%; jscpd /
      CRAP ratchets hold; no file > 2800 lines (split `subagent_manager`
      early if it grows)
- [x] `AGENTS.md` `lib/src/task/` bullet rewritten for the new runtime

## Explicitly out of scope (v1)

- Nesting depth > 1 (children never spawn their own subagents).
- Cross-session subagents (children belong to their parent session family;
  cross-process/cross-vendor interop is phase 5 via A2A, not the in-process
  family channel).
- Daemon/worker process isolation (prime-agent style) — our runtime is
  in-process; the `SubagentManager` seam leaves room for it later.
