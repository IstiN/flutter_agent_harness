# AGENTS.md

Conventions for AI agents and contributors in this repository. Keep it
factual: paths, commands, invariants — no essays.

## Project layout

- `lib/` — the `flutter_agent_harness` package (pure Dart core). `test/`
  mirrors it. `prompts/` — all LLM prompts as Markdown (see rules below).
- `lib/src/approval/` — tool approval gate: tiers (read/write/exec),
  session modes (always-ask/write/yolo/unattended), per-tool overrides,
  critical-pattern
  `bash` interceptor, per-turn grants (`grantForTurn(allow:, deny:)` —
  skill `allowed-tools`/`disallowed-tools` manifest keys ride these for one
  turn; explicit deny > turnDeny > per-tool override > turnAllow >
  alwaysAllow > mode (critical bash outranks mode in always-ask/write/yolo,
  but is skipped in unattended so the mode never blocks — for runs with no
  user present); `clearTurnGrants()`
  on every new user
  message). Wired via `attachApproval` into `beforeToolCall` (runs
  first); prompt UI is an injectable `ApprovalPrompt` (null + prompt policy
  = deny).
- `lib/src/tools/ask_tool.dart` — `ask` tool: structured mid-turn questions
  via injectable `AskCallback` (null = error, cancel = plain result).
- `lib/src/tools/request_secret_tool.dart` — `request_secret` tool: the agent
  asks the USER for a missing credential via injectable
  `RequestSecretCallback` (never in chat text); a grant returns
  `RequestSecretResult` (host-adjusted `name`, `value`, `persisted` flag),
  a decline is a plain result. The app wires it in `AgentService` to
  `secretRequestHandler` (chat screen installs
  `ui/widgets/secret_request_sheet.dart`): a grant is persisted into
  `SessionKeysStore`, injected into the live shell env via
  `SecretsExecutionEnv.addSecrets` (the map is runtime-mutable now), and
  registered into the same `SecretRedactor` — so the next run's prompt name
  list, bash `$NAME`, and redaction all pick it up.
- `lib/src/env/session_vars_execution_env.dart` — `SessionVarsExecutionEnv`:
  an `ExecutionEnv` decorator injecting session-correlation env vars
  (`FAH_SESSION_ID`/`FAH_SESSION_FILE`/`FAH_PROVIDER`/`FAH_MODEL`, resolved
  live per `exec`, never secrets) into bash tool executions. Wired around
  `builtinTools` in the CLI (`AgentCli`) and the app (`AgentService`).
  `LocalShell` merges `ShellExecOptions.env` OVER `Platform.environment`
  (never replaces), so injected vars keep the inherited environment.
- `lib/src/tools/checkpoint_tool.dart` — `checkpoint`/`rewind` tools:
  context hygiene for detours. `CheckpointRewindController` wraps
  `Agent.prepareNextTurn`, persists via host `CheckpointSessionSink`.
- `lib/src/compaction/branch_summarization.dart` — `generateBranchSummary` +
  `navigateSessionTree` (use instead of `Session.moveTo` for tree
  navigation); summary is a `branch_summary` record on the entered branch.
- `lib/src/hashline/` — hashline patch language: `[path#TAG]` headers
  (4-hex xxHash32 of whole file), `SWAP`/`DEL`/`INS.*` ops, all-or-nothing
  `HashlinePatcher`, stale tags reject before any write. Wired in
  `builtin_tools.dart`: `edit` takes `patch`, `read` takes `hashline` flag.
- `lib/src/tools/read_selector.dart` — `read` trailing selectors:
  `:N`/`:A-B`/`:A+C` (`..` alias), comma multi-ranges, `:raw`. A literal
  file named `x:1-2` wins over the selector. `offset`/`limit` must not be
  combined with a selector.
- `lib/src/tools/archive_reader.dart` — `read` inside archives
  (`a.zip:inner/entry`, `.tar`, `.tgz`), 256 MiB cap.
- `lib/src/tools/sqlite/` — `read` SQLite targets (`db.sqlite`,
  `:table[:key][?params]`, `?q=SELECT`). FFI engine (`package:sqlite3`)
  exported only from `lib/io.dart`, passed via `builtinTools(env, sqlite:)`;
  without it a clean "not supported" note.
- `lib/src/tools/shell_jobs.dart` — background shell jobs:
  `ShellJobRegistry` over the `BackgroundShell` capability
  (`execution_env.dart`; `LocalShell`/`LocalExecutionEnv` implement it,
  `SessionVarsExecutionEnv`/`SecretsExecutionEnv`/`MemoryExecutionEnv` and
  the app's `ProjectMountEnv`/`SandboxedExecutionEnv`/
  `PersistentWebExecutionEnv` forward it — the desktop app runs the host
  shell; mobile's `WasiSandboxShell` and web's `MemoryShell` run jobs as
  detached script Futures on job-local interpreter clones via
  `flutter_app/lib/sandbox/shell_job.dart` — own cwd/vars/capture, shared
  fs). `bash background: true` runs detached with output
  streaming into `.fah/bash_jobs/<id>.log`; `bash_job {status|output|stop}`
  (write tier) manages them. A settle fires `onSettled` (CLI
  `_onShellJobSettled`, app `sendText` system-notice) → steered mid-run or a
  fresh idle turn. A foreground call that consumed the result inline
  suppresses the notification. Job logs on disk are NOT secret-redacted.
- `lib/src/lsp/` — `lsp` tool (diagnostics/definition/references/rename):
  pure-Dart JSON-RPC client over `LspTransport`; `.dart` →
  `dart language-server --protocol=lsp`, projects merge `.fah/lsp.json`;
  lazy start, 5-min idle shutdown, crash respawn with backoff; renames apply
  all-or-nothing through the env. IO transport only via `lib/io.dart` +
  `builtinTools(env, lsp:)`; 1-indexed line/character; missing server =
  clean note, never a crash.
- `lib/src/mcp/` — MCP (Model Context Protocol) servers from the `mcp:`
  section of `~/.fah/config.yaml` (strict `ConfigException` parsing; config
  file only, no CLI commands). Stdio (`command`/`args`/`env`,
  newline-delimited JSON-RPC — NOT LSP's Content-Length framing) and remote
  (`url`, streamable-http default or legacy sse, `headers`). Message-level
  `McpTransport`; stdio framing glue is pure Dart over `McpByteChannel`
  (process impl only via `lib/io.dart`), both HTTP transports are pure Dart
  over injectable `package:http` (web gets remote servers; stdio = clean
  "not supported" status). `McpManager` connects lazily in the background
  (boot never blocks), per-server connecting/connected/failed status,
  reconnect with capped backoff; tools register as `mcp__<server>__<tool>`
  (exec approval tier, description prefixed with the origin, inputSchema
  verbatim) through the manager's `onChanged` (AgentCli re-registers +
  rebuilds the prompt's tiny MCP section). Results map MCP content blocks
  onto ours (text as-is, images as ImageContent, resources/links as text
  placeholders) under a shared 100k-char budget; `isError` throws so the
  loop records an error result; timeouts name `mcp.toolCallTimeoutMs`.
  Wired via `builtinTools(env, mcp:)`; resources/prompts out of scope.
- `lib/src/model_roles/` — model roles (`default`/`smol`/`slow`/`plan`) with
  fallback chains, key rotation (`ApiKeyRing` over `NAME`/`NAME_2`/…), 429
  mid-turn take-over (`FallbackStreamFunction`, never silent). Provider
  streams carry watchdogs (`provider_common.dart`:
  `providerConnectTimeout` 180s for the request, `providerStreamIdleTimeout`
  5min between bytes — overridable via the `providerTimeouts:` config
  section, `connectTimeoutMs`/`streamIdleTimeoutMs`, published to
  `providerTimeoutsOverride` at startup) so a wedged endpoint errors out — and the resolver
  can fail over — instead of hanging the turn forever. Streaming adapters
  share ONE keep-alive `http.Client` (`sharedProviderHttpClient`) instead of
  a fresh client per call: per-turn TCP churn piled TIME_WAIT sockets into
  connect stalls. Config:
  `roles:`/`modelOverrides:`/`retry:` in `~/.fah/config.yaml` (invalid
  schema = `ConfigException`). Also the shared models config:
  `media_model_slots.dart` (media slot names/fields shared with the app's
  `MediaModelsStore` + strict yaml slot entry) and `models_config.dart`
  (the `models:` section — per-slot media overrides + named custom model
  definitions `/model <name>` resolves; mutable like the custom-provider
  registry, persisted by the host).
- `lib/src/ttsr/` — time-traveling stream rules: regex matched against
  streaming deltas; on match abort, inject rule bodies as hidden
  `<system-interrupt>` message, retry after 50ms. Persisted via
  `TtsrSessionSink`; guards: once-per-session, `maxInjectionsPerTurn`.
  Config: `ttsr:` in `~/.fah/config.yaml` + project `.fah/rules.yaml`.
- `lib/src/skills/skills.dart` — agent skills: `<root>/<name>/SKILL.md` plus
  Claude/Copilot/Codex layouts (`.claude/skills` + `.claude/commands`,
  `.github/skills`, `.codex/skills`, user-level equivalents incl.
  `~/.copilot/skills`), each root tagged with a `SkillSource`; project >
  user, first-name-wins. Third-party roots are discovered BY DEFAULT
  (opt-out): `skills_access.dart` `SkillsAccess` ask/granted/denied with
  `granted` as the zero-config default — `allowedSources` on
  `discoverSkills`/`discoverTaskAgents`; CLI `skills:` config section,
  the TUI `/skills` management menu + `/skills access`, startup dialog
  only for an explicit `ask`; app `SkillsAccessStore` + settings/boot
  dialog). Typed frontmatter lives in
  `skill_manifest.dart` (`SkillManifest` — allowed-tools, context: fork,
  paths, user/model-invocable …; unknown keys = notes). Only metadata
  enters the system prompt (path-gated `paths:` skills appear once a
  matching file was touched); bodies loaded with `read` or rendered for
  invocation by `skill_renderer.dart` (`$ARGUMENTS`/`$N`/`${CLAUDE_*}`,
  `` !`cmd` `` shell injections through the env, `allowed-tools` →
  per-turn approval grants, `context: fork` → the task tool). Migration
  guide: `docs/migrating-from-claude-copilot-codex.md`.
