# Flutter app + packages + repo-level areas

> Moved verbatim from `AGENTS.md` (gh-2181 — the slim-AGENTS.md card). Canonical reference; the slim AGENTS.md carries the one-line summary and points here.

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
  `FaChatHost.uploadPicker`/`galleryPicker`/`cameraPicker` hooks — the
  upload hook is the any-type multi-select system picker on every platform
  (issue #1979), voice
  input through `FaChatHost.voiceInput`; desktop keys: Enter sends and
  Shift+Enter inserts a newline (issue #973 — the Focus ancestor swallows
  plain Enter before the IME turns it into a break; the touch return key
  keeps its IME newline path), Cmd/Ctrl+V is smart paste — clipboard FILES
  (type-aware via the `FaChatHost.clipboardReader` hook: copied file refs,
  audio/video, images — issue #1979) or long/multi-line text
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
  The trajectory ledger UI lives in `lib/src/trajectory/` (issue #25
  redesign): `TrajectoryController` (view-state owner — debounced
  snapshot updates, turn/assistant folds, the four timeline projections
  with selection, record selection, throttled search),
  `TrajectoryScreen` (the full-screen trajectory page: wide canvases
  `>= kWideLayoutBreakpoint` push it as a master-detail route from the
  chat app bar; narrow canvases swap it in as the chat screen's body via
  the Chat | Trajectory segmented switcher — controller state lives at
  screen level so the swap never loses scroll, selection, or filters),
  `TrajectoryHeader` (title + session stamp, stat pills, the search
  field with match position and prev/next navigation, the ledger filter
  chips, and the export overflow menu that copies the session as
  JSON/Markdown to the clipboard), `TrajectoryBody` (header above the
  ledger; wide splits ledger ~55% / details ~45% into
  `TrajectoryDetailsPane`, narrow keeps the tap-for-details sheet),
  `TrajectoryView` (control strip + Gantt timeline strip + ledger of
  two-line expandable selectable rows with per-row copy and injectable
  table/timeline builder seams), the details surface (`showTrajectoryDetails`
  sheet narrow / persistent pane wide: tab set per record kind with
  empty tabs hidden, a Request tab for outbound model payloads, per-tab
  copy, highlighted Raw view; session-scoped last-tab restore,
  `resetTrajectoryTabHistory()` test seam), and `FaTrajectoryPanel`
  for hosts that feed their own stream via `TrajectoryServiceFeed`
  (broadcast snapshot stream that replays `latest` to new listeners).
  `TrajectoryTimeline` draws the Gantt: time ruler + lane labels, three
  fixed lanes (0 system/user/context, 1 message/compacted, 2 tools), a
  live pulse on the in-progress span, and the whole strip hidden when
  the session is untimed.
  Strings: `TrajectoryStrings` en/ru + `TrajectoryStringsScope`. Golden
  baselines: `test/trajectory/golden/` (regenerate with
  `flutter test test/trajectory/golden/ --update-goldens`, verify without
  the flag) — `golden_test_setup.dart` loads the real `Inter` and
  `JetBrainsMono` families from `test/assets/fonts/` (test-only copies
  of flutter_app's bundled TTFs; the package itself ships no font
  assets) plus the bundled MaterialIcons font, so goldens render real
  glyphs; review every changed PNG after regenerating.
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
  `lib/apps|webllm|transformers_js|l10n/`. All lib-internal imports
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
  `asrTranscriber`/`clipboardReader` test fakes) and bridges it to the
  shared composer's hooks: the `UploadPicker` becomes a `FaChatUploadPicker`
  (native any-type multi-select chooser via `file_selector` on iOS/Android/
  desktop, the `<input type=file multiple>` on web — issue #1979),
  gallery/camera come from `image_picker`, the ASR stack is wrapped in a
  `FaChatVoiceInput` (transcriber resolved per take via the session's
  media gateway, falling back to the active provider), and the smart-paste
  clipboard probe is type-aware via `super_clipboard`
  (`services/clipboard_uploads.dart`: file refs > audio/video/pdf >
  images; native plugin — the desktop/mobile apps need a REBUILD, not a hot
  reload, to register it).
- `flutter_app/lib/ui/screens/app_launcher_screen.dart` — the reusable Apps
  surface embedded by the responsive Fa2 shell. It is presented only when
  the Apps section is selected; it is no longer the app's home screen.
  iOS-home-screen grid of the JS apps (fsRevision-refreshed like
  `AppsGridView`) plus Settings/Files system tiles, laid out on the
  icon-unit geometry (`LauncherGridSpec` in
  `lib/ui/widgets/span_grid_delegate.dart`: 56px icon square + 20px label,
  16px gaps; default 4 columns < 600px, 6 above, clamped 3–8) as a
  `SingleChildScrollView` + `Stack` of `AnimatedPositioned` tiles
  (`packTileSpans`/`layOutTileRects`; issue #166 made the packer
  order-preserving row-wrap: tiles place strictly in list order, a span
  that doesn't fit the remaining row cells wraps to the next row and the
  trailing cells stay blank — no backfilling earlier rows, reading order
  == tile order; spans clamp to the column count), so reorders animate
  live while dragging (center-band hover on an app = folder intent, edge
  halves = insertion preview; drop persists; hold-release without
  movement opens the tile-size menu). Folder tap opens a floating panel
  (rename/dissolve buttons, drag-out-to-ungroup onto the barrier). Tile
  layout persists via
  `LauncherLayoutStore` (`lib/services/launcher_layout_store.dart`,
  `launcher_layout.json` v2: ordered keys `app:<id>`/`system:*`/`folder:<id>`
  + `grid.columns` + `tileSizes` {appId: "WxH"} overrides — agent-editable,
  re-read live on fsRevision; v1 migrates, corrupt file → defaults;
  `syncApps` reconciles with installed apps).
- `flutter_app/lib/ui/widgets/wide_layout_shell.dart` — the responsive Fa2
  messenger shell: compact Chats / Activity / Apps navigation, the shared
  conversation list, live Running/Recent activity, and Apps as a selected
  surface. Wide layouts keep the active chat in the center; narrow layouts
  open conversations as full routes with bottom navigation.
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
- `flutter_app/test/golden/` — golden tests (MANDATORY — see docs/agents/golden-tests.md).
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
- `flutter_app/lib/sandbox/python_http_bridge.dart` — the mobile WASM
  python HTTP bridge (issue #337): the WASI CPython build has no sockets and
  no `ssl` module, so `fa_http.py` + `sitecustomize.py` (materialized into
  site-packages by `WasiSandboxShell._ensurePythonBridge`) patch
  `http.client`/`urllib`/`urllib3` to print each request to stdout as a
  `\x01FAHTTP1` control line and poll `/dev/.fahttp/<id>` for the raw
  response. `FaHttpBridge` (wired into `WasiSandboxShell._runStage` for
  python stages) strips those lines from captured stdout, performs the
  request with the shell's real-TLS HTTP client and writes the response
  back; the authority in the control line carries the scheme
  (`https://host:port`). Curl `-d` follows real-curl semantics (`@file`,
  `@-`, multiple flags join with `&`, 1 MiB cap, `-d` implies POST) and the
  mobile prompt advertises the TLS path via `sandbox_registry.dart`.
- `flutter_app/lib/services/project_mount_env.dart` — macOS project-folder
  mount (`/project` → user-picked host dir; security-scoped bookmarks in
  `project_mount.json`; stale bookmark = "pick again" warning). Sessions on
  macOS are stored in the shared App Group container
  (`~/Library/Group Containers/group.dev.fa1.shared/fa/sessions`) so the Fa
  CLI and the sandboxed Fa macOS app see the same workspace-scoped sessions.
- `flutter_app/lib/apps/` — JS apps platform on `package:js_widget_runtime`
  (`^0.4.156` hosted — ships `jsr.openUrl` + the `webView` node and, since
  0.4.156 = upstream 9d57570 (gh-1341), the flutter_js bridge registers
  EVERY `__jsr_*` channel (`JsWidgetBridge.handledChannels` is the source
  of truth), so `jsr.hostCall`/`jsr.capture` no longer hang forever on JSC
  builds; the git pin convention is drop-the-override-once-hosted-lands;
  `js_app_engine.dart` wires `openUrlHandler` over `url_launcher`
  (LaunchMode.externalApplication, {'__error': ...} rejections) and passes a
  `JsWebViewHost` (fa_webview_host.dart, `flutter_inappwebview` over the
  system default data store — never incognito; iOS/Android/macOS only, other
  platforms get the renderer placeholder via `createFaWebViewHost`) to BOTH
  the JsRuntimeConfig and the JsonWidgetRenderer in js_app_view.dart —
  flutter_inappwebview rides the coherent 6.2.0-beta.3 set because 6.1.x's
  android impl evaluates getDefaultProguardFile('proguard-android.txt'),
  which AGP 9 removed (APK CI leg); the beta macos impl declares a 10.14
  floor while its Swift needs 10.15 (fails on both the SwiftPM and
  CocoaPods paths), so it is vendored with only the floor raised to the
  app's 14.0 (vendor/flutter_inappwebview_macos, pubspec override); return
  to ^6.1.x once 6.2.0 stable ships —
  earlier hosted line shipped the queued-callEvent-after-dispose guard +
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
  notifications/media/keys/theme — default denied);
  `jsr.fa.*` bridge over exec (`fa.llm`, `fa.calendar`, `fa.home.*`,
  `fa.health.*`, `fa.asr.*`, `fa.notify.*`, `fa.theme` — declarative-only
  list/current/apply over installed theme packs, consent dialog per apply,
  no install/delete surface (issue #169); `fa.keys` — list/get/request the
  host's merged secrets (AgentService.hostSecrets); `request` renders the
  shared secret_request sheet from JsAppView and persists via
  AgentService.acceptSecretGrant; contacts is a gated "not
  available yet" stub); the `js-apps` skill is a package builtin
  (gh-1164 retired the `.fah/skills/` seeder — it is compiled into
  `builtinSkillFiles` by `scripts/gen_prompts.dart`, and the gh-1275
  packaging-content gate is `scripts/verify_builtin_skills.dart`, wired
  into the app build workflows). Bundled demos (seeded by
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
  `JsAppInfo.tileWidget`; size in icon-slot cells, W 1–4 × H 1–4, default
  2x2 — W 1 = icon-only; out-of-range values clamp to the range with an
  AppLog note, never a crash) makes the launcher
  grid render `app_tile_host.dart`
  (a JsAppEngine on the tile entry, display-only — any tap opens the app)
  instead of the static icon tile; a WxH tile's edges align exactly with
  the WxH block of icon slots it replaces. Users resize tiles via the
  hold-release menu (issue #166 preset list: 1×1/1×2/2×1/2×2/1×3/3×1
  plus the iOS 4×2/4×4; writes `tileSizes` into `launcher_layout.json`);
  the same menu offers demo apps "Restore reference version"
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

