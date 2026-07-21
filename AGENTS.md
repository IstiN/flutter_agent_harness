# AGENTS.md

Conventions for AI agents and contributors working in this repository.

## Project layout

- `lib/` — the `flutter_agent_harness` package (pure Dart core).
- `lib/src/approval/` — the tool approval gate: capability tiers
  (read/write/exec, exec for undeclared tools) on `AgentTool`, session modes
  (always-ask/write/yolo), per-tool allow/deny/prompt overrides, and the
  critical-pattern `bash` interceptor. Wired into the agent's
  `beforeToolCall` phase via `attachApproval` (composes with user hooks,
  approval runs first); the prompt UI is an injectable `ApprovalPrompt`
  callback (null callback + prompt policy = deny).
- `lib/src/tools/ask_tool.dart` — the `ask` tool (ported from oh-my-pi):
  structured mid-turn questions (labeled options, optional multi-select and
  a recommended index/label) answered by the host through an injectable
  `AskCallback` (same host-callback pattern as `ApprovalPrompt`). A null
  callback yields an error result ("host cannot answer"); a cancelled dialog
  yields a plain "ask cancelled by user" result. The CLI renders a stdin
  menu, the example app a modal bottom sheet (`ask_ui.dart`); both register
  the tool next to `builtinTools`.
- `lib/src/tools/checkpoint_tool.dart` — the `checkpoint`/`rewind` tools
  (ported from oh-my-pi): self-service context hygiene for exploratory
  detours. `checkpoint(goal?)` writes a `CheckpointRecord` (message-count
  anchor + goal) to the session tree; `rewind(report)` prunes the live
  transcript back to the mark at turn end (the report is kept verbatim as a
  hidden `rewind-report` custom message + a `branch_summary` record; the
  dropped detour stays in the tree). The `CheckpointRewindController`
  subscribes to agent events (capture on the checkpoint tool-result message,
  apply on turn end), wraps `Agent.prepareNextTurn` so the run continues
  with the pruned context, and drives anchor persistence through the
  host-provided `CheckpointSessionSink` (the CLI wires it next to
  `builtinTools`; `/reset` clears it).
- `lib/src/compaction/branch_summarization.dart` — branch summaries for
  session-tree navigation (ported from oh-my-pi): `generateBranchSummary`
  reuses the compaction `SummarizeFn` + fixed structured prompt to summarize
  an abandoned branch (preamble + `<read-files>`/`<modified-files>` tags),
  and `navigateSessionTree` wires it into branch switches — the summary is
  written as a `branch_summary` record on the branch being entered (call it
  instead of `Session.moveTo` when exposing tree navigation).
- `lib/src/hashline/` — the hashline patch language (ported from oh-my-pi
  `packages/hashline`): `[path#TAG]` section headers with a 4-hex whole-file
  content hash (xxHash32, ported in `xxhash32.dart`), `SWAP`/`DEL`/`INS.*`
  line-range ops, the per-session `HashlineSnapshotStore`, and the
  all-or-nothing `HashlinePatcher` over `ExecutionEnv`. Stale tags reject
  before any write. omp's tree-sitter block ops (`*.BLK`), file ops
  (`REM`/`MV`), boundary-repair leniency, and diff-based stale-anchor
  auto-remap are deliberately not ported. Wired into the built-in tools in
  `lib/src/tools/builtin_tools.dart`: `edit` accepts a `patch` argument
  (hashline mode) next to legacy `oldText`/`newText`, and `read` gains a
  `hashline` flag emitting numbered lines + the tag header; both share one
  session snapshot store via `builtinTools`.
- `lib/src/tools/read_selector.dart` — the `read` tool's trailing-selector
  grammar (ported from oh-my-pi `path-utils.ts`/`read.ts`): `:N`/`:A-B`/
  `:A+C` line ranges (`..` alias, `L` prefixes), comma-merged multi-ranges,
  and `:raw` (verbatim: no line numbers/hashline header/notices), compound
  in either order. `offset`/`limit` args map onto the same pipeline and must
  not be combined with a selector; a literal file named e.g. `test:1-2`
  wins over the selector (`splitPathAndSelPreferringLiteral`). omp's
  `:conflicts` selector and the 1+3 context-line expansion are not ported.
