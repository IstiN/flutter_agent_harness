# `packages/fa_ui/`

Reusable Flutter package for hosts embedding the Fa agent. See [flutter-app.md](flutter-app.md) for how the app consumes it.

- Theme: `FahPalette`/`FahLightPalette`/`FahColors.of(context)`, `buildFahTheme()`/`buildFahThemeLight()` + chat themes; customization via `FaUiTheme`/`FaUiThemeProvider` (accent colors, font family, radii).
- Provider / model settings widgets: `ProvidersSection`, `ProviderEditorPage`, `DefaultChatModelSection` + pickers, `MediaModelsSection` (moved from app — store/`mainBaseUrl`/`modelsFetcher` in, host analytics via `onSlotEditorOpened`/`onSlotOverrideSaved` hooks), `MediaSlotProviderPickerPage`/`MediaSlotModelPage`, `ProviderPreset` + helpers (hosted presets: OpenRouter, Ollama Cloud, Google Gemini), `ModelIdAutocompleteField`, `FaVoicePresetPicker` + `faVoicePresetsFor` (per-`(baseUrl, modelId)` TTS voice presets — Gemini/Kokoro/OpenAI — inline sample previews).
- Stores: `ProviderRegistry`, `MediaModelsStore`, `SessionKeysStore`, `KeychainStore`, `modelIdSuggestsVision`.
- **One post-provider model-choice pattern.** Fetched list renders with field text as live quick-search; `Use "<query>"` row keeps manual entry. `FaModelListPicker` (initial value shows FULL list with a check, only user typing filters) for form pages; same `Use "<filter>"` row inside `UnifiedModelPickerPage` (ACTIVE provider, key via registry). Media slots AND agent-role rows (`TaskModelsSection`: Quick model / Subagents model) share the ONE two-step flow — `MediaSlotProviderPickerPage` → `MediaSlotModelPage` (`slot: null` for roles: no voice field, no capability chips, dial-aware kind). Endpoint fetch via `fetchModelsForEndpoint`; legacy `DefaultModelProviderPickerPage`/`DefaultModelPickerPage` + `TaskRoleConfigPage` are gone.
- Chat leaf widgets (`lib/src/chat/`): `markdown_style.dart`, `media_player.dart`, approval/ask/secret-request sheets, `chat_message_tile.dart` (the ONE transcript message renderer — **Never fork message rendering**, extend this widget), `chat_composer.dart` (file/gallery/camera via `FaChatHost.uploadPicker`/`galleryPicker`/`cameraPicker`, voice via `FaChatHost.voiceInput`), `fa_chat_screen.dart` (`FaChatScreen(service:, features:, title:, settingsBuilder:, fileBrowserBuilder:, composerBuilder:)`), `upload_utils.dart`, `media_tool_names.dart`.
- Backend surface is the `FaChatService` interface (which `AgentService` implements; `ApprovalModeSelector` needs only the `FaApprovalModeController` slice). Localized via `FaChatStrings` (en/ru defaults, `FaChatStringsScope` override) + `FaUiStrings` (en/ru defaults, `FaUiStringsScope` override) — never the app's gen-l10n. Analytics via the `FaChatHost.track` hook.
- App-level concerns injected:

| Hook | Purpose |
| --- | --- |
| `FaChatConnection` | active connection |
| `FaOnDeviceRoute` | on-device engine route builders |
| `FaChatModelConfig` | apply callback payload |
| `FaUiHost.keyResolver` | named-key resolution |
| `FaChatHost.uploadPicker` / `galleryPicker` / `cameraPicker` | file picking |
| `FaChatHost.voiceInput` | ASR |
| `FaChatHost.appLauncher` | open-app navigation |
| `FaChatHost.track` | analytics |

`flutter_app` consumes it via path dep + thin `export` shims at the old paths; the app's `lib/ui/screens/providers_section.dart` additionally keeps a `DefaultChatModelSection` ADAPTER (old constructor) wiring `AgentService`, `LastConnectionStore`, and the on-device engines into the package flow.