- `lib/src/prompts/project_context.dart` — `AGENTS.md`/`CLAUDE.md`/`GEMINI.md`/
  `GOAL.md`/`DESIGN.md` plus per-directory GitHub Copilot files
  (`.github/copilot-instructions.md` and `.github/instructions/
  *.instructions.md` — `applyTo` globs not evaluated, scoped files get an
  `<!-- applies to: ... -->` marker, `excludeAgent` ignored) auto-merged into
  the system prompt: cwd → git root, farthest-first, `<!-- From: -->`
  annotations, 32 KiB leaf-first budget; optional `~/.fah/AGENTS.md` first.
  CLI: `/skill:<name> [args]`, the `/<name>` alias, `/skills` (TUI: a
  management menu — picking a skill prefills `/skill:<name> ` into the
  composer via `FaTuiController.sendInputText`, plus access/import rows;
  line mode: plain list) with `[reload|access [ask|granted|denied]|import]`
  subcommands (bare `/skills access` opens an interactive picker, run
  detached from the sequential line REPL like the guided provider flows).
- `lib/src/task/` — `task` tool: parallel subagents, batch form
  `{context, tasks[]}` + `background` flag; children never get `task` (no
  nesting); roles: `explore`→`smol`, `review`→`slow`, `plan`→`plan`;
  `outputSchema` with
  ONE fix retry; child failure = per-item error, never batch failure.
  Agent types: built-ins (`task`/`explore`/`review`/`plan`) plus discovered
  `.md`/`.agent.md` files (`agent_discovery.dart` — roots `.fah/agents`,
  `.agents/agents`, `.claude/agents`, `.github/agents`, `.codex/agents` +
  user-level, gated by the skills access setting; `canonicalTaskAgentName` folds
  Claude/Copilot names like `general-purpose`/`Explore`/`Reviewer` onto the
  built-ins).
  `/tasks` lists jobs (background agents AND background shell jobs),
  `/tasks cancel <id>` routes by id; completions re-enter the parent
  as async-result messages (`agent://<id>` refs). Subagents are retained &
  addressable: real JSONL child sessions, `task_status`/`task_observe`/
  `task_send`/`task_cancel` (model-facing job abort), child-only `reply` +
  sibling `agent_message` (pending-queue + hop-capped),
  `completed_without_reply` notice.
- Steer soft-yield: a steering message (user `Ctrl+S`, subagent completion,
  inbox mail) arriving DURING a tool-call phase cancels the phase's
  zone-scoped yield token — `currentYieldToken()` in `cancel_token.dart`,
  published by `_runToolCallPhase` (`agent_loop.dart`), fed by
  `AgentLoopConfig.steeringNotifications` (in-process queue) and the
  non-draining `hasPendingSteering` probe (external inbox, 2s poll).
  Yield-aware tools (`bash`, blocking `task`) finish the tool call early
  WITHOUT stopping the work — it continues as a background job and the user
  message is delivered at the step boundary. Tools ignoring the token keep
  the classic behavior (message waits for the phase).
- `lib/src/messaging/` — the agent messaging fabric: every agent (main,
  subagents, other Fa instances sharing the root) owns a file inbox behind
  the isolated `MessagingRepository` interface (send/peek/drain/directory —
  future DB/network impls drop in without caller changes).
  `AgentMessage.kind` distinguishes agent chat from `user` input handed
  over by an attached client (the Fa app's attach view; the CLI delivers
  it as `[from app] …`, its own words, not agent chat).
  `FileMessagingRepository` over `ExecutionEnv`:
  `<root>/<agent>/inbox|read/<id>.json`, timestamp-ordered names, sanitized
  agent dirs, torn writes skipped. `SubagentManager.messaging` routes
  `enqueueMessage`/`drainMessages` through the fabric (in-memory queue is
  the no-fabric fallback); `mailboxPrefix` (the session id, set by the host
  on every session init/switch) namespaces mailboxes so two instances never
  drain each other — ids with `/` are absolute cross-instance addresses
  (`<sessionId>/main`). `agent_message` targets siblings, `main`, or an
  absolute mailbox; `agent_directory` lists LIVE fabric mailboxes (recent
  activity via the heartbeat hosts touch on their inbox-watch timers) plus
  anything with pending mail — stale mailboxes from finished sessions are
  hidden behind the tool's `all: true` (`.id` markers keep real ids despite
  dir sanitization; `_scheduled`/dot-dirs are not mailboxes). The
  `## Agent messaging` prompt section (prompts messaging_section.md, CLI +
  app variants) tells the model its own mailbox address. Turn-boundary
  delivery: `Agent.externalSteeringSource`
  merges inbox drains into the steering poll (main in AgentCli/AgentService
  as `_mainInboxMessages`, children via the executor) — messages land as
  sender-attributed user messages, so they persist in the session and read
  like a chat. Idle wake: an inbox watcher (2s CLI / 3s app) starts a turn
  when mail arrives while idle — two Fa instances chat live; a 10-run
  streak cap without user input breaks ping-pong loops.
  UI: `/agents` rows show a `mail:N` pending marker (the CLI
  font has no ✉ glyph), the app's AgentsSection shows `✉N`; observe/detail
  views list the pending inbox.
- `lib/src/session/attach/` — attached-session infrastructure (the Fa app
  watching a live `fa` CLI session 1:1 and handing it input): three
  INTERFACES so a later network impl (`fa serve --attach`, remote headless)
  drops in without touching consumers — `SessionPresenceStore`
  (register/touch/unregister/list; stale heartbeats auto-drop, crash
  coverage), `SessionEventSource.watch` (transcript tail as
  `AttachedMessage` rows: user/assistant/tool), `SessionInputChannel.send`
  (user input to the owning process). File impls:
  `FileSessionPresenceStore` (`<sessionsRoot>/.presence/<id>.json`,
  15s staleness) and `FileSessionEventSource` (JSONL tail via
  `readTextLines` deltas) + `FileSessionInputChannel` (fabric mail,
  `AgentMessageKind.user`, to `<sessionId>/main`). CLI wiring: `run()`
  registers presence, the 2s inbox timer touches it every other tick,
  `finally` unregisters; `AgentCliConfig.presenceStore` is injectable
  (bin/fah.dart builds the file store; tests inject fakes). CLI sessions
  carry `agent: cli` metadata (the app writes `fa`). App wiring:
  `CliSessionPresence` service (3s poll) + green-dot `live` on
  `SessionTile`; a live tap in the chat-sheet drawer opens
  `AttachedSessionScreen` (controller `attached_session_controller.dart`)
  instead of a second writer on the same JSONL.
- `lib/src/memory/` — long-term memory: `MemoryController` over the
  `flutter_agent_memory` package (hosted pub.dev dep),
  `execution_env_kb_storage` (KbStorage → ExecutionEnv), `memory_add`/
  `memory_search`/`memory_list` tools (`memoryTools(controller, onChanged:)`),
  and the `<memory>` prompt section: `formatPromptSection()` (BOTH scopes,
  entities parsed via `KBFileParser` — the raw file's first line is the
  `---` delimiter, not the fact) is cached by the host and recomposed into
  the system prompt asynchronously after startup + on every `memory_add`
  (CLI `_refreshMemorySection` in agent_cli.dart, app in AgentService);
  phase 2:
  `compaction_memory_hook` (compaction-time durable-fact extraction on the
  smol role, non-blocking), `maintain()` (levels + consolidate, running
  guard, 24h stamp), triggers on session start + `/memory maintain`;
  `/memory` shows stats.
- Git-backed memory (the repo IS the memory): storage paths come from the
  `memory:` config section — project `.fah/config.yaml` wins over
  `~/.fah/config.yaml` (`loadProjectMemoryConfig`); a relative
  `projectPath` resolves against the project root. This repo dogfoods it:
  `.fah/config.yaml` points at the COMMITTED `memory/` directory — clone
  the repo, get its memory. Inside the store dir: `MemoryRepoInit.
  ensureGitSupport()` (flutter_agent_memory 0.2.0) keeps `.gitignore`
  (derived artifacts: GRAPH.md, MEMORY.revision, INDEX.md,
  .last_maintenance — rebuilt on load, never committed) and
  `.gitattributes` (`DELETIONS.md merge=union` — the append-only
  tombstone ledger merges by union). Note ids are merge-friendly since
  0.2.0: `n_0447_a1b2` = sequential index + 4-hex md5 of the normalized
  text (parallel branches union-merge; legacy `n_0001` ids stay valid
  forever). The `memory_add` description IS the package's
  `MemoryPolicy.memoryAddPolicy` (docs/memory/memory_add_policy.md in
  the memory repo): durable facts only, solved problems are superseded
  via delete+add (never left to rot), project scope is PUBLIC (git) —
  no secrets/personal data there, user scope stays machine-local.
  `.gitignore` whitelists `.fah/config.yaml` (+rules/lsp/mcp/agents/
  skills/packages); logs/sessions/bash_jobs stay local. Commit memory/
  changes with the task that produced them (`memory:` prefix for
  memory-only commits).
