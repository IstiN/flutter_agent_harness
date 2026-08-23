# Services

One-line purpose for each `flutter_app/lib/services/` file. See [system-integrations.md](system-integrations.md) for HomeKit/Calendar/CodeMie SSO details.

| File | Purpose |
| --- | --- |
| `services/agent_service.dart` | main agent façade; wires `builtinTools` + `attachApproval` + secret/ask callbacks |
| `services/flutter_session_manager.dart` | multi-session manager: owns several `AgentService` instances, switches without aborting in-flight work, persists titles via `SessionNamesStore` |
| `services/session_keys_store.dart` | shim re-exporting fa_ui store; in-app secrets (see below) |
| `services/keychain_store.dart` | `fah/keychain` MethodChannel, service `fa.app` (iOS/macOS); file-persisted keys migrate once |
| `services/secrets_store.dart` | `.env` + in-memory overlay on IO, in-memory only on web (io/stub pair) |
| `services/provider_registry.dart` | custom-provider keys ride the same Keychain backend (host-scoped `FA_KEY_<HOST>`) |
| `services/media_models_store.dart` / `task_models_store.dart` / `vision_models.dart` | shim re-exports of fa_ui stores |
| `services/session_names_store.dart` | user-given session titles (`session_names.json` envelope in `ExecutionEnv.cwd`); `derivedSessionTitle(context, id:, createdAt:)` — localized `intl DateFormat.MMMd(locale).add_Hm()` from creation time, `session <id8>` fallback. Rename dialog `showRenameSessionDialog` |
| `services/approval_mode_store.dart` | approval mode persisted as `approval_mode.json`; `AgentService.create` seeds from it, `clone()` inherits the CURRENT mode (never a fresh read) |
| `services/ondevice_config_store.dart` | on-device engine route (`gemma`/`webllm`/`transformers_js`) — persisted JSON, observed by widgets |
| `services/analytics.dart` | `AppAnalytics` facade over Firebase Analytics (see Analytics & crash) |
| `services/last_connection.dart` | `last_connection.json` (no API keys); `restorableBootConfig` rebuilds `AgentConfig` (custom-provider key → saved hosted key) for auto-connect |
| `services/media_tools.dart` | `MediaGateway` over `media_models.json` slots (+ main-connection fallback) backing `generate_image`/`speak`/`generate_music`/`generate_video` tools + `jsr.fa.media.*` bridge; files → `generated/`. `generate_video` rides `videoGeneration` slot (required): async OpenAI/OpenRouter `/videos` (POST → poll `GET /videos/{id}` every 3s, 4-min cap → `unsigned_urls` or `GET /videos/{id}/content` mp4). Google (`generativelanguage`) baseUrl switches to Gemini protocol: `speak` → `/models/{model}:generateContent` (`x-goog-api-key`, LINEAR16 PCM 24 kHz → `.wav`), `generate_music` → `/interactions` (deep-search base64 audio); image/video slots = 'not supported for Google'. |
| `services/asr_service.dart` (+ `asr_tool.dart`) | voice-to-text: per-take model resolution (active provider → media gateway fallback), Whisper-compatible upload; wires `fah/mic` for native mic capture on iOS/macOS |
| `services/chatgpt_oauth_flow.dart` | ChatGPT account OAuth UI flow (browser launch + callback parse) — mirrors CLI's `chatgpt_oauth_server.dart` |
| `services/openrouter_oauth_*` | OpenRouter OAuth PKCE: `coordinator`/`callback` (io)/`links_io`/`links_web`/`launch_stub`/`launch_web` — wire same `openrouter_oauth.dart` PKCE primitives as CLI but with `webview_flutter`/browser launchers |
| `services/contact_service.dart` (+ `contact_tool.dart`) | iOS/macOS system contacts over `fah/contacts` MethodChannel (io/stub pair); agent tool `contacts_search` |
| `services/health_service.dart` (+ `health_tool.dart`) | iOS HealthKit over `fah/health` MethodChannel (io/stub pair); per-day samples |
| `services/icloud_sync_service.dart` (+ `icloud_sync_tool.dart`) | iCloud container sync over `fah/icloud_sync` (io/stub pair); state in `icloud_sync.json` |
| `services/notify_service.dart` (+ `notify_tool.dart`) | local user notifications over `fah/notify` (io/stub pair); backs the `reminders` demo |
| `services/video_service.dart` (+ `video_tool.dart`) | per-frame extraction (jpeg bytes + timestamp) from local video files (io/stub pair) |
| `services/home_service.dart` (+ `home_tool.dart`) | smart home: see [system-integrations.md](system-integrations.md) |
| `services/calendar_service.dart` (+ `calendar_tool.dart`) | system calendar: see [system-integrations.md](system-integrations.md) |
| `services/project_mount_store.dart` (+ `project_folder_channel.dart`) | macOS project-folder mount persistence (`project_mount.json`, security-scoped bookmark); `project_folder_channel` is the native bridge |
| `services/project_mount_env.dart` | `ExecutionEnv` wiring for the mounted folder (used at runtime by the agent) |
| `services/app_log.dart` | debug log: ring buffer (2000 lines) + persistence to `logs/app.log` under `ExecutionEnv.cwd` (rewritten with tail past 1 MB). `main.dart` tees `debugPrint` |
| `services/background_execution.dart` | iOS extended background execution (`fah/background` → `UIApplication.beginBackgroundTask`, io/stub pair): `AgentService.isStreaming` brackets every run so the OS grants ~30 s when backgrounded mid-stream |
| `services/live_activity.dart` | iOS Live Activity (`fah/live_activity`, ActivityKit ≥16.2, io/stub pair): starts on run start, updates with FaWorkBar-style status, ends after 4 s. Widget extension `ios/FaLiveActivity/` (bundle id `dev.fa1.app.FaLiveActivity`); `Info.plist` has `NSSupportsLiveActivities` |
| `services/theme_controller.dart` | ThemeMode (system/light/dark) persisted as `theme.json`; theme in `packages/fa_ui`; widgets read via `FahColors.of(context)` (never `FahPalette` directly) |
| `services/onboarding_store.dart` | `onboarding_seen.json` (same tiny-store pattern); `BootstrapScreen` shows onboarding once only when there is NO restorable connection |
| `lib/ui/screens/onboarding_screen.dart` | 4 pages: welcome + AI disclaimer, permissions explainer, model preset mini-wizard reusing `kModelPresets`/`applyModelPreset` with a null service, privacy + policy link via `url_launcher`; page dots, Skip on every page |

