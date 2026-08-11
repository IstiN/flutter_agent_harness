/// The cross-platform settings registry: the single source of truth for
/// every shared concept that must exist on BOTH the CLI and the Flutter app.
///
/// When you add a new setting or interactive type that both platforms should
/// support:
/// 1. Add it to [SharedSetting] here.
/// 2. Implement it on BOTH platforms.
/// 3. If one platform genuinely cannot support it, add it to
///    [cliOnlySettings] or [appOnlySettings] with a comment explaining WHY.
/// 4. Run `dart test test/parity/` — the guard must pass.
///
/// The parity tests in `test/parity/` read [sharedSettingMetadata] and verify
/// that the `cliRef` and `appRef` strings appear in the respective platform's
/// source tree. This catches drift early — a new setting added to the CLI but
/// forgotten in the app (or vice versa) fails the test.
library;

/// Every shared settings concept that must exist on both platforms unless
/// explicitly exempted.
enum SharedSetting {
  /// Tool-approval mode (always-ask / write / yolo).
  approvalMode,

  /// The default chat model (provider, modelId, baseUrl, apiKey).
  modelDefault,

  /// Fast/cheap model for compaction and subagents.
  modelSmol,

  /// Per-modality media model overrides (image/TTS/music/video/vision/transcription).
  mediaSlots,

  /// Saved custom provider endpoints.
  customProviders,

  /// API key store (env / keychain).
  apiKeys,

  /// External MCP tool servers.
  mcpServers,

  /// Time-traveling stream rules.
  ttsrRules,

  /// Prompt template overrides (system prompt, mode prompts, compaction prompts).
  promptOverrides,
}

/// Settings that are currently CLI-only.
///
/// Each entry MUST have a comment explaining WHY the app cannot support it.
const cliOnlySettings = <SharedSetting>{
  // MCP servers require spawning external processes — impossible on web and
  // not yet wired in the Flutter app's sandbox.
  SharedSetting.mcpServers,

  // TTSR rules monitor the raw streaming delta for regex matches and abort
  // mid-turn — the app's stream wrapper does not expose per-delta hooks yet.
  SharedSetting.ttsrRules,
};

/// Settings that are currently app-only.
///
/// Each entry MUST have a comment explaining WHY the CLI cannot support it.
const appOnlySettings = <SharedSetting>{
  // No app-only settings — everything the app has, the CLI should have too
  // (or already has an equivalent for).
};

/// Metadata for each [SharedSetting]: what to search for in each platform's
/// source tree. The parity test greps the `cliRef` pattern inside
/// `lib/src/cli/` (recursively) and the `appRef` pattern inside
/// `flutter_app/lib/` (recursively). A non-null pattern that is absent
/// from the target tree fails the test.
const sharedSettingMetadata = <SharedSetting, _SettingMeta>{
  SharedSetting.approvalMode: _SettingMeta(
    cliRef: 'approvalMode',
    appRef: 'ApprovalModeStore',
    description: 'Tool-approval mode (always-ask / write / yolo).',
  ),
  SharedSetting.modelDefault: _SettingMeta(
    cliRef: 'providerKind',
    appRef: 'DefaultChatModelSection',
    description: 'The default chat model.',
  ),
  SharedSetting.modelSmol: _SettingMeta(
    cliRef: 'smolModelRole',
    appRef: 'TaskModelsStore',
    description: 'Fast/cheap model for compaction and subagents.',
  ),
  SharedSetting.mediaSlots: _SettingMeta(
    cliRef: 'mediaModelSlotIds',
    appRef: 'MediaSlot.all',
    description: 'Per-modality media model overrides.',
  ),
  SharedSetting.customProviders: _SettingMeta(
    cliRef: 'CustomProviderEntry',
    appRef: 'ProviderRegistry',
    description: 'Saved custom provider endpoints.',
  ),
  SharedSetting.apiKeys: _SettingMeta(
    cliRef: 'SecureKeyCache',
    appRef: 'SessionKeysStore',
    description: 'API key store.',
  ),
  SharedSetting.mcpServers: _SettingMeta(
    cliRef: 'McpConfig',
    appRef: null, // exempted — not yet supported in the app.
    description: 'External MCP tool servers.',
  ),
  SharedSetting.ttsrRules: _SettingMeta(
    cliRef: 'TtsrConfig',
    appRef: null, // exempted — not yet supported in the app.
    description: 'Time-traveling stream rules.',
  ),
  SharedSetting.promptOverrides: _SettingMeta(
    cliRef: 'promptOverrides',
    appRef: null, // app does not expose prompt overrides yet — CLI-only.
    description: 'Prompt template overrides.',
  ),
};

/// Internal metadata record used by the parity tests.
final class _SettingMeta {
  const _SettingMeta({
    required this.cliRef,
    required this.appRef,
    required this.description,
  });

  /// A string that MUST appear in at least one file under `lib/src/cli/`.
  final String cliRef;

  /// A string that MUST appear in at least one file under `flutter_app/lib/`.
  /// `null` means this setting is exempted from the app (must be listed in
  /// [appOnlySettings]).
  final String? appRef;

  /// Human-readable description shown in test failure messages.
  final String description;
}
