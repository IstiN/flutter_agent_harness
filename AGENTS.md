# AGENTS.md

Conventions for AI agents and contributors in this repository. Keep it
factual: paths, commands, invariants — no essays.

## Project layout

- `lib/` — the `flutter_agent_harness` package (pure Dart core). `test/`
  mirrors it. `prompts/` — all LLM prompts as Markdown (see rules below).
- `lib/src/approval/` — tool approval gate: tiers (read/write/exec),
  session modes (always-ask/write/yolo), per-tool overrides, critical-pattern
  `bash` interceptor. Wired via `attachApproval` into `beforeToolCall` (runs
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
  mid-turn take-over (`FallbackStreamFunction`, never silent). Config:
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
- `lib/src/skills/skills.dart` — agent skills: `<root>/<name>/SKILL.md`,
  roots project (`.fah/skills`, `.agents/skills`) > user (`~/.fah/skills`,
  `~/.agents/skills`), first-name-wins. Only metadata enters the system
  prompt; bodies loaded with `read` through the env.
- `lib/src/prompts/project_context.dart` — `AGENTS.md`/`CLAUDE.md`/`GOAL.md`/
  `DESIGN.md` auto-merged into the system prompt: cwd → git root,
  farthest-first, `<!-- From: -->` annotations, 32 KiB leaf-first budget;
  optional `~/.fah/AGENTS.md` first. CLI: `/skill:<name> [args]`, `/skills`.
- `lib/src/task/` — `task` tool: parallel subagents, batch form
  `{context, tasks[]}` + `background` flag; children never get `task` (no
  nesting); roles: `explore`→`smol`, `review`→`slow`; `outputSchema` with
  ONE fix retry; child failure = per-item error, never batch failure.
  `/tasks` lists jobs, `/tasks cancel <id>`; completions re-enter the parent
  as async-result messages (`agent://<id>` refs).
- `bin/fah.dart` — the `fah`/`fa` CLI. REPL (no args) or headless
  (`fa "prompt"` / `-p`, mutually exclusive). First positional naming an
  EXISTING file is the prompt source (`.md`/`.txt` inlined, others attached
  by reference; `-p` is verbatim). Args parsed in `lib/src/cli/cli_args.dart`
  (pure Dart). Headless: exit 0/1/130; `CliIO` contract — `write` = primary
  stream, `writeln` = diagnostics (stderr headless).
- `lib/src/cli/` — REPL machinery: `/provider [name] [baseUrl] [token] |
  custom` (guided wizard in `provider_flow.dart` + `provider_commands.dart`;
  `/models` fetched for openai-like endpoints), custom providers in the
  `customProviders:` section of `~/.fah/config.yaml`. `/models` also manages
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
  (Provider, Edit/delete provider, Chat model, Model parameters, Approval
  mode, Agent mode, API keys, MCP servers) launch the same flows the
  dedicated slash commands open; line mode prints a summary.
- `lib/src/prompts/prompt_overrides.dart` — `prompts:` config section maps
  prompt names to file path or inline text; strict validation; flags
  `--system-prompt(-file)` > config > built-in.
- `lib/src/cli/cli_help.dart` — full `fah --help` text, guarded by
  `test/cli/cli_help_test.dart` (update BOTH).
- `lib/src/web_search/` — `web_search` (DDG keyless → Brave/Tavily keyed)
  and `web_fetch` (HTML→markdown, pub.dev handler) via
  `builtinTools(env, webSearch:)`.
- `lib/src/model_roles/provider_catalog.dart` — provider table; specs
  default `input: ['text','image']` (vision).
  `lib/src/model_roles/vision_models.dart` — the shared vision heuristic
  (`modelIdSuggestsVision`, `visionMarker` picker checkmark,
  `inputModalitiesFor`): CLI model switches recompute `Model.input` from it
  and the model pickers show the ✓/✗ marker; `packages/fa_ui` re-exports it
  (one marker list for CLI and app).
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
  `modelIdSuggestsVision`). The chat leaf widgets live there too
  (`lib/src/chat/`): the Markdown style/sandbox image resolver
  (`markdown_style.dart`), the inline audio/video players
  (`media_player.dart`), the approval/ask/secret-request sheets, the
  transcript message tile (`chat_message_tile.dart`), the composer
  (`chat_composer.dart` — file/gallery/camera picking through the
  `FaChatHost.uploadPicker`/`galleryPicker`/`cameraPicker` hooks, voice
  input through `FaChatHost.voiceInput`), and the single-service chat
  screen (`fa_chat_screen.dart` — `FaChatScreen(service:, features:,
  title:, settingsBuilder:, fileBrowserBuilder:, composerBuilder:)`),
  plus the upload helpers
  (`upload_utils.dart`) and the media tool-name constants
  (`media_tool_names.dart`) —
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
  `asrTranscriber` test fakes) and bridges it to the shared composer's
  hooks: the `UploadPicker` becomes a `FaChatUploadPicker`, gallery/camera
  come from `image_picker`, and the ASR stack is wrapped in a
  `FaChatVoiceInput` (transcriber resolved per take via the session's
  media gateway, falling back to the active provider).
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
- `flutter_app/lib/apps/session_chat_sheet.dart` — the session chat bottom
  sheet over the launcher (FaChatOverlay pattern/constants): collapsed =
  floating Fa button bottom-right (the `FaWorkBar` takes its place while
  streaming); expanded = 92% sheet with drag-handle header (session title
  via `SessionNamesStore`, 3-dots menu: New session / Rename session /
  Open full chat / Collapse — Rename opens the shared rename dialog
  `showRenameSessionDialog`), a horizontal PageView over `manager.sessions` wired to
  `manager.switchTo`, `FaWorkBar(embedded:)`, and the shared
  `ChatMessageTile` transcript + `ChatComposer`. Pull-down (48px / 300px/s)
  collapses.
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
  sealed for future custom/on-device targets.
- `flutter_app/lib/sandbox/sandbox_registry.dart` — central registry of
  sandbox shell commands per platform; the Fa system prompt's `{{commands}}`
  renders from it. Never list commands in prompt text or UI by hand.
- `flutter_app/lib/services/project_mount_env.dart` — macOS project-folder
  mount (`/project` → user-picked host dir; security-scoped bookmarks in
  `project_mount.json`; stale bookmark = "pick again" warning).
- `flutter_app/lib/apps/` — JS apps platform on `package:js_widget_runtime`
  (git-pinned to IstiN/flutter_js_widget_runtime@9498d0c — the queued-
  callEvent-after-dispose guard + restart-safe bridge channels; the
  use-after-free SIGSEGV is owned by `js_app_engine.dart`'s process-wide
  lifecycle serialization — releases must stay immediate, never deferred —
  until a pub release >0.4.20 ships both; ≥0.4.5 adds the `map` node: center/zoom/markers/polylines/
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
  the macOS channel answers unsupported): `listHomes`/`listRooms`/
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
- `flutter_app/lib/services/theme_controller.dart` — ThemeMode
  (system/light/dark) persisted as `theme.json`; the theme itself lives in
  `packages/fa_ui` (`buildFahTheme()` dark + `buildFahThemeLight()`,
  re-exported by the `lib/ui/app_theme.dart` shim), widgets read colors via
  `FahColors.of(context)` (never `FahPalette` directly in widgets).
- `flutter_app/lib/ui/screens/onboarding_screen.dart` — first-launch
  onboarding: 4 pages (welcome + AI disclaimer, permissions explainer, model
  preset mini-wizard reusing `kModelPresets`/`applyModelPreset` with a null
  service — the combo persists as the last connection boot restores, privacy
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