## `services/session_keys_store.dart` (shim)

On iOS/macOS persisted in the platform Keychain via `keychain_store.dart`; elsewhere `session_keys.json` via the env (set/delete, never displays values); the settings Keys section manages them. The "Add key" dialog saves arbitrary names (`^[A-Z][A-Z0-9_]*$`, uppercase-normalized, duplicates rejected). `AgentService.create` merges saved keys into agent secrets — dotenv first, saved keys OVERRIDE on conflict (bash env, redactor, system-prompt name list all flow from the merged map).

## Analytics & crash

`AppAnalytics` facade over Firebase Analytics (global instance, noop without Firebase; tests install a recorder sink). Privacy rule: **never keys, message text, or file contents.**

| Event group | Payload |
| --- | --- |
| App start / Setup shown / Provider add/edit/delete / Session new/switch/delete / Settings opened / Key set-delete (names only) / Upload count / Chat sheet state / JS app open-reload / Launcher folders-tiles-grid / Theme+approval mode / Model presets / Media slot set-generated / Voice input / Secret request outcome / Files opened | — |
| Bootstrap outcome | success/fail |
| Connect result | provider kind/custom/on-device, success only |
| Models fetch | count bucket |
| Model pick | suggestion vs free-text |
| Message sent | attachment flag + length bucket (never content) |
| `screen_opened` per screen | user-path backbone |

`test/analytics_guard_test.dart` hard-fails on a screen/composer/sheet file without an `AppAnalytics.instance` call (or a documented exemption) and on facade events never called from `lib/` — keep both sides wired.

**Crashlytics** (`firebase_crashlytics`, wired in `main.dart`: fatal Flutter errors + uncaught async + `debugPrint` breadcrumbs) NEEDS `GoogleService-Info.plist` bundled in the Runner target — both pbxproj files carry the reference (gitignored file, CI writes it from `GOOGLE_SERVICE_INFO_PLIST_BASE64`) plus a "Crashlytics: upload dSYMs" build phase + `dwarf-with-dsym` in Release; settings has a "Send test crash report" row (non-fatal `recordError`) to verify the pipeline from a device.
