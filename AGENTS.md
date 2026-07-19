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
- `bin/fah.dart` — the `fah`/`fa` CLI executable.
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