- `lib/src/a2a/` — A2A (Agent2Agent) interop: `a2a_client.dart` (Agent Card
  + JSON-RPC + SSE), `a2a_config.dart` (`a2a:` yaml section, `${NAME}`
  env tokens), `a2a_manager.dart` (lazy per-server connect, A2A task state
  → subagent lifecycle mapping), `a2a_server.dart` (request handler).
  `task` tool agent type `a2a:<name>` runs remote agents as subagents
  (uniform `task_status`/`task_send`); `/a2a` shows server status;
  `fa serve --a2a [--port N] [--token T]` mounts this agent as an endpoint
  (`bin/serve_a2a.dart`).
- `bin/fah.dart` — the `fah`/`fa` CLI. REPL (no args) or headless
  (`fa "prompt"` / `-p`, mutually exclusive). First positional naming an
  EXISTING file is the prompt source (`.md`/`.txt` inlined, others attached
  by reference; `-p` is verbatim). Args parsed in `lib/src/cli/cli_args.dart`
  (pure Dart). Headless: exit 0/1/130; `CliIO` contract — `write` = primary
  stream, `writeln` = diagnostics (stderr headless). The TUI captures the
  mouse by default (wheel scrolling — the alternate screen has no native
  scrollback); selection works via the terminal's bypass modifier (Shift),
  and `FA_TUI_MOUSE=0` (`AgentCliConfig.tuiMouseCapture`) hands the mouse
  back for always-on native select-to-copy.