- `lib/src/tools/archive_reader.dart` — archive inner-path reads for `read`
  (`archive.zip:inner/entry`, also `.tar`, `.tar.gz`/`.tgz`) on
  `package:archive` (pure Dart). Whole-archive decode in memory (256 MiB
  cap, 64 MiB per member); listings, member reads through the shared text
  pipeline, binary members yield a note. omp's JVM/Android zip aliases are
  not recognized.
- `lib/src/tools/sqlite/` — SQLite targets for `read` (ported from omp's
  `sqlite-reader.ts`): `db.sqlite`, `:table` (schema+samples), `:table:key`
  (PK/rowid), `:table?limit/offset/order/where`, and `?q=SELECT` raw,
  rendered as width-capped ASCII tables. `sqlite_reader.dart` is pure Dart
  behind the `SqliteEngine` interface (detection by extension + existence;
  omp's magic-header sniff is skipped to keep reads lazy); the FFI engine
  (`sqlite3_engine.dart`, `package:sqlite3`) is exported only from
  `lib/io.dart` and passed via `builtinTools(env, sqlite: ...)` — hosts
  without it (web) get a clean "not supported" note.
- `lib/src/lsp/` — the `lsp` tool (diagnostics/definition/references/rename,
  ported reduced from oh-my-pi `packages/coding-agent/src/lsp/`): a
  pure-Dart LSP JSON-RPC client (`lsp_client.dart` — initialize handshake,
  didOpen/didChange/didClose with version tracking, publishDiagnostics
  cache, server-request replies; omp's write queue, `$/progress` tracking,
  lspmux, and rust-analyzer polling are not ported) over an abstract
  `LspTransport` (`lsp_transport.dart`); `lsp_framing.dart` ports the
  Content-Length framer with junk-header resync. `lsp_config.dart` keeps
  the extension→server map in omp's `defaults.json` shape (built-in:
  `.dart` → `dart language-server --protocol=lsp`; projects merge
  `.fah/lsp.json` field-wise, JSON only — omp's YAML/user/plugin sources
  are not ported) and resolves workspace roots by walking root markers.
  `lsp_manager.dart` owns the lifecycle: lazy start per server:root, idle
  shutdown (default 5 min, omp disables it), crash drop + respawn bounded
  by quick-crash counting and a 3-minute init-failure backoff.
  `lsp_edits.dart` applies rename WorkspaceEdits through the ExecutionEnv
  all-or-nothing (validate + version-guard + in-memory apply of every file
  before any write), so barrel files and imports update atomically;
  resource ops (create/rename/delete) are reported-skipped, not applied.
  The `dart:io` process transport (`io_lsp_transport.dart`) is exported
  only from `lib/io.dart`; the tool registers via
  `builtinTools(env, lsp: LspToolConfig(...))` on process-capable hosts
  (the CLI passes `ioLspTransportFactory` + the host pid), web leaves it
  out. Ops take 1-indexed `line`/`character`; a missing server binary or
  unmatched extension yields a clean text result, never a crash.
- `lib/src/model_roles/` — intent-based model roles (`default`/`smol`/
  `slow`/`plan`, exact omp names) with ordered fallback chains, key
  rotation, and path-scoped overrides (ported, reduced, from oh-my-pi's
  model-resolver/model-roles + non-compaction-retry-policy):
  `roles_config.dart` (`ModelRolesConfig`/`ModelRef`/retry policy/yaml),
  `key_rotation.dart` (`ApiKeyRing`: round-robin over stacked keys
  `NAME`/`NAME_2`/… with per-key backoff and session affinity),
  `fallback_stream.dart` (`FallbackStreamFunction`: mid-turn take-over on
  429/quota — rotate keys free, same-entry backoff retries, then next chain
  entry; every step announced via `FallbackNotice`, never silent; context
  overflow stays with compaction), `provider_catalog.dart` (provider table
  + `providerStreamFunction`), `model_resolver.dart` (`ModelRolesResolver`:
  applies a role to an `Agent` per run, `smol` for compaction summaries,
  skipped-uncredentialed-entry reporting). Config lives in the
  `roles:`/`modelOverrides:`/`retry:` sections of `~/.fah/config.yaml`
  (invalid roles schema throws `ConfigException`, never silently resets).
