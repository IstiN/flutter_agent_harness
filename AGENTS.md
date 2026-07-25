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
- `lib/src/model_roles/` — model roles (`default`/`smol`/`slow`/`plan`) with
  fallback chains, key rotation (`ApiKeyRing` over `NAME`/`NAME_2`/…), 429
  mid-turn take-over (`FallbackStreamFunction`, never silent). Config:
  `roles:`/`modelOverrides:`/`retry:` in `~/.fah/config.yaml` (invalid
  schema = `ConfigException`).
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
  `customProviders:` section of `~/.fah/config.yaml`. Keys: env first, then
  secure store (`lib/src/secrets/secure_key_store*.dart` — Keychain /
  Secret Service / PasswordVault, IO backends only in `lib/io.dart`),
  preloaded into `SecureKeyCache`; resolution order env → `FA_KEY_<HOST>`
  → `FA_KEY_<HOST>_<NAME>` → legacy; `/key set` writes store-only, never
  config.
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
- `flutter_app/` — Flutter chat example. Layout: `lib/main.dart`
  (entrypoint + SetupScreen), `lib/ui/` (`app_theme.dart` — dark + light
  palettes/themes, `FahColors.of(context)` resolves per brightness;
  `markdown_style.dart`, `screens/`, `widgets/`), `lib/services/` (agent
  service, stores, upload, secrets, project mount, vision,
  `theme_controller.dart` theme-mode persistence + `FahThemeScope`,
  `session_keys_store.dart` user-saved keys + `SessionKeysScope`),
  `lib/sandbox/` (env, shells, wasm, git, fs persistence), feature dirs
  `lib/apps|gemma|webllm|transformers_js|l10n/`. All lib-internal imports
  are absolute `package:fa/...` — no relative imports.
- `flutter_app/lib/l10n/` — gen-l10n: `app_en.arb` + `app_ru.arb` →
  `AppLocalizations` (generated, never edit; `flutter gen-l10n`). UI copy
  via `context.l10n.<key>` (`l10n_ext.dart`); locale follows system.
  `test/l10n_guard_test.dart` hard-fails on hardcoded widget strings, en/ru
  key drift, placeholder mismatches, missing keys — opt out per line with
  `// l10n:ignore`, per file with `// l10n:ignore-file` (agent-facing/log
  strings stay literal).
- `flutter_app/test/golden/` — golden tests (see MANDATORY section below).
- `flutter_app/lib/sandbox/sandbox_registry.dart` — central registry of
  sandbox shell commands per platform; the Fa system prompt's `{{commands}}`
  renders from it. Never list commands in prompt text or UI by hand.
- `flutter_app/lib/services/project_mount_env.dart` — macOS project-folder
  mount (`/project` → user-picked host dir; security-scoped bookmarks in
  `project_mount.json`; stale bookmark = "pick again" warning).
- `flutter_app/lib/apps/` — JS apps platform on `package:js_widget_runtime`
  (≥0.4.5 — adds the `map` node: center/zoom/markers/polylines/fitBounds,
  onTap/onMarkerTap): apps live in env-shared `apps/<id>/{manifest.json,
  widget.js}`; permissions in `apps_permissions.json` (network/
  allowedCommands/llm/homekit/health/contacts/calendar — default denied);
  `jsr.fa.*` bridge over exec (`fa.llm`, `fa.calendar`; homekit/health/
  contacts are gated "not available yet" stubs); the `js-apps` skill seeds
  into `.fah/skills/` on startup. Bundled demos (seeded by
  `AppsStore.demoAppIds`, assets in `flutter_app/assets/apps/`): calculator,
  weather, stocks, crypto, animation-showcase, yolo-hello, calendar
  (`jsr.fa.calendar`), map (`map` node), health + homekit (honest stub UX +
  demo state). `open_app_tool.dart` registers the agent tool `open_app`
  (host callback navigates via `js_app_navigation.dart` `pushJsApp`).
- `flutter_app/lib/services/calendar_service.dart` — read-only system
  calendar: `CalendarApi` over the `fah/calendar` MethodChannel (EventKit in
  `MainFlutterWindow.swift`/`AppDelegate.swift`; entitlement
  `com.apple.security.personal-information.calendars`, both
  NSCalendars*UsageDescription plist keys); stub = not-available on web.
  Agent tool `calendar_events {date?, days?}` in `calendar_tool.dart`
  (registered when `calendarPlatformSupported`); denial result points to
  System Settings → Privacy → Calendars.
- `flutter_app/lib/services/theme_controller.dart` — ThemeMode
  (system/light/dark) persisted as `theme.json`; `app_theme.dart` has
  `buildFahTheme()` (dark) + `buildFahThemeLight()`, widgets read colors via
  `FahColors.of(context)` (never `FahPalette` directly in widgets).
- `flutter_app/lib/services/session_keys_store.dart` — in-app secrets:
  `session_keys.json` via the env (set/delete, never displays values);
  the settings Keys section manages them.
- `flutter_app/lib/services/last_connection.dart` — persists last connection
  (never API keys) as `last_connection.json`; pre-selects the settings form.
- `flutter_app/lib/services/vision_models.dart` — `modelIdSuggestsVision`
  heuristic fills `Model.input`; `AgentConfig.supportsImages` overrides;
  without `image` the `read` tool notes non-vision and adapters drop image
  blocks.
- `site/` — static GitHub Pages landing; `.github/workflows/pages.yml`
  builds the web demo into `app/` (never committed).
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
   `scripts/check_goldens.py`.

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

- `dart analyze` + `dart format --set-exit-if-changed .` clean; example app
  also `flutter analyze --no-fatal-infos --no-fatal-warnings`.
- `dart test` green (integration-tagged excluded — they run in CI).
- `cd flutter_app && flutter test` green (includes golden suite) +
  `scripts/check_goldens.py --quick`.
- Line coverage of `lib/` ≥ 80%; jscpd duplication < 1% core `lib/`,
  < 2.2% `flutter_app/lib/` (ratchet — only tighten).
- Max 2800 lines per `.dart` file (`*.g.dart` exempt).

## Commits and releases

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