- `lib/src/cli/` — REPL machinery: `/provider [name] [baseUrl] [token] |
  custom` (guided wizard in `provider_flow.dart` + `provider_commands.dart`;
  `/models` fetched for openai-like endpoints), custom providers in the
  `customProviders:` section of `~/.fah/config.yaml`. Editing a saved
  OAuth-connected entry (OpenRouter) offers the connect-time sign-in choice
  at the key step — keep / Browser OAuth re-auth / paste a key
  (`CustomProviderFlowConfig.reauth`). The same picker appears for
  CodeMie entries in edit mode (matched by the `/code-assistant-api/`
  URL marker — works for legacy entries whose `authMethod` was never
  recorded): `Browser SSO (CodeMie)` (`_mintCodeMieSsoCookie`); the
  wizard applies the minted value through format-aware switch routing
  (`isCodeMieJwtToken` decides SSO-cookie vs JWT-Bearer) so the cookie
  stays a `cookie:` header (not Bearer) and the JWT keeps its Bearer
  slot. Every add/connect flow that saves a
  registry entry offers a provider-name step (`_askConnectProviderName`:
  typed value, else the endpoint host; a clash with a DIFFERENT endpoint
  retries, and so does a name matching a CATALOG provider — `/provider
  kimi` routes to the catalog before the registry lookup, so such an
  entry would be unreachable) — the custom wizard, DIAL (custom names
  scope the store key; the switch stores under the entry's slot via
  `tokenKeyName`), Kimi (a typed key becomes a named
  entry with a name-scoped key; a resolved key offers "use it / add a
  second account"), OpenRouter OAuth + API-key, ChatGPT OAuth (lands a
  registry entry too, `apiType: chatgpt`), CodeMie SSO/JWT (the
  SSO name step only from the explicit add flows: `offerName` — automatic
  re-authorizations on startup/switch/mid-stream expiry stay silent; a
  NEW account name re-runs the guided project → model pick, a re-login
  to the same entry keeps its model).
  Saved-entry lookups are by base URL (`_entryForBaseUrl`), so a renamed
  entry is not duplicated on re-connect. Catalog switches RESET
  `_activeCustomName` (kimi/openrouter stored-key branches included) —
  a leaked marker made `/model` rewrite the previous custom entry's
  model memory. `/models` also manages
  the `models:` section: `/models config`/`set <slot> <model> [baseUrl]`/
  `remove <slot>` for media slot overrides (persisted via
  `onModelsConfigChanged`), and `/model <name>` resolves `models.custom`
  definitions. Keys: env first, then
  secure store (`lib/src/secrets/secure_key_store*.dart` — Keychain /
  Secret Service / PasswordVault, IO backends only in `lib/io.dart`),
  preloaded into `SecureKeyCache`. Resolution: the spec's DEFAULT endpoint
  gets env → `FA_KEY_<HOST>` → `FA_KEY_<HOST>_<NAME>` → legacy; any other
  endpoint resolves ONLY its scoped store keys (env names never hijack a
  custom endpoint); `/key set` writes store-only, never config.
  `/settings` is the interactive settings hub: a TUI picker whose entries
  (Provider, Edit/delete provider, Chat model, Model parameters, Media
  models, Agent models, Approval mode, Agent mode, API keys, MCP servers)
  launch the same flows the dedicated slash commands open; line mode prints
  a summary. ALL TUI pickers (generic host pickers included) have
  type-to-filter + backspace (generic ones filter their static item list
  locally via `menuAllItems`, the models picker rebuilds through
  `buildModelMenu`; a no-match filter keeps the title + `(no matches)`).
  The `/model` TUI menu is TWO-STEP when several providers exist:
  `_buildModelMenu` returns provider rows (`@<name>` keys, the filter
  matches provider names AND their model ids) first, and selecting one
  opens that provider's model list (generic `modelProvider` picker whose
  `provider|model` rows route back through `_tuiSelectModel`'s
  cross-provider switch). A single provider goes straight to its models.
  The provider→model pick flows live in `lib/src/cli/settings_flow.dart` in the
  NAMED `SettingsFlow` extension (public `runProviderModelFlow`/
  `startChatModelFlow`/`startMediaSlotFlow`/`startAgentModelFlow`), so
  tests can drive them line-mode (see `test/cli/settings_flow_test.dart`).
  The model-list fetch dispatches per dialect
  (`_fetchProviderModelIds`: CodeMie `/llm_models` by URL marker, DIAL
  deployments when the spec is `dial`, else OpenAI `/models`; the saved
  entry's own key authenticates; failures fall back to manual entry).
  `startAgentModelFlow` pins the `smol`/`subagent` role chains through
  `ModelRolesResolver.setRoleChain`/`clearRoleChain` (the resolver is
  created on demand when the config had no `roles:` section —
  `AgentCliConfig.modelRolesResolver` is mutable) and persists via
  `onModelsConfigChanged` (bin/fah.dart's persistConfig reads the live
  resolver config).
- `lib/src/prompts/prompt_overrides.dart` — `prompts:` config section maps
  prompt names to file path or inline text; strict validation; flags
  `--system-prompt(-file)` > config > built-in.
- `lib/src/cli/cli_help.dart` — full `fah --help` text, guarded by
  `test/cli/cli_help_test.dart` (update BOTH).
- `lib/src/web_search/` — `web_search` (DDG keyless → Brave/Tavily keyed)
  and `web_fetch` (HTML→markdown, pub.dev handler) via
  `builtinTools(env, webSearch:)`.
- `lib/src/model_roles/provider_catalog.dart` — provider table (incl. the
  `chatgpt` Codex-backend entry, kind `chatgpt-codex`); specs
  default `input: ['text','image']` (vision). The `FA_PROVIDERS`
  dart-define / runtime env (`providerFilterEnvOverride`, wired from the
  process env in `bin/fah.dart`; the define wins) allowlists the catalog
  per build — `enabledProviders`/`providerEnabledInBuild`/`catalogProvider`
  all honor it, default is everything on
  (`test/build_filter/provider_filter_test.dart`).
  `lib/src/providers/chatgpt_oauth.dart` + `chatgpt_codex.dart` — ChatGPT
  account sign-in (PKCE against auth.openai.com, Codex CLI client id) and
  the Responses-API SSE adapter (`store: false` — the backend rejects
  server-side storage; `ChatGPT-Account-ID` header; 401 → refresh →
  re-persist via `ChatGptCredentialsPersist`). CLI:
  `/provider chatgpt oauth [headless]` (callback server in
  `lib/src/cli/chatgpt_oauth_server.dart`, exported from `lib/io.dart`);
  the credentials blob lives in the secure store as
  `CHATGPT_OAUTH_CREDENTIALS`.
  `lib/src/providers/codemie_sso.dart` + `lib/src/cli/codemie_sso_server.dart`
  (io.dart export) — CodeMie organization sign-in: `/provider codemie sso
  [orgUrl]` runs the browser SSO (login URL embeds the RANDOM callback port;
  the base64 `token` callback carries session cookies); the
  `codemie_access_token` JWT authenticates as Bearer against
  `<org>/code-assistant-api/v1` — the org is saved as a custom provider
  entry (re-login refreshes the key, keeps the last-used model). Models come
  from `/llm_models?include_all=true` (LiteLLM shape), not `/models`;
  `_refreshModelCache` branches on the `code-assistant-api` marker. The
  catalog also has a `codemie` entry for the manual
  `/provider codemie [url] [token]` path (env `CODEMIE_API_KEY`).
  `lib/src/providers/dial.dart` — the `dial` catalog entry (EPAM DIAL Core):
  OpenAI-completions payload, but chat at `{baseUrl}/openai/deployments/
  {model}/chat/completions` (the deployment name lives in the PATH — via the
  `OpenAICompletionsOptions.urlBuilder` extension point) with `Api-Key`
  header auth (the adapter gets a null key so no `Authorization: Bearer` is
  sent); optional `?api-version=` from the `DIAL_API_VERSION` env
  (`_catalogStreamFunction` reads it via `config.envVarValue`). Models come
  from `{baseUrl}/openai/models` (`fetchDialModels`, the
  `_refreshModelCache` `provider == 'dial'` branch). Headless:
  `--provider dial --model <deployment> [--base-url …]` (dial has no
  default model id — `buildCliDefaultModel` throws without `--model`).
  `lib/src/model_roles/vision_models.dart` — the shared vision heuristic
  (`modelIdSuggestsVision`, `visionMarker` picker checkmark,
  `inputModalitiesFor`): CLI model switches recompute `Model.input` from it
  and the model pickers show the ✓/✗ marker; `packages/fa_ui` re-exports it
  (one marker list for CLI and app).
  `lib/src/providers/models_for_endpoint.dart` — the shared "list this
  endpoint's models" dispatch (`fetchModelsForEndpoint`): CodeMie
  `/llm_models` by URL marker, DIAL deployments by `provider: 'dial'`,
  else OpenAI `/models`; every model picker (CLI flows, app pages) routes
  through it so no dialect silently degrades to manual entry.
- `packages/fa_ui/` — reusable Flutter package for hosts embedding the Fa
  agent: the Fa theme (`FahPalette`/`FahLightPalette`/`FahColors.of(context)`,
  `buildFahTheme()`/`buildFahThemeLight()` + chat themes) with the
  `FaUiTheme`/`FaUiThemeProvider` customization layer (accent colors, font
  family, radii), the provider/model settings widgets (`ProvidersSection`,
  `ProviderEditorPage`, `DefaultChatModelSection` + pickers,
  `MediaModelsSection` (the settings media-models section, moved from the
  app — store/`mainBaseUrl`/`modelsFetcher` in, host analytics via the
  `onSlotEditorOpened`/`onSlotOverrideSaved` hooks),
  `MediaSlotProviderPickerPage`/`MediaSlotModelPage`, `ProviderPreset` +
  helpers (hosted presets: OpenRouter, Ollama Cloud, Google Gemini), `ModelIdAutocompleteField`, `FaVoicePresetPicker` +
  `faVoicePresetsFor` (per-(baseUrl, modelId) TTS voice presets — Gemini /
  Kokoro / OpenAI — with inline sample previews), and the stores (`ProviderRegistry`,
  `MediaModelsStore`, `SessionKeysStore`, `KeychainStore`,
  `modelIdSuggestsVision`). Every post-provider model choice uses ONE
  pattern: the fetched list renders immediately with the field text as the
  live quick-search, and a `Use "<query>"` row keeps manual entry —
  `FaModelListPicker` (`src/widgets/model_list_picker.dart`, the initial /
  tap-picked value shows the FULL list with a check, only user typing
  filters) for the form pages — media slots, agent roles, and the CodeMie
  SSO model step
  (`flutter_app/lib/services/codemie_sso_flow.dart`); the same
  `Use "<filter>"` row lives inside
  `UnifiedModelPickerPage` (applies on the ACTIVE provider, key resolved
  via the registry). The `ProvidersSection` rows carry the SAME brand mark
  the add-provider picker shows — `providerMarkKey` (preset) /
  `providerMarkKeyForBaseUrl` (custom provider, URL-matched: codemie
  marker, openrouter.ai, ollama.com, generativelanguage…, else `custom`) in
  `provider_marks.dart` — and never a current-provider check; every row
  trails a chevron into the editor. The provider editor
  (`ProviderEditorPage`) owns
  name/URL/key; the model id is a button-style row (icon + current model +
  chevron, mirroring the `TaskModelsSection` rows) opening
  `MediaSlotModelPage` with `slot: null` DIRECTLY (no provider-picker step)
  for a transient provider entry built from the CURRENT form values — the
  edited provider keeps its id so the stored key resolves, and a freshly
  typed (unsaved) key rides the page's `apiKeyOverride` (preset mode falls
  back to the stored preset key). The editor's `modelsFetcher` is a test
  seam threaded through `ProvidersSection`/`AddProviderPresetPickerPage`/
  `pushProviderEditor`. The media slots AND the agent-role rows
  (`TaskModelsSection`: Quick model / Subagents model) share the ONE
  two-step flow — `MediaSlotProviderPickerPage` → `MediaSlotModelPage`
  with `slot: null` for roles (no voice field, no capability chips,
  dial-aware provider kind) — so provider→model picking can never drift
  between settings surfaces. The endpoint fetch
  goes through the core `fetchModelsForEndpoint` dispatch (DIAL deployments
  / CodeMie marker / OpenAI `/models`); the legacy two-step
  `DefaultModelProviderPickerPage`/`DefaultModelPickerPage` and the
  text-field `TaskRoleConfigPage` are gone.
  The chat leaf widgets live there too (`lib/src/chat/`): the Markdown
  style/sandbox image resolver (`markdown_style.dart`), the inline
  audio/video players (`media_player.dart`), the approval/ask/
  secret-request sheets, the
  transcript message tile (`chat_message_tile.dart`), the composer
  (`chat_composer.dart` — file/gallery/camera picking through the
  `FaChatHost.uploadPicker`/`galleryPicker`/`cameraPicker` hooks, voice
  input through `FaChatHost.voiceInput`; desktop keys: Shift+Enter inserts
  a newline (a Focus ancestor swallows the key before the text-input plugin
  turns it into `send`), Cmd/Ctrl+V is smart paste — a clipboard image
  (via the `FaChatHost.clipboardImageReader` hook) or long/multi-line text
  is staged as an `uploads/` attachment chip, short single-line text pastes
  inline), and the single-service chat
  screen (`fa_chat_screen.dart` — `FaChatScreen(service:, features:,
  title:, settingsBuilder:, fileBrowserBuilder:, composerBuilder:)`),
  plus the upload helpers
  (`upload_utils.dart`), the media tool-name constants
  (`media_tool_names.dart`), and the brand glyphs
  (`fa_glyphs.dart` — `FaAttachGlyph`, the SVG attach icon used by the
  composer, `FaModelGlyph`, the AI-chip icon leading the provider editor's
  model row, and `FaAiAvatar`, the `>_` squircle used as the assistant
  avatar in `chat_message_tile.dart`) —
  localized via `FaChatStrings` (en/ru defaults, `FaChatStringsScope`
  override), analytics via the `FaChatHost.track` hook, backend surface is
  the `FaChatService` interface (which `AgentService` implements;
  `ApprovalModeSelector` needs only the
  `FaApprovalModeController` slice).
  Package strings live in `FaUiStrings`
  (en/ru defaults resolved from the locale, host-overridable via
  `FaUiStringsScope`) — never the app's gen-l10n. App-level concerns are
  injected: the active connection is the `FaChatConnection` interface,
  on-device engine routes are `FaOnDeviceRoute` builders, the apply
  callback carries `FaChatModelConfig`, and named-key resolution goes
  through the `FaUiHost.keyResolver` hook. `flutter_app` consumes it via
  path dep + thin `export` shims at the old paths; the app's
  `lib/ui/screens/providers_section.dart` additionally keeps a
  `DefaultChatModelSection` ADAPTER (old constructor) wiring `AgentService`,
  `LastConnectionStore`, and the on-device engines into the package flow.
- `flutter_app/` — Flutter chat example. Layout: `lib/main.dart`
  (entrypoint + BootstrapScreen: auto-connects the restored last connection
  when its key resolves, else SetupScreen), `lib/ui/` (`app_theme.dart` —
  shim re-exporting the fa_ui theme; `markdown_style.dart`, `screens/`,
  `widgets/`),
  `lib/services/` (agent service, stores, upload, secrets, project mount,
  vision, `theme_controller.dart` theme-mode persistence + `FahThemeScope`;
  `session_keys_store.dart`/`keychain_store.dart`/`provider_registry.dart`/
  `media_models_store.dart`/`vision_models.dart` are shim re-exports of the
  fa_ui stores), `lib/sandbox/` (env,
  shells, wasm, git, fs persistence), feature dirs
  `lib/apps|gemma|webllm|transformers_js|l10n/`. All lib-internal imports
  are absolute `package:fa/...` — no relative imports.
- `flutter_app/lib/ui/markdown_style.dart` (shim re-export of
  `packages/fa_ui/lib/src/chat/markdown_style.dart`) — beyond
  `fahMarkdownStyleSheet`: `SandboxImageResolver`/`fahSandboxImageBuilder`
  render markdown images with sandbox paths (`![alt](generated/x.png)`,
  leading `/` stripped) by loading bytes via `env.readBinaryFile` (memoized
  per surface, dim placeholder on failure, tap → `showFahImagePreview`
  fullscreen dialog); wired into the chat screen and the Fa chat overlay
  markdown. `generate_image` tool tiles also render the saved image inline
  (path parsed from the result text, which itself teaches the model the
  `![image](<path>)` convention).
- `flutter_app/lib/ui/widgets/media_player.dart` (shim re-export of
  `packages/fa_ui/lib/src/chat/media_player.dart`) — inline audio/video
  playback of sandbox media: `SandboxAudioPlayer` (play/pause, seek slider,
  `m:ss / m:ss`) and `SandboxVideoPlayer` (bounded tap-to-toggle surface,
  progress bar, mute) behind injectable `SandboxAudioController`/
  `SandboxVideoController` abstractions (tests/goldens inject fakes via
  `ChatScreen(audioControllerFactory:/videoControllerFactory:)`, real
  defaults wrap `audioplayers` (`BytesSource` — no file needed) and
  `video_player` (bytes staged to a temp file; web build shows an honest
  "not supported" note). Wired in `chat_screen.dart` for `speak`/
  `generate_music` results plus a `.mp3/.wav/.m4a` (audio) / `.mp4/.mov/
  .webm` (video) extension fallback for any NON-`read`, non-error tool
  result (which is how `generate_video` tiles render); markdown media links open a `showFahMediaDialog` player dialog
  (`onTapLink` — flutter_markdown has no custom link renderer) in the chat
  screen and the Fa chat overlay. Bytes load through the same memoized
  `SandboxImageResolver.load`.
- `flutter_app/lib/ui/widgets/chat_message_tile.dart` (shim re-export of
  `packages/fa_ui/lib/src/chat/chat_message_tile.dart`) — the ONE transcript
  message renderer, shared by the chat screen (its `flutter_chat_ui`
  builders delegate) and the in-app Fa chat overlay (`compact: true` for
  tighter panel padding): user/assistant Markdown bubbles (sandbox images
  via `SandboxImageResolver`, selectable), tail-collapsed thinking bubble,
  styled `[ tool ]` tiles with the private collapsible output block,
  `$`-prompt system lines, and inline generated-image/audio/video under
  tool tiles. Never fork message rendering — extend this widget.
- `flutter_app/lib/ui/widgets/chat_composer.dart` (ADAPTER over
  `packages/fa_ui/lib/src/chat/chat_composer.dart`) — keeps the app's
  constructor surface (`AgentService` + injectable `uploadPicker`/`asr`/
  `asrTranscriber`/`clipboardImageReader` test fakes) and bridges it to the
  shared composer's hooks: the `UploadPicker` becomes a `FaChatUploadPicker`,
  gallery/camera come from `image_picker`, the ASR stack is wrapped in a
  `FaChatVoiceInput` (transcriber resolved per take via the session's
  media gateway, falling back to the active provider), and the smart-paste
  clipboard image probe rides `pasteboard` (`Pasteboard.image` → PNG bytes;
  native plugin — the desktop/mobile apps need a REBUILD, not a hot reload,
  to register it).
- `flutter_app/lib/ui/screens/app_launcher_screen.dart` — THE app home on
  every layout (`faHomeScreen` in main.dart always returns it; the classic
  sidebar chat home is legacy and `session_sidebar.dart` no longer exists —
  sessions are managed by the chat sheet's pager/menus).
  iOS-home-screen grid of the JS apps (fsRevision-refreshed like
  `AppsGridView`) plus Settings/Files system tiles, laid out on the
  icon-unit geometry (`LauncherGridSpec` in
  `lib/ui/widgets/span_grid_delegate.dart`: 56px icon square + 20px label,
  16px gaps; default 4 columns < 600px, 6 above, clamped 3–8) as a
  `SingleChildScrollView` + `Stack` of `AnimatedPositioned` tiles
  (`packTileSpans`/`layOutTileRects`), so reorders animate live while
  dragging (center-band hover on an app = folder intent, edge halves =
  insertion preview; drop persists; hold-release without movement opens the
  tile-size menu). Folder tap opens a floating panel (rename/dissolve
  buttons, drag-out-to-ungroup onto the barrier). Tile layout persists via
  `LauncherLayoutStore` (`lib/services/launcher_layout_store.dart`,
  `launcher_layout.json` v2: ordered keys `app:<id>`/`system:*`/`folder:<id>`
  + `grid.columns` + `tileSizes` {appId: "WxH"} overrides — agent-editable,
  re-read live on fsRevision; v1 migrates, corrupt file → defaults;
  `syncApps` reconciles with installed apps). Its Stack hosts the
  `SessionChatSheet`.
- `flutter_app/lib/apps/session_chat_sheet.dart` — the iMessage-style
  session chat overlay over the launcher, three layers above the app grid:
  the always-visible docked input bar (the shared `ChatComposer` with
  `autofocus: false` — the bar never pops the keyboard at app start;
  leading slot = sessions-drawer toggle with the custom `SessionsGlyph`
  stacked-bubbles icon, turning into the attach button once a session is
  open; trailing = exactly ONE action — the mic while the field is empty
  and idle, stop while streaming-empty, send once text is entered, swapped
  via AnimatedSwitcher scale+fade (the composer's `hideMicWhenNotEmpty`;
  the idle mic sits in the same pill-colored circle the send/stop button
  occupies); the composer carries a stable key so the status-row slot
  toggling never recreates it (that killed the field's focus after send),
  and `_send` restores focus past the IME send action's own unfocus —
  the keyboard stays up for the follow-up message. Focusing the field
  opens the panel right away via
  `onFocusChanged`, `onSent` does too), the sessions drawer sliding in from
  the LEFT (New-session tile + live then persisted sessions rendered with
  the SAME `SessionTile`/`sessionTileSubtitle`/`sessionTileCwdLabel`/
  `showSessionActionsMenu` the wide sidebar exports from
  `sidebar_sessions_list.dart`, persisted open lazily via
  `manager.openSession`; a tile's folder label always comes from the
  session's OWN on-disk metadata cwd — a live session's env reports the
  app's CURRENT mount for every session, so reading
  `service.env.sessionCwd` would flip the label the moment a persisted
  session opens; its header clears the floating macOS traffic
  lights via `faIsMacOSDesktop`; a scrim tap on the exposed part dismisses
  the top layer, and the drawer carries its OWN scrim ABOVE the panel so an
  outside tap still closes it while a session is open), and the session
  panel sliding up UNDER
  the bar to 92% (drag-handle header: sessions-drawer button with the
  `SessionsGlyph`, title via `SessionNamesStore`, 3-dots menu New / Rename /
  Open full chat / Copy / Close — Rename opens the shared
  `showRenameSessionDialog`; the shared `ChatMessageTile` transcript padded
  above the bar by its measured height; pull-down on the header zone or a
  scrim tap closes). While streaming with the panel closed a slim
  `FaWorkBar(embedded:)` status row sits above the composer. There is no
  collapsed/mini state and no pager — session switching is the drawer.
  Sizing: the expanded panel height and all drag math come from the sheet's
  own `LayoutBuilder` constraints (`panelFraction`, default
  `defaultPanelFraction` 0.92 — hosts like the store-inapp shot pass a
  smaller fraction to park the panel lower), NEVER from
  `MediaQueryData.fromView(View.of(...))` — `View.of` subscribes to
  `_ViewScope`, whose `updateShouldNotify` compares only the view instance,
  so it never rebuilds on viewInsets changes and the keyboard opening used
  to push the panel header off the top edge; the host Scaffold's
  `resizeToAvoidBottomInset` shrinks the body constraints around the
  keyboard, which DOES rebuild the LayoutBuilder.
- `flutter_app/lib/ui/screens/chat_screen.dart` (ADAPTER over
  `packages/fa_ui/lib/src/chat/fa_chat_screen.dart`; also re-exports
  `chatImageMessageSource`/`kWideLayoutBreakpoint`) — keeps the app's
  multi-session surface: the `FlutterSessionManager` subscription (session
  switch hands the shared screen the new active service, which
  re-subscribes and re-syncs in place; closing the last session clones a
  fresh one via `ensureActiveSession`) plus the fa-specific affordances the
  package screen takes as hooks — the settings route (`settingsBuilder` →
  `SettingsScreen`), the files panel (`fileBrowserBuilder` → `FileBrowser`
  with env/fsRevision), the `open_app` launcher (`service.appLauncher` →
  `FaChatHost.appLauncher` when set, else `pushJsApp`), and the composer
  test fakes (`composerBuilder` → the app's `ChatComposer` adapter).
  Composer changes must keep the chat goldens pixel-identical.
- `flutter_app/lib/l10n/` — gen-l10n: `app_en.arb` + `app_ru.arb` →
  `AppLocalizations` (generated, never edit; `flutter gen-l10n`). UI copy
  via `context.l10n.<key>` (`l10n_ext.dart`); locale follows system.
  `test/l10n_guard_test.dart` hard-fails on hardcoded widget strings, en/ru
  key drift, placeholder mismatches, missing keys — opt out per line with
  `// l10n:ignore`, per file with `// l10n:ignore-file` (agent-facing/log
  strings stay literal).
- `flutter_app/test/golden/` — golden tests (see MANDATORY section below).
- `flutter_app/test/cli_visual/` — CLI visual integration tests
  (integration-tagged, excluded from the pre-commit `flutter test`): the
  real `dart bin/fah.dart` runs in a PTY (package:pty2) and every step is
  screenshotted through the real Flutter `TerminalView` (JetBrainsMono +
  Fa palette, `RepaintBoundary.toImage` at 2x) into the repo-root
  `test/integration/screenshots/NN_name.png` + a `.txt` twin with the exact
  xterm screen text. Run: `flutter test test/cli_visual --tags
  integration`. The pure-Dart counterpart harness lives in
  `test/integration/pty_harness.dart` (see its README for the PTY/pty2
  pitfalls: spawn `dart bin/fah.dart` NOT `dart run`, always cancel the
  output subscription in `close()`).
- `flutter_app/lib/ui/screens/model_presets.dart` — settings "Model presets"
  section: a swipeable `PageView` of `kModelPresets` cards applying a whole
  model combo in one tap (`applyModelPreset` — per-slot `MediaModelsStore`
  overrides, unmapped slots cleared, then `service.reconfigure` +
  `LastConnectionStore.saveFromConfig`; missing provider key = inline hint +
  jump to `ProviderEditorPage`, nothing applied). Add a preset by appending a
  `ModelPreset` to `kModelPresets` (doc comment there) plus its
  `modelPreset<Id>Name`/`...Description` arb keys; `ModelPresetTarget` is
  sealed for future custom/on-device targets. The presets headline the
  dedicated **Models** settings page
  (`flutter_app/lib/ui/screens/models_settings_page.dart` —
  `ModelsSettingsPage`: presets → `DefaultChatModelSection` →
  `TaskModelsSection` → `MediaModelsSection`), opened from the "Models"
  row on `SettingsScreen` (chip icon + chevron, ABOVE the Agents section)
  via `pushFaPage` — a centered dialog on wide canvases, full-screen on
  the phone — so the settings top level stays provider-focused; same
  layout on phone and macOS. The sections need the `MediaModelsScope`/`TaskModelsScope`
  from the app shell (tests: wrap ABOVE the MaterialApp — pushed routes
  build inside the Navigator, above `home:`).
- `flutter_app/lib/sandbox/sandbox_registry.dart` — central registry of
  sandbox shell commands per platform; the Fa system prompt's `{{commands}}`
  renders from it. Never list commands in prompt text or UI by hand.
- `flutter_app/lib/services/project_mount_env.dart` — macOS project-folder
  mount (`/project` → user-picked host dir; security-scoped bookmarks in
  `project_mount.json`; stale bookmark = "pick again" warning). Sessions on
  macOS are stored in the shared App Group container
  (`~/Library/Group Containers/group.dev.fa1.shared/fa/sessions`) so the Fa
  CLI and the sandboxed Fa macOS app see the same workspace-scoped sessions.
- `flutter_app/lib/apps/` — JS apps platform on `package:js_widget_runtime`
  (hosted `^0.4.79` — ships the queued-callEvent-after-dispose guard +
  restart-safe bridge channels that the old git pin carried, plus the M3
  nodes/overlays/flChart/pickers/drawer catalog and M3 motion tokens; the
  use-after-free SIGSEGV is owned by `js_app_engine.dart`'s process-wide
  lifecycle serialization — releases must stay immediate, never deferred;
  the `map` node: center/zoom/markers/polylines/
  fitBounds, onTap/onMarkerTap). `flutter_js` itself is overridden in
  `flutter_app/pubspec.yaml` to IstiN/flutter_js@74a11bf
  (fix-jscore-multi-instance: the shared native sendMessage callback routed
  to the LAST created runtime, so coexisting engines converted each other's
  JSValues with the wrong JSContext — SIGSEGV in JSC::JSLock::lock; the fork
  routes by executing context and refuses post-dispose evaluate): apps live in env-shared `apps/<id>/
  {manifest.json, widget.js}`; permissions in `apps_permissions.json` (network/
  allowedCommands/llm/homekit/health/contacts/calendar/microphone/
  notifications/media/keys — default denied);
  `jsr.fa.*` bridge over exec (`fa.llm`, `fa.calendar`, `fa.home.*`,
  `fa.health.*`, `fa.asr.*`, `fa.notify.*`, `fa.keys` — list/get/request the
  host's merged secrets (AgentService.hostSecrets); `request` renders the
  shared secret_request sheet from JsAppView and persists via
  AgentService.acceptSecretGrant; contacts is a gated "not
  available yet" stub); the `js-apps` skill seeds
  into `.fah/skills/` on startup. Bundled demos (seeded by
  `AppsStore.demoAppIds`, assets in `flutter_app/assets/apps/` — each id
  MUST also have its `- assets/apps/<id>/` entry in pubspec.yaml, gated by
  `test/apps/demo_assets_declared_test.dart`): calculator,
  weather, stocks, crypto, animation-showcase, yolo-hello, calendar
  (`jsr.fa.calendar`), map (`map` node), health + homekit (real bridge on
  iOS, honest demo-panel fallback elsewhere), fitness-trainer — guided
  workout with a 3D animated coach (a realistic human baked from NAVER's
  anny body model — Apache-2.0 — into
  `assets/apps/fitness-trainer/models/coach_anny.glb` with 10
  hand-authored skeletal clips; baker script in
  `references/anny/tools/bake_coach_glb.py` — anny `local-bone` deltas in
  world axes → glTF: IBMs are column-major, mesh split into ≤16-joint
  surfaces for flame_3d, and the skinned node must NOT be parented to a
  joint (flame_3d's dependency count then never settles); rendered via
  the `scene3d` node + flame_3d; START-driven exercise/rest steps with
  per-clip mapping, pause/skip/quit, sessions persisted via jsr.storage;
  `integration_test/fitness_coach_screenshot_test.dart` screenshot-verifies
  it on the macOS host), english-teacher — the "Language Tutor": Duolingo-style
  quiz sessions (hearts/XP/streak, choice + typing modes), a per-language
  offline word bank (en/de/es/fr/pl picker persisted via jsr.storage),
  LLM-generated extra words via `jsr.fa.llm.chat` (manifest `llm: true`),
  3d-game (`scene3d` node +
  `jsr.scene3d.*` bridge on the runtime's flutter_cube/flame_3d dispatcher
  — the engine's `JsRuntimeConfig` and both renderers (JsAppView,
  AppTileHost) wire `js3dHost: createJs3dHost()`, tap picking flows back
  via `dispatchHostEvent('scene3d.tap:<id>')`). Demo seeding is
  ownership-aware: `apps/.demo_seeds.json` records sha256 of each file as
  last seeded — a file whose content no longer matches is user/agent-owned
  and never overwritten, UNLESS the on-disk manifest is unparseable (a
  half-written skeleton is re-seeded, not protected: it bricks the tile), (`resetDemoApp(id)` force-restores the reference
  version, `storage.json` untouched). A demo id whose seeding FAILS
  (missing/corrupt asset) never kills the rest: it lands in
  `AppsStore.failedSeeds` (id → error text) and gets an error badge on its
  launcher tile; tapping the tile shows a dialog with the copyable error
  (hand it to Fa for a fix). `open_app_tool.dart` registers
  the agent tool `open_app`
  (host callback navigates via `js_app_navigation.dart` `pushJsApp`).
  Live launcher tiles: a manifest `"widget"` section
  (`{entry: 'widget_tile.js', size: 'WxH', refreshSeconds?}` →
  `JsAppInfo.tileWidget`; size in icon-slot cells, W 2–4 × H 1–4, default
  2x2 — the iOS small/medium/large presets 2x2/4x2/4x4) makes the launcher
  grid render `app_tile_host.dart`
  (a JsAppEngine on the tile entry, display-only — any tap opens the app)
  instead of the static icon tile; a WxH tile's edges align exactly with
  the WxH block of icon slots it replaces. Users resize tiles via the
  hold-release menu (writes `tileSizes` into `launcher_layout.json`); the
  same menu offers demo apps "Restore reference version"
  (`AppsStore.resetDemoApp` — force-reseeds bundled code when
  ownership-aware seeding skips modified files, `storage.json` untouched).
- `flutter_app/lib/services/home_service.dart` — smart home: `HomeApi` over
  the `fah/home` MethodChannel (HomeKit in `AppDelegate.swift`, iOS only;
  the macOS channel answers unsupported): the HMHomeManager is created
  LAZILY on the first home call — instantiating it is what triggers the OS
  home-data prompt, so the channel registration never touches it (the prompt
  waits for the home JS app / a home tool, never app start). `listHomes`/
  `listRooms`/
  `listAccessories` (with the full services/characteristics breakdown +
  isOn/brightness/targetTemperature conveniences), `readAccessory`,
  `writeCharacteristic` (ANY writable characteristic by HomeKit type
  string), `listScenes`/`executeScene`, and the setPower/setBrightness/
  setTargetTemperature aliases. The delegate waits for the first
  `homeManagerDidUpdateHomes` (5 s cap) when access was granted but homes
  have not loaded yet, and polls the authorization status so a denied
  prompt answers `false` instead of hanging. All four writes take optional
  `name`/`room`: bridge sub-devices (Aqara/Mi) can share ONE
  `uniqueIdentifier`, so the native write routing narrows id matches by
  name+room (case-insensitive, exact > partial) and falls back to a
  name+room match when the id matches nothing; still-ambiguous = clean
  error, never a first-match write. JS surface `jsr.fa.home.*`
  mirrors it (`docs/js-system-apis.md`); agent tools in `home_tool.dart`
  (`home_devices`, `home_turn_on`/`home_turn_off`, `home_set`) — `match`
  accepts a name or a full UUID, optional `room`/`home` args narrow
  duplicate names (the ambiguity error teaches both escape hatches), and
  `home_devices` shows each accessory's short id (first 8 chars).
- `flutter_app/lib/services/app_log.dart` — process-wide debug log: ring
  buffer (2000 lines) + best-effort persistence to `logs/app.log` under
  `ExecutionEnv.cwd` (rewritten with its tail past 1 MB). `main.dart` tees
  `debugPrint` into it; settings has a "Copy debug logs" row.
- `flutter_app/lib/services/background_execution.dart` — iOS extended
  background execution (`fah/background` channel →
  `UIApplication.beginBackgroundTask`, io/stub pair): the
  `AgentService.isStreaming` setter brackets every run so the OS grants
  ~30 s of execution when the user backgrounds mid-stream instead of
  suspending instantly.
- `flutter_app/lib/services/live_activity.dart` — iOS Live Activity
  (`fah/live_activity` channel, ActivityKit ≥16.2, io/stub pair): starts
  on run start, updates with the FaWorkBar-style status text on tool
  start/end and first deltas, final done/error update then `end` after
  4 s. The widget extension is `ios/FaLiveActivity/` (bundle id
  `dev.fa1.app.FaLiveActivity`, compiled into both targets via
  `FaLiveActivityAttributes.swift`); `Info.plist` has
  `NSSupportsLiveActivities`. Device/release signing needs an App ID +
  provisioning profiles for the extension in the portal.
- `flutter_app/lib/services/calendar_service.dart` — system calendar:
  `CalendarApi` over the `fah/calendar` MethodChannel (EventKit in
  `MainFlutterWindow.swift`/`AppDelegate.swift` — MIRRORED, edit both;
  entitlement `com.apple.security.personal-information.calendars`, both
  NSCalendars*UsageDescription plist keys); stub = not-available on web.
  Agent tools in `calendar_tool.dart` (registered when
  `calendarPlatformSupported`): `calendar_events {date?, days?}` (rows carry
  recurrence/alarm/url hints), `calendar_calendars` (title, source account,
  writable), and the write-tier `calendar_add` / `calendar_update` /
  `calendar_delete`. Writes support `recurrence`
  ({frequency, interval?, daysOfWeek? MO..SU weekly-only, daysOfMonth?
  monthly-only, until|count — at most one end; validated by
  `parseCalendarRecurrence` in calendar_service.dart, removed on update via
  `'none'`/`{}`), `alarms` (minutes before start; replace-on-update),
  `calendar` (target calendar title), `span` (`this`/`future` → `EKSpan`)
  on update/delete, and `url`. Denial result points to System Settings →
  Privacy → Calendars. The `jsr.fa.calendar` bridge
  (`js_app_engine.dart`) passes the same fields through.
- macOS window chrome: `MainFlutterWindow.swift` uses the modern unified
  titlebar (`titlebarAppearsTransparent`, hidden title,
  `fullSizeContentView`, `toolbarStyle = .unifiedCompact`, window
  background `#070A10`; deployment target 14.0 in `project.pbxproj`), so the
  compact traffic lights float over Flutter content; `MaterialApp.builder`
  in `main.dart` reserves a 28px top strip on macOS so they never overlap
  the app header.
- CodeMie SSO in the app: `lib/services/codemie_sso_flow.dart` — macOS uses
  the CLI flow (local callback server + system browser), iOS drives
  `ASWebAuthenticationSession` through the `fah/web_auth_session` channel in
  `ios/Runner/AppDelegate.swift` (Safari-grade WebAuthn/passkey sign-in —
  an embedded WKWebView cannot offer Face ID without a `webcredentials`
  associated-domain relationship with the IdP; the session intercepts the
  `http://localhost:<port>/?token=` redirect by its `http` scheme, every
  flow page being https). When the session cannot start, the flow falls back
  to `ui/screens/codemie_sso_webview.dart` (in-app `webview_flutter` page
  intercepting the same redirect via its `NavigationDelegate`, password
  login only).
- `flutter_app/lib/services/theme_controller.dart` — ThemeMode
  (system/light/dark) persisted as `theme.json`; the theme itself lives in
  `packages/fa_ui` (`buildFahTheme()` dark + `buildFahThemeLight()`,
  re-exported by the `lib/ui/app_theme.dart` shim), widgets read colors via
  `FahColors.of(context)` (never `FahPalette` directly in widgets).
- `flutter_app/lib/ui/screens/onboarding_screen.dart` — first-launch
  onboarding: 4 pages on every platform (third-party skills are discovered
  by default, so there is no consent page). Pages:
  welcome + AI disclaimer, permissions explainer, privacy
  + policy link via `url_launcher`), page dots, Skip on every page.
  `BootstrapScreen` shows it once only when there is NO restorable
  connection; the seen flag lives in
  `lib/services/onboarding_store.dart` (`onboarding_seen.json`, same
  tiny-store pattern as `theme.json`).
- `flutter_app/lib/services/session_keys_store.dart` — shim re-exporting
  the fa_ui store; in-app secrets:
  on iOS/macOS persisted in the platform Keychain via `keychain_store.dart`
  (the `fah/keychain` MethodChannel, service `fa.app`; file-persisted keys
  migrate once), elsewhere `session_keys.json` via the env (set/delete,
  never displays values); the settings Keys section manages them.
  `provider_registry.dart` custom-provider keys ride the same Keychain
  backend (host-scoped `FA_KEY_<HOST>` names, like the CLI). The Keys
  section's "Add key" dialog saves arbitrary names
  (`^[A-Z][A-Z0-9_]*$`, uppercase-normalized, duplicates rejected);
  `AgentService.create` merges saved keys into the agent secrets — dotenv
  first, saved keys OVERRIDE on conflict (bash env, redactor, system-prompt
  name list all flow from the merged map).
- `flutter_app/lib/services/session_names_store.dart` — user-given session
  titles (`session_names.json` envelope in `ExecutionEnv.cwd`, keyed by
  session id; the session repo has no header-update API, so renames are an
  app-side overlay) plus `derivedSessionTitle(context, id:, createdAt:)` —
  the fallback title the chat sheet uses: a localized
  intl `DateFormat.MMMd(locale).add_Hm()` date+time from the session's
  creation time ("Jul 31 12:30" en / "31 июл. 12:30" ru; `main.dart` calls
  `initializeDateFormatting` for the app locales), `session <id8>` when the
  creation time is unreachable. The rename dialog
  (`flutter_app/lib/ui/widgets/rename_session_dialog.dart`,
  `showRenameSessionDialog`) is opened from the chat sheet's menu
  (Save/Clear; empty clears → the derived name).
- `flutter_app/lib/services/approval_mode_store.dart` — the tool-approval
  mode persisted as `approval_mode.json`; `AgentService.create` seeds
  `approval` from it, `setApprovalMode` writes through (fire-and-forget),
  `clone()` inherits the CURRENT mode (never a fresh read).
- `flutter_app/lib/services/skills_access_store.dart` — the third-party
  skills access setting persisted as `skills_access.json` (same tiny-store
  pattern); `null` = never chose = **granted by default** (opt-out
  discovery — a fresh install reads `.claude`/`.github/skills`/`.codex`
  without asking); a persisted `ask` round-trips verbatim (it is the
  boot-dialog state), `denied` opts out. `AgentService.create` gates
  `discoverSkills` on it
  (`allowedSources: {SkillSource.fah, SkillSource.agents}` unless granted),
  `setSkillsAccess` writes through (fire-and-forget) AND re-discovers the
  prompt's skills section live (no reconfigure needed), `clone()` inherits
  the CURRENT setting. UI: the settings `SkillsAccessSection` dropdown
  (ask/allowed/denied), and the one-time boot dialog in `main.dart`'s
  `BootstrapScreen` (seen-onboarding + explicit `ask` only; Allow persists
  granted, Not now persists DENIED so it never re-asks, a dismissed dialog
  stays `ask`). Both surfaces are desktop-only:
  `skillsConsentSurfacesVisible` (same file, off `defaultTargetPlatform` so
  widget tests can flip it) hides them on Android/iOS — the third-party
  roots don't exist there; discovery gating itself is unaffected.
- `flutter_app/lib/services/analytics.dart` — `AppAnalytics` facade over
  Firebase Analytics (global instance, noop without Firebase; tests install
  a recorder sink): app start, bootstrap outcome, setup shown, connect
  result (provider kind/custom/on-device, success only), provider
  add/edit/delete, models fetch count bucket, suggestion-vs-free-text model
  pick, message sent (attachment flag + length bucket — never content),
  session new/switch/delete, settings opened, key set/delete (names only),
  upload count, screen_opened per screen (the user-path backbone), chat
  sheet state, JS app open/reload, launcher folders/tiles/grid, theme +
  approval mode, model presets, media slot set/generated, voice input,
  secret request outcome, files opened. Privacy rule: never keys, message
  text, or file contents. `test/analytics_guard_test.dart` hard-fails on a
  screen/composer/sheet file without an `AppAnalytics.instance` call (or a
  documented exemption) and on facade events never called from lib/ —
  keep both sides wired.
  Crashlytics (`firebase_crashlytics`, wired in `main.dart`: fatal Flutter
  errors + uncaught async + debugPrint breadcrumbs) NEEDS
  `GoogleService-Info.plist` bundled in the Runner target — both
  pbxproj files carry the reference (gitignored file, CI writes it from
  `GOOGLE_SERVICE_INFO_PLIST_BASE64`) plus a "Crashlytics: upload dSYMs"
  build phase and `dwarf-with-dsym` in Release; settings has a
  "Send test crash report" row (non-fatal recordError) to verify the
  pipeline from a device.
- `flutter_app/lib/services/last_connection.dart` — persists last connection
  (never API keys) as `last_connection.json`; at boot `restorableBootConfig`
  (main.dart) rebuilds the AgentConfig (custom-provider key → saved hosted
  key) for the auto-connect, else it pre-selects the settings form.
- `flutter_app/lib/services/vision_models.dart` — shim re-exporting the
  `modelIdSuggestsVision` heuristic (fa_ui shim → the pure-Dart core
  `lib/src/model_roles/vision_models.dart`), which fills `Model.input`;
  `AgentConfig.supportsImages` overrides;
  without `image` the `read` tool notes non-vision and adapters drop image
  blocks.
- `flutter_app/lib/services/media_tools.dart` — `MediaGateway` over the
  `media_models.json` slots (+ main-connection fallback) backing the
  `generate_image`/`speak`/`generate_music`/`generate_video` tools and the
  `jsr.fa.media.*` bridge; files land in `generated/`. `generate_video`
  rides the `videoGeneration` slot (required — no fallback): async
  OpenAI/OpenRouter `/videos` contract (POST job → poll `GET /videos/{id}`
  every 3s, 4-min cap, cancel-token aware → `unsigned_urls` or
  `GET /videos/{id}/content` mp4). Google (`generativelanguage`) endpoints
  switch to the native Gemini protocol by baseUrl: `speak` posts
  `/models/{model}:generateContent` (`x-goog-api-key` auth, LINEAR16 PCM
  24 kHz mono wrapped into a `.wav`), `generate_music` posts
  `/interactions` with `{model, input}` and deep-searches the response for
  base64 audio; the image/video slots answer an honest "not supported for
  the Google provider yet" error.
- `docs/subagents/` — the subagents-2.0 + long-term-memory master plan
  (phased: memory package publish, memory foundation, memory-aware
  compaction, session-backed retained subagents, agent-type menu); update
  the checklists there as work lands.
- `site/` — static GitHub Pages landing; `.github/workflows/pages.yml`
  builds the web demo into `app/` (never committed). `site/privacy.html`
  is the published privacy policy (`PRIVACY.md` in the repo root is the
  source text — keep both in sync; the onboarding privacy page links to
  `https://fa1.dev/privacy.html`).
- `scripts/` — codegen and quality-gate scripts.

## Hard architecture rules

- `lib/` is pure Dart: **no `dart:io`** (must compile for web). The only
  `dart:io` entry points are `bin/` and `lib/io.dart`; file/process/network
  behind tools goes through the `ExecutionEnv` abstraction.

## Golden tests are MANDATORY for UI work

Any change to `flutter_app/lib/` UI code is INCOMPLETE until its golden
tests are done right:

1. **Coverage first.** New widget file → tests in
   `test/golden/<area>_golden_test.dart` + map entry in
   `golden_guard_test.dart` (hard-fails otherwise). Changed visuals →
   regenerate affected snapshots.
2. **Real fonts.** `setUpAll(ensureGoldenFonts)` in every golden file;
   placeholder-box glyphs = garbage, redo.
3. **Full frames.** Snapshots are marketing material: full app frames
   (`goldenSizeDesktop` 1280x800, `goldenSizePhone` 390x844) with realistic
   content — never a widget floating on black void.
4. **Determinism.** Fixed data/timestamps, existing-test fakes, no
   network/engines/infinite animations.
5. **Eyes on pixels.** After `--update-goldens`, OPEN every changed PNG
   (no tofu, no overflow, legible buttons/icons) before committing.
6. **Green gate.** `flutter test test/golden` passes; pre-commit runs it +
   `scripts/check_goldens.py` (which also hard-fails on ORPHAN snapshots —
   committed PNGs no test references; delete stale files, never let them
   rot in git history).

## Prompts live outside Dart code

- Every LLM prompt is a Markdown file under `prompts/**` (example app:
  `flutter_app/prompts/`). Never prompt string literals in `.dart` files.
- Format: YAML frontmatter (`name`, `description`) between `---` lines,
  then body; runtime placeholders are `{{name}}` tokens.
- After editing a prompt: `dart run scripts/gen_prompts.dart` rewrites
  `lib/src/prompts/prompts.g.dart` + `flutter_app/lib/prompts.g.dart`
  (generated, never edit by hand); `test/prompts/prompts_sync_test.dart`
  gates drift.
- Bundled Codex model catalog
  (`lib/src/providers/chatgpt_codex_models_data.dart`) is generated from
  `codex-rs/models-manager/models.json` via
  `dart run scripts/sync_codex_models.dart`. Re-run the script when
  codex-rs ships a new catalog so the picker / OAuth default stay current
  without a manual edit.

## Quality gates (pre-commit hook: `scripts/pre-commit`)

- `dart analyze` + `dart format --set-exit-if-changed lib test bin example
  scripts flutter_app packages` clean (explicit dirs — `yoclip/` is a
  standalone video workspace with its own toolchain); example app also
  `flutter analyze --no-fatal-infos --no-fatal-warnings`.
- `dart test` green (integration-tagged excluded — they run in CI).
- `cd flutter_app && flutter test --exclude-tags integration` green
  (includes golden suite; integration-tagged `test/cli_visual` runs on
  demand) + `scripts/check_goldens.py --quick`.
- Line coverage of `lib/` ≥ 80%; jscpd duplication < 1% core `lib/`,
  < 2.2% `flutter_app/lib/` (ratchet — only tighten).
- CRAP ratchet (`crap4dart analyze`, config `crap4dart.yaml`, tool pinned
  as `dart pub global activate crap4dart 0.2.1`): the threshold is the
  current repo max — only down from here; runs after the coverage step in
  pre-commit and in the `ci.yml` quality job.
- Max 2800 lines per `.dart` file (`*.g.dart` exempt).

## Cross-platform parity

Every shared setting and interactive prompt type must exist on BOTH the CLI
(`lib/src/cli/`) and the Flutter app (`flutter_app/lib/`) unless it is
**fundamentally impossible** on the target platform. When a setting or prompt
type is platform-only (e.g. MCP servers need process spawning — impossible on
web), it MUST be explicitly listed in `cliOnlySettings` or `appOnlySettings`
in `lib/src/parity/settings_registry.dart` with a comment explaining WHY.

**Workflow when adding a new setting or interactive type:**
1. Add it to `SharedSetting` enum in `settings_registry.dart` FIRST
2. Implement on BOTH platforms (CLI + Flutter app)
3. If one platform genuinely cannot support it: add to the exemption set
   with a one-line reason comment
4. Run `dart test test/parity/` — the parity guard must pass

## Commits and releases

- Commit identity: human/AI contributors commit as `ai.teammate
  <agent.ai.native@gmail.com>` (history was rewritten to it — set
  `git config user.name ai.teammate` + `git config user.email
  agent.ai.native@gmail.com` repo-locally). Release commits from
  `scripts/auto_release.sh` stay `github-actions[bot]`.
- Commit subjects: `type(scope): ...` (`feat:`, `fix:`, `fix(example):`,
  `ci:`, `test(providers):`, `refactor(prompts):`).
- Every push to `main` auto-releases a patch to pub.dev
  (`scripts/auto_release.sh` via `ci.yml`) — intended.
- CLI binaries build per tag (`ci.yml` `binaries` job), attach to the
  GitHub Release (`fa-<os>-<arch>[.exe]`); `installer-smoke` verifies
  installers.
- App builds (`build-mobile.yml`, `build-macos.yml`, manual dispatch):
  Android AAB + iOS IPA on `[self-hosted, macOS, ARM64]`, macOS DMG/ZIP
  signed + notarized, TestFlight via `flutter_app/fastlane`. Optional
  secrets: `APP_STORE_CONNECT_KEY_ID/_ISSUER_ID/_KEY_CONTENT`,
  `MACOS_INSTALLER_P12_BASE64/_PASSWORD/MACOS_INSTALLER_CERT_ID`,
  `GOOGLE_SERVICE_INFO_PLIST_BASE64`. Both workflows hard-gate the binary
  on wasm_run FFI exports (`xcrun dyld_info -exports` must list
  `_wire_compile_wasm` — Podfiles force-load + `-exported_symbol` +
  `STRIP_STYLE=non-global`, else white screen on TestFlight). Pods cached
  keyed by `Podfile.lock`.
- App Store content pipeline (no binary): store screenshots are COMMITTED
  goldens from `flutter_app/test/golden/store_screenshots_test.dart` (frame +
  inline en/ru copy in `store_marketing_frame.dart`) at
  `flutter_app/test/goldens/store/{en,ru}/{ios,ipad,mac}/` — regenerate with
  `flutter test test/golden/store_screenshots_test.dart --update-goldens`,
  then open every PNG. Store copy lives in
  `flutter_app/fastlane/metadata/{ios,macos}/{en-US,ru-RU}/` (the lanes strip
  name.txt/subtitle.txt — App Info is not editable post-release); release
  notes come from the latest `## […]` section of
  `store_artefacts/metadata/{en,ru}/changelog.md`. Upload: `fastlane ios
  app_store` / `fastlane mac app_store` in `flutter_app` (env gates
  `IOS_DEPLOY_METADATA`/`IOS_DEPLOY_SCREENSHOTS`/`MACOS_DEPLOY_*`; ASC API key
  env secrets) or the `store-metadata.yml` workflow (`ios_content`/
  `macos_content` inputs: none/metadata_only/screenshots_only/all).