- `lib/src/ttsr/` — time-traveling stream rules (ported from oh-my-pi's
  TTSR, regex conditions only — no ast-grep/globs/interruptMode): user or
  project rules carry regex patterns matched against streaming
  text/thinking/tool-call deltas (`TtsrManager`: cumulative per-stream
  buffers, full rescan per delta so patterns split across chunks still
  match). On a match the `TtsrController` (subscribed to agent events,
  omp's `AgentSession` role) aborts the generation mid-stream, drops or
  keeps the partial per `contextMode`, injects the rule bodies as a hidden
  `<system-interrupt>` reminder user message (`prompts/ttsr/interrupt.md`),
  and retries with `Agent.continueRun` after `retryDelay` (omp's 50ms).
  Injections persist through the host-provided `TtsrSessionSink` as a
  `ttsr-injection` custom message (projects into context, survives
  compaction) plus a `ttsr_injection` record of rule names
  (`readPersistedTtsrInjections` → `restoreInjected` on resume). Guards:
  once-per-session repeat policy (omp default; `after-gap` optional) and a
  `maxInjectionsPerTurn` chain cap (ours, not omp's). Config: the `ttsr:`
  section of `~/.fah/config.yaml` (settings + rules; invalid schema throws
  `ConfigException`) merged with project rules from `.fah/rules.yaml`
  (project first, name clashes first-win); programmatic hosts instantiate
  `TtsrManager` + `TtsrController` directly. The CLI wires it next to the
  checkpoint controller, awaits `TtsrController.settled` before run-end
  persistence, and `/reset` clears it.
- `lib/src/task/` — the `task` tool: parallel subagents with
  schema-validated results (ported, reduced, from oh-my-pi
  `packages/coding-agent/src/task/`). The wire shape is omp's batch form
  `{context, tasks[]}` plus a per-call `background` flag (omp's
  `async.enabled` made host-neutral); no flat shape, no `isolated`
  (copy-based sandboxes are a follow-up). `task_tool.dart` has
  `taskTool`/`TaskToolConfig` (one per session: the `Semaphore`,
  `AgentOutputStore`, and `TaskJobManager` are session-scoped through it)
  and the background job surface — omp injects completions into the parent
  conversation as async results, here the host wires
  `TaskJobManager.completions` to do that. The CLI wires it in
  `agent_cli.dart`: the `task` tool is registered with the core tool
  surface as `childTools`, and every settled job prints a dim transcript
  notification and re-enters the parent conversation as an async-result
  message (`<system-notice>` + `<task-result>` envelope, `agent://<id>`
  pointer, 4k preview cap) — steered mid-run, or re-woken as a fresh run
  while idle (omp's aside/idle-flush paths). Monitoring: the `/tasks`
  slash command lists jobs (`○/⠿/✓/✗` + elapsed + `agent://` ref,
  `/tasks cancel <id>` aborts a child) and the status line carries a
  `bg:N` badge while jobs are active (kimi's toolbar badge). Headless
  runs wait for in-flight jobs plus their re-wake reactions (kimi's
  print-mode, capped at 10 rounds). The config captures the startup
  model — later `/model` switches don't propagate to children (role
  resolution still applies).
  `task_executor.dart` runs each item as a child `Agent` with a restricted
  tool surface (the registry never hands children `task`: no nesting),
  resolves cheap models per agent type through `ModelRolesResolver`
  (`explore`→`smol`, `review`→`slow`, else inherit), and validates
  `outputSchema` output with the param-validation subset — ONE fix retry,
  then an error entry (omp's strict outcome; its `schemaMode` split is not
  ported). `agent_registry.dart` holds the built-in types (`task`, `explore`
  = omp's read-only `scout`, `review` = omp's `reviewer` made read-only)
  plus host overrides; filesystem discovery is a follow-up.
  `output_manager.dart` ports the `AgentOutputManager` id allocator
  (`Name`, `Name-2`, nested `Parent.Child`), the in-memory session store
  (on-disk artifacts are a follow-up), and the `agent://` resolver subset:
  `agent://<id>`, `agent://<id>/<child>`, and dot-path JSON extraction
  (`agent://<id>/findings.0.path`, `?q=`). Guards: a child failure is a
  per-item error entry, never a batch failure; the parent cancel token
  aborts every child and semaphore waiter.
- `bin/fah.dart` — the `fah`/`fa` CLI executable. Two invocation shapes:
  interactive REPL (no prompt arguments) and headless mode (`fa "prompt"`,
  positional arguments joined with spaces, or `-p`/`--prompt <text>` —
  positional and `-p` together are an error). Argument parsing lives in
  `lib/src/cli/cli_args.dart` (`parseCliArgs` → `CliArgs`/`CliArgsHelp`/
  `CliArgsVersion`, `CliArgsException` on invalid input — pure Dart, unit
  tested; the executable maps it to output/exit codes). A first positional
  naming an EXISTING file is the prompt source, resolved by
  `resolveHeadlessPrompt` in `lib/src/cli/headless_prompt.dart` (`dart:io`,
  exported only from `lib/io.dart`, next to `cli_config.dart`): text files
  (`.md`/`.markdown`/`.txt`, case-insensitive) are inlined as the prompt,
  any other file becomes a `[attached file: <abs path> — read it with your
  tools]` reference, trailing positionals append as the instruction in both
  cases, an unreadable/undecodable text file falls back to the path
  reference, and a non-existent path is plain prompt text (never an error).
  `-p` text is used verbatim (never resolved as a file). Headless runs go
  through `AgentCli.runHeadless`: no banner/prompt/slash commands, the
  session persists like a REPL turn (same `_afterRun`: TTSR settle, batch
  persistence, auto-compaction), exit code 0 ok / 1 provider error / 130
  aborted (read from the final assistant message's stopReason). The
  stdout/stderr split is the `CliIO` channel contract: `write` is the
  primary stream (assistant text — the trailing newline after streamed text
  is a `write`, never a `writeln`), `writeln` is diagnostics (tool
  indicators, approval/TTSR/roles notices, errors); the terminal IO merges
  both on stdout interactively and routes `writeln` to stderr in headless
  mode, and headless is never interactive (approval/ask resolve per the
  non-interactive rule, terminal or not).
- `lib/src/prompts/prompt_overrides.dart` — prompt overrides (pure Dart):
  the `prompts:` section of `~/.fah/config.yaml` maps prompt names to a
  file path OR inline text, replacing built-in prompts. Names mirror the
  `prompts/` tree ids — `system` (alias for `cli/mode_code`), `cli/mode_*`,
  `compaction/*` (see `overridablePromptNames`). `parsePromptOverrideMap`
  validates strictly (`ConfigException` on unknown names, non-string
  values, or the alias pair together); `PromptOverrides` resolves
  name → text at the consumption points — the CLI modes
  (`builtInAgentModes(..., overrides:)`, startup + `/mode` switches) and
  the compaction prompts (`CompactionPrompts.fromOverrides` in
  `lib/src/compaction/compaction.dart`, threaded through
  `streamFunctionSummarizer`/`generateSummary`/`CompactionManager`). File
  reads live in `lib/src/cli/prompt_overrides_io.dart` (`dart:io`, exported
  only from `lib/io.dart`): a value is a file when it starts with `/`,
  `~/`, `./`, `../` or ends in `.md`/`.markdown`/`.txt` (`~` expands,
  relative paths resolve against the agent cwd, frontmatter stripped, a
  missing file is a hard `ConfigException`); anything else is inline text.
  The `--system-prompt`/`--system-prompt-file` flags (mutually exclusive)
  override the system prompt per invocation: flag > config > built-in.
  `CliConfig.promptOverrides` keeps the raw map (round-tripped verbatim);
  `AgentCliConfig.promptOverrides` carries the resolved one.
- `lib/src/cli/cli_help.dart` — the full `fah --help` reference
  (`cliHelpText`): every flag, provider/key, config section (`roles:`,
  `modelOverrides:`, `retry:`, `ttsr:`, `prompts:`), approval mode, session
  feature, tool, and plugin, guarded by `test/cli/cli_help_test.dart` (add
  new flags/keywords there AND in the text). Terminal output, not an LLM
  prompt — it is not under `prompts/`.
- `lib/src/web_search/` — the `web_search`/`web_fetch` tools (ported from
  oh-my-pi `packages/coding-agent/src/web/`): `web_search` walks a provider
  chain (keyless DuckDuckGo HTML first, keyed Brave/Tavily when their key is
  in the `SecretsStore`), falling through on failure; `web_fetch` renders
  pages as markdown via site handlers behind one `WebSiteHandler` interface
  (pub.dev shipped; GitHub/arXiv follow-ups) with a hand-rolled generic
  HTML→markdown converter (link anchors preserved, boilerplate stripped).
  All HTTP goes through an injectable `package:http` client; both tools
  register via `builtinTools(env, webSearch: WebSearchConfig(...))`.
- `example/flutter_example/` — Flutter chat example (mobile/web sandbox).
- `site/` — static GitHub Pages landing (hand-rolled HTML/CSS/JS, no build
  step). `.github/workflows/pages.yml` builds the Flutter web demo into
  `app/` inside the Pages artifact (never committed) and deploys on pushes
  touching `site/`, `example/`, `lib/`, or `vendor/`.
- `prompts/` — all LLM prompts as Markdown (see below); `test/` mirrors `lib/`.
- `example/flutter_example/lib/sandbox_registry.dart` — the central registry
  of sandbox shell commands per platform (web/mobile/desktop). The shells
  resolve against its name sets, and the Fa system prompt's `{{commands}}`
  placeholder is rendered from it (`AgentService`). Never list commands in
  prompt text or UI by hand.
- `example/flutter_example/lib/last_connection.dart` — the
  `LastConnectionStore`: persists the last successful connection
  (provider/model/URL/on-device preset — never API keys) as
  `last_connection.json` via the shared ExecutionEnv (same pattern as
  `ProviderRegistry`). Written on every setup-screen connect and
  settings-dialog apply; read at boot to pre-select the settings form (an
  on-device model no longer cached/installed falls back to the default
  preset with a "previously used model was removed" note).
- `example/flutter_example/lib/downloaded_models_quick_start.dart` — the
  setup screen's "Downloaded models" section above the connection form:
  one row per already-cached/installed on-device model (WebLLM +
  transformers.js CacheStorage, flutter_gemma repository — the same engine
  cache queries as the settings cache sections, never warming the engines),
  each with a one-tap "Use" that loads the model and connects immediately.
  Hidden while scanning and when empty; the Gemma repository scan runs on a
  state-owned cancellable timer (a wedged plugin must not pin the section or
  leak a pending timer).
- `scripts/` — codegen and quality-gate scripts.

## Hard architecture rules

- `lib/` is pure Dart: **no `dart:io`** (it must compile for web). The only
  `dart:io` entry points are `bin/` and `lib/io.dart`; file, process, and
  network access behind the agent's tools goes through the `ExecutionEnv`
  abstraction.

## Prompts live outside Dart code

- Every LLM prompt is a Markdown file under `prompts/**` (example app:
  `example/flutter_example/prompts/`). Never write prompt string literals in
  `.dart` files — prompts must be findable and reviewable as Markdown.
- File format: YAML frontmatter between `---` lines (`name`, `description`),
  then the prompt body verbatim. Runtime placeholders are `{{name}}` tokens
  (e.g. `{{cwd}}`) substituted by the consuming Dart code.
- After editing a prompt, regenerate and commit the compiled constants:
  `dart run scripts/gen_prompts.dart` rewrites `lib/src/prompts/prompts.g.dart`
  and `example/flutter_example/lib/prompts.g.dart` — generated files, never
  edit by hand.
- `test/prompts/prompts_sync_test.dart` reruns the generation and fails the
  test gate on any drift.

## Quality gates (pre-commit hook: `scripts/pre-commit`)

- `dart analyze` and `dart format --set-exit-if-changed .` clean.
- `dart test` green (integration-tagged tests excluded; they run in CI).
- Line coverage of `lib/` ≥ 80%; jscpd duplication < 1%.
- Max 2800 lines per `.dart` file (`*.g.dart` exempt).
- Example app: `cd example/flutter_example && flutter test`.

## Commits and releases

- Commit subjects follow `type(scope): ...` — e.g. `feat:`, `fix:`,
  `fix(example):`, `ci:`, `test(providers):`, `refactor(prompts):`.
- Every push to `main` triggers an automatic patch release to pub.dev
  (`scripts/auto_release.sh` via `.github/workflows/ci.yml`) — intended.
