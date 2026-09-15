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
///
/// ## Completeness contract (issue #288)
///
/// The registry also OWNS the yaml schema classification: every top-level
/// key the real parsers read (`CliConfig.fromYaml` + the roles parser) is
/// either
/// - owned by a [SharedSetting] via its `yamlKeys` (settings-hub TUI entry
///   + app surface, unless [cliOnlySettings] exempts the app side), or
/// - listed in [fileOnlyConfigKeys] with a WHY (structural/infrastructure
///   keys no interactive surface edits, on any platform, by design).
///
/// The completeness gate `test/parity/settings_completeness_test.dart`
/// walks the parser sources and fails on any unclassified key — a new yaml
/// key cannot land without a registry classification. CLI-only exemptions
/// carry a user-readable justification in [cliOnlyJustifications] which the
/// app renders in its "CLI-only settings" section (never silent absence),
/// and [settingSurfaces] records the {macOS, iOS, web, extension}
/// applicability audit with capability-named gap reasons.
library;

/// Every shared settings concept that must exist on both platforms unless
/// explicitly exempted.
enum SharedSetting {
  /// Tool-approval mode (always-ask / write / yolo / unattended).
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

  /// Consent for reading third-party skill roots (Claude/Copilot/Codex).
  skillsAccess,

  /// fa_cube sandbox profiles (declarative fs/shell/network clamps).
  cubeSandbox,

  /// DAP/1 hub connection (URL, agent name/identity, channels).
  dapHub,

  /// Capability-gated tool availability (hide unavailable/disabled tools).
  tools,

  /// Compaction engine choice (structured 2.0 default, issue #287; the
  /// classic 1.0 prefix summary stays as the in-settings rollback).
  compactionEngine,

  /// The agent mode preset (code / ask / plan …) that picks the system
  /// prompt of the coding REPL.
  agentMode,

  /// Long-term memory store locations (`memory.projectPath` /
  /// `memory.userPath`).
  memoryStores,

  /// The layered redaction pipeline's `redact:` section (enabled/blockMode,
  /// per-layer toggles, allowlist regexes, entropy knobs, per-tool policy,
  /// issue #391).
  redactionPolicy,

  /// The session image registry's `images:` section — the registry kill
  /// switch (`registry: false` reproduces the legacy request shape
  /// byte-for-byte) and the per-request unique-image cap
  /// (`maxPerRequest`, default 20), issue #395.
  imageRegistry,

  /// The owner-side context cap (`agent.contextWindowCap`, issue #273)
  /// clamping the EFFECTIVE window for the compaction thresholds, the ctx
  /// meter and the loop's over-window guard (issue #394).
  contextWindowCap,
  /// Provider failure resilience: the watchdog timeouts
  /// (`providerTimeouts.connectTimeoutMs`/`streamIdleTimeoutMs`) and the
  /// chain retry policy (`retry:`, issue #393).
  resiliencePolicy,

  /// TUI color palette (tui.theme + ~/.fah/themes/*.json, issue #279).
  tuiTheme,
}

/// Settings that are currently CLI-only.
///
/// Each entry MUST have a comment explaining WHY the app cannot support it,
/// and a matching user-readable justification in [cliOnlyJustifications]
/// (the app surfaces the reason instead of silently omitting the setting).
const cliOnlySettings = <SharedSetting>{
  // MCP servers require spawning external processes — impossible on web and
  // not yet wired in the Flutter app's sandbox.
  SharedSetting.mcpServers,

  // TTSR rules monitor the raw streaming delta for regex matches and abort
  // mid-turn — the app's stream wrapper does not expose per-delta hooks yet.
  SharedSetting.ttsrRules,

  // Host-process sandboxing primitives + a host shell: the app's mobile
  // shells are already WASI/memory-confined and web has no shell at all.
  SharedSetting.cubeSandbox,

  // The app's agent surfaces compile their prompt templates in
  // (flutter_app/lib/prompts.g.dart, generated from flutter_app/prompts/);
  // there is no runtime prompt-override file for them to read.
  SharedSetting.promptOverrides,

  // Agent modes are REPL prompt presets (builtInAgentModes) driving the
  // coding agent's system prompt; the app composes its own per-surface
  // prompts and has no mode-preset concept to switch.
  SharedSetting.agentMode,

  // Memory store locations are host filesystem paths (project-relative and
  // ~/ user roots). The app's sandbox owns its storage layout and resolves
  // the section read-only (memory_config_loader); editing host paths from
  // inside the sandbox would point the CLI at paths the app cannot see.
  SharedSetting.memoryStores,

  // The redaction pipeline runs inside the CLI host process with the
  // process's registered secrets in memory; the app has no pipeline
  // instance to re-toggle live (issue #391 is the CLI half — the app
  // keeps consuming the section read-only per #288's umbrella).
  SharedSetting.redactionPolicy,

  // The image registry is process-wide state inside the CLI host's agent
  // loop (the request-build rewrite reads a global published at boot);
  // the app composes its own requests and consumes the section read-only
  // per #288's umbrella (issue #395 is the CLI half).
  SharedSetting.imageRegistry,
  // The context cap feeds the CLI's compaction math, ctx meter and the
  // loop's over-window guard — all running in the CLI host process; the
  // app has no agent loop to re-cap live (issue #394 is the CLI half —
  // the app keeps consuming the section read-only per #288's umbrella).
  SharedSetting.contextWindowCap,
  // The resilience knobs (watchdog timeouts + retry policy) govern the
  // CLI host process's provider connections: the timeouts are published
  // onto a process-wide override and the retry policy rides the roles
  // resolver's cached stream wrappers (issue #393 is the CLI half — the
  // app keeps consuming the sections read-only per #288's umbrella).
  SharedSetting.resiliencePolicy,

  // The TUI palette colors a terminal: the app renders through Flutter's
  // own theming stack (separate system by design — issue #279 non-goal).
  SharedSetting.tuiTheme,
};

/// Settings that are currently app-only.
///
/// Each entry MUST have a comment explaining WHY the CLI cannot support it.
const appOnlySettings = <SharedSetting>{
  // No app-only settings — everything the app has, the CLI should have too
  // (or already has an equivalent for).
};

/// SharedSettings that own NO `~/.fah/config.yaml` key because their
/// storage lives elsewhere. The completeness gate allows exactly these to
/// have empty `yamlKeys` (issue #288 E1: secrets never ride the yaml).
const nonYamlSettings = <SharedSetting>{
  // API keys resolve env-first, then the platform secure store
  // (SecureKeyCache / the app's keychain-backed stores) — never the yaml
  // config file. Both surfaces edit the same secure store.
  SharedSetting.apiKeys,

  // The DAP/1 hub connection persists in ~/.dap/config.json plus the
  // .fah/packages.yaml plugin opt-out — an E4-style whole-section entry
  // that covers the connection, not a yaml key.
  SharedSetting.dapHub,
};

/// User-readable justifications for the [cliOnlySettings] exemptions.
///
/// The app renders these in its "CLI-only settings" section (issue #288
/// AC4): where the app would naturally list a related setting, the CLI-only
/// entry shows the marker + reason — never a silent absence. E3 discipline:
/// the reason names the missing capability, not "didn't get to it".
const cliOnlyJustifications = <SharedSetting, String>{
  SharedSetting.mcpServers:
      'MCP servers spawn external processes on the host; the app cannot '
      'start them from its sandbox. Configure them in the CLI.',
  SharedSetting.ttsrRules:
      'Time-traveling stream rules watch every raw streaming delta to abort '
      'mid-turn; the app chat surface has no per-delta hook for them.',
  SharedSetting.cubeSandbox:
      'fa_cube sandbox profiles need host-process sandboxing and a host '
      'shell; the app runs WASI/memory-confined (or in a browser with no '
      'shell at all).',
  SharedSetting.promptOverrides:
      'The app ships its prompt templates compiled in; runtime prompt '
      'overrides are a CLI config-file feature.',
  SharedSetting.redactionPolicy:
      'The redaction pipeline runs inside the CLI host process with its '
      'registered secrets in memory; the app reads the section but has no '
      'pipeline to re-toggle live. Configure it in the CLI (issue #391).',
  SharedSetting.imageRegistry:
      'The image registry is process-wide state inside the CLI host agent '
      'loop (the request-build rewrite reads a global published at boot); '
      'the app composes its own requests and consumes the section '
      'read-only. Configure it in the CLI (issue #395).',
  SharedSetting.contextWindowCap:
      'The context cap feeds the CLI agent loop and compaction math '
      'running in the CLI host process; the app has no agent loop to '
      're-cap live. Configure it in the CLI (issue #394).',
  SharedSetting.agentMode:
      'Agent modes are CLI REPL prompt presets; the app composes its own '
      'prompts per surface and has no mode presets to switch.',
  SharedSetting.memoryStores:
      'Memory store locations are host filesystem paths; the app sandbox '
      'resolves them read-only and cannot re-point the CLI at new paths.',
  SharedSetting.tuiTheme:
      'The TUI palette colors a terminal emulator; the app themes through '
      'its own Flutter theming stack (separate system by design).',
  SharedSetting.resiliencePolicy:
      'The watchdog timeouts and retry policy govern the CLI host '
      'process\'s provider connections; the app has no process-wide '
      'override or roles resolver to re-arm. Configure them in the CLI '
      '(issue #393).',
};

/// Top-level yaml keys that are intentionally NOT interactive settings on
/// ANY surface — structural or infrastructure config, edited in the file by
/// design. Every entry carries its WHY (issue #288 AC1: a documented
/// structural-only key, reviewed).
const fileOnlyConfigKeys = <String, String>{
  // A2A gateway endpoints + credentials are deployment wiring (env-token
  // references included) — infrastructure, not a user preference.
  'a2a':
      'A2A gateways are deployment infrastructure (endpoints and '
      'credentials with env-token references); no surface edits them '
      'interactively.',

  // Provider transport tuning: rarely-changed watchdog knobs.
  'providerTimeouts':
      'Provider transport watchdog tuning (connect/idle timeouts) — '
      'rarely-changed knobs, tuned in the file.',

  // Image-tool runtime tuning (registry on/off, per-request cap).
  'images':
      'Image-tool runtime tuning (registry on/off, per-request cap) — '
      'operational knobs, tuned in the file.',

  // Trajectory capture tuning (opt-in raw wire dumps, issue #385): a
  // deliberate, size/pII-sensitive escape hatch — file-only by design so
  // it cannot be flipped casually mid-session.
  'trajectory':
      'Trajectory wire-dump capture is an opt-in, size/pII-sensitive '
      'debugging escape hatch (issue #385); provisioned deliberately in '
      'the file per environment.',

  // Background-subagent heartbeat cadence and stall threshold (issue
  // #383): operational knobs for long-running sessions, tuned in the
  // file; 0/0 disables the heartbeat entirely.
  'subagents':
      'Heartbeat cadence and stall threshold for background-subagent '
      'status digests (issue #383) — operational knobs, tuned in the '
      'file.',

  // The fabric section carries the HOST's discovery announcements (issue
  // #27 phase 2) — written by hosts, read by the runtime, never user-edited.
  'fabric':
      'Host discovery announcements are written BY hosts (issue #27), not '
      'by users; read-only config.',

  // Roles-group member: per-path role pinning, parsed together with
  // roles:. Superseded for interactive use by the roles: chains the
  // agent-models flow edits; per-path pinning stays file-tuned.
  'modelOverrides':
      'Roles-group member (per-path role pinning), superseded for '
      'interactive use by the roles: chains the agent-models flow edits; '
      'per-path pinning stays file-tuned.',

  // The power section (power.sleepPrevention + power.hold, issues
  // #325/#326) picks the host machine's sleep-prevention level and hold
  // lifecycle for long sessions — hardware policy of the machine the
  // agent runs on, not a per-conversation preference. Both surfaces
  // treat it read-only: the CLI's /power shows the level and held-ness
  // (pointing at the file to change it) and the app's power_guard only
  // loads it; no settings TUI edits it on any platform.
  'power':
      'Sleep-prevention level and hold lifecycle (power.sleepPrevention, '
      'power.hold, #325/#326) is machine hardware policy for long-running '
      'sessions; /power and the app guard read it, only the file sets it.',
};

/// Which app surfaces carry a shared setting: the Flutter app on macOS,
/// iOS and web, plus the browser extension panel (issue #288 AC3/AC5).
/// Absent surfaces must name the CAPABILITY gap in [SettingSurfaces.gapWhy]
/// (E3) — never "didn't get to it".
final class SettingSurfaces {
  /// Creates the audit record for one setting.
  const SettingSurfaces({
    required this.macos,
    required this.ios,
    required this.web,
    required this.extensionPanel,
    this.gapWhy,
  });

  /// Present in the macOS build of the Flutter app.
  final bool macos;

  /// Present in the iOS build of the Flutter app.
  final bool ios;

  /// Present in the web build of the Flutter app.
  final bool web;

  /// Present in the browser extension panel (its own capability floor).
  final bool extensionPanel;

  /// Why the absent surfaces cannot carry the setting; null when every
  /// surface has it.
  final String? gapWhy;

  /// Whether any Flutter-app surface carries the setting.
  bool get anyApp => macos || ios || web;
}

/// The {macOS, iOS, web, extension} applicability audit (issue #288 AC3).
const settingSurfaces = <SharedSetting, SettingSurfaces>{
  SharedSetting.approvalMode: SettingSurfaces(
    macos: true,
    ios: true,
    web: true,
    extensionPanel: true,
  ),
  SharedSetting.modelDefault: SettingSurfaces(
    macos: true,
    ios: true,
    web: true,
    extensionPanel: true,
  ),
  SharedSetting.modelSmol: SettingSurfaces(
    macos: true,
    ios: true,
    web: true,
    extensionPanel: false,
    gapWhy:
        'The extension panel runs single embedded turns; the auxiliary '
        'role chains (quick/subagent model) have no selection surface there.',
  ),
  SharedSetting.mediaSlots: SettingSurfaces(
    macos: true,
    ios: true,
    web: true,
    extensionPanel: false,
    gapWhy: 'Media generation tools are not wired into the extension panel.',
  ),
  SharedSetting.customProviders: SettingSurfaces(
    macos: true,
    ios: true,
    web: true,
    extensionPanel: false,
    gapWhy:
        'The extension panel stores a single provider triple '
        '(settings_put provider.save), not a saved-provider registry.',
  ),
  SharedSetting.apiKeys: SettingSurfaces(
    macos: true,
    ios: true,
    web: true,
    extensionPanel: true,
  ),
  SharedSetting.skillsAccess: SettingSurfaces(
    macos: true,
    ios: true,
    web: false,
    extensionPanel: false,
    gapWhy:
        'Third-party skill roots live on the HOST filesystem '
        '(~/.claude, ~/.copilot, …); the browser sandbox and the extension '
        'have no host filesystem to read them from.',
  ),
  SharedSetting.dapHub: SettingSurfaces(
    macos: true,
    ios: true,
    web: true,
    extensionPanel: false,
    gapWhy: 'The extension panel has no DAP hub client.',
  ),
  SharedSetting.tools: SettingSurfaces(
    macos: true,
    ios: true,
    web: true,
    extensionPanel: true,
  ),
  SharedSetting.compactionEngine: SettingSurfaces(
    macos: true,
    ios: true,
    web: false,
    extensionPanel: false,
    gapWhy:
        'The app consumes the engine from the shared ~/.fah/config.yaml on '
        'io hosts (read-only, loadAppCompactionEngine); the browser sandbox '
        'and the extension have no shared config file — the web loader '
        'keeps the classic engine.',
  ),
  SharedSetting.mcpServers: SettingSurfaces(
    macos: false,
    ios: false,
    web: false,
    extensionPanel: false,
    gapWhy: 'MCP servers spawn host processes; no app surface can.',
  ),
  SharedSetting.ttsrRules: SettingSurfaces(
    macos: false,
    ios: false,
    web: false,
    extensionPanel: false,
    gapWhy: 'No app surface exposes per-delta stream hooks.',
  ),
  SharedSetting.cubeSandbox: SettingSurfaces(
    macos: false,
    ios: false,
    web: false,
    extensionPanel: false,
    gapWhy: 'Needs host-process sandboxing and a host shell.',
  ),
  SharedSetting.promptOverrides: SettingSurfaces(
    macos: false,
    ios: false,
    web: false,
    extensionPanel: false,
    gapWhy: 'App prompts are compiled in (prompts.g.dart).',
  ),
  SharedSetting.agentMode: SettingSurfaces(
    macos: false,
    ios: false,
    web: false,
    extensionPanel: false,
    gapWhy: 'Mode presets are a CLI REPL concept; apps compose prompts.',
  ),
  SharedSetting.memoryStores: SettingSurfaces(
    macos: false,
    ios: false,
    web: false,
    extensionPanel: false,
    gapWhy:
        'Memory roots are host filesystem paths; the app resolves them '
        'read-only.',
  ),
  SharedSetting.tuiTheme: SettingSurfaces(
    macos: false,
    ios: false,
    web: false,
    extensionPanel: false,
    gapWhy:
        'The palette colors a terminal emulator; the app themes through '
        'its own Flutter theming stack.',
  ),
  SharedSetting.redactionPolicy: SettingSurfaces(
    macos: false,
    ios: false,
    web: false,
    extensionPanel: false,
    gapWhy:
        'The redaction pipeline lives in the CLI host process (registered '
        'secrets in memory); no app surface has a pipeline to reconfigure.',
  ),
  SharedSetting.imageRegistry: SettingSurfaces(
    macos: false,
    ios: false,
    web: false,
    extensionPanel: false,
    gapWhy:
        'The image registry is process-wide state in the CLI host agent '
        'loop (the request-build rewrite); the app composes its own '
        'requests and reads the section read-only.',
  ),
  SharedSetting.resiliencePolicy: SettingSurfaces(
    macos: false,
    ios: false,
    web: false,
    extensionPanel: false,
    gapWhy:
        'The watchdog override and roles resolver live in the CLI host '
        'process; no app surface re-arms them.',
  ),
  SharedSetting.contextWindowCap: SettingSurfaces(
    macos: false,
    ios: false,
    web: false,
    extensionPanel: false,
    gapWhy:
        'The cap clamps the CLI agent loop and compaction math in the CLI '
        'host process; no app surface runs that loop.',
  ),
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
    yamlKeys: ['approvalMode'],
    description: 'Tool-approval mode (always-ask / write / yolo / unattended).',
  ),
  SharedSetting.modelDefault: _SettingMeta(
    cliRef: 'providerKind',
    appRef: 'DefaultChatModelSection',
    yamlKeys: ['provider', 'model', 'baseUrl'],
    description: 'The default chat model.',
  ),
  SharedSetting.modelSmol: _SettingMeta(
    cliRef: 'smolModelRole',
    appRef: 'TaskModelsStore',
    yamlKeys: ['roles'],
    description: 'Fast/cheap model for compaction and subagents.',
  ),
  SharedSetting.mediaSlots: _SettingMeta(
    cliRef: 'mediaModelSlotIds',
    appRef: 'MediaSlot.all',
    yamlKeys: ['models'],
    description: 'Per-modality media model overrides.',
  ),
  SharedSetting.customProviders: _SettingMeta(
    cliRef: 'CustomProviderEntry',
    appRef: 'ProviderRegistry',
    yamlKeys: ['customProviders'],
    description: 'Saved custom provider endpoints.',
  ),
  SharedSetting.apiKeys: _SettingMeta(
    cliRef: 'SecureKeyCache',
    appRef: 'SessionKeysStore',
    yamlKeys: [],
    // apiKeys covers NO yaml key: keys live in env vars / the platform
    // secure store (E1 — secrets never ride the yaml config). Classified
    // as a SharedSetting because both surfaces edit the same store.
    description: 'API key store.',
  ),
  SharedSetting.mcpServers: _SettingMeta(
    cliRef: 'McpConfig',
    appRef: null, // exempted — not yet supported in the app.
    yamlKeys: ['mcp'],
    description: 'External MCP tool servers.',
  ),
  SharedSetting.ttsrRules: _SettingMeta(
    cliRef: 'TtsrConfig',
    appRef: null, // exempted — not yet supported in the app.
    yamlKeys: ['ttsr'],
    description: 'Time-traveling stream rules.',
  ),
  SharedSetting.promptOverrides: _SettingMeta(
    cliRef: 'promptOverrides',
    appRef: null, // app does not expose prompt overrides — CLI-only.
    yamlKeys: ['prompts'],
    description: 'Prompt template overrides.',
  ),
  SharedSetting.skillsAccess: _SettingMeta(
    cliRef: 'skillsAccess',
    appRef: 'SkillsAccessStore',
    yamlKeys: ['skills'],
    description: 'Consent for reading third-party skill roots.',
  ),
  SharedSetting.cubeSandbox: _SettingMeta(
    cliRef: '/cube',
    appRef: null, // exempted — sandbox profiles are CLI-only (see above).
    yamlKeys: ['cube'],
    description: 'fa_cube sandbox profiles.',
  ),
  SharedSetting.dapHub: _SettingMeta(
    cliRef: 'config.plugins',
    appRef: 'DapHubSection',
    yamlKeys: [],
    // The hub connection is NOT a ~/.fah/config.yaml key: it lives in
    // ~/.dap/config.json + the .fah/packages.yaml plugin opt-out (E4-style
    // section entry covering the whole connection).
    description: 'DAP/1 hub connection (URL, agent name, channels).',
  ),
  SharedSetting.tools: _SettingMeta(
    cliRef: '/tools',
    appRef: 'ToolsAvailabilityStore',
    yamlKeys: ['tools', 'allowedTools'],
    description:
        'Capability-gated tool availability (hide unavailable/disabled '
        'tools).',
  ),
  SharedSetting.compactionEngine: _SettingMeta(
    cliRef: 'compactionEngine',
    // #295 named the app surface `CompactionSection` (the richer loader
    // symbol `loadAppCompactionEngine` also exists; the section is the
    // settings-parity surface this registry tracks).
    appRef: 'CompactionSection',
    yamlKeys: ['compaction'],
    description:
        'Compaction engine (structured default | classic rollback, #287).',
  ),
  SharedSetting.agentMode: _SettingMeta(
    cliRef: '_openModePicker',
    appRef: null, // exempted — modes are CLI-only (see above).
    yamlKeys: ['mode'],
    description: 'Agent mode preset (code / ask / plan …).',
  ),
  SharedSetting.memoryStores: _SettingMeta(
    cliRef: 'startMemoryStoresFlow',
    appRef: null, // exempted — host paths, CLI-only (see above).
    yamlKeys: ['memory'],
    description: 'Long-term memory store locations.',
  ),
  SharedSetting.tuiTheme: _SettingMeta(
    cliRef: 'tuiTheme',
    appRef: null, // exempted — terminal theming, CLI-only (see above).
    yamlKeys: ['tui'],
    description: 'TUI palette (tui.theme + user themes, issue #279).',
  ),
  SharedSetting.redactionPolicy: _SettingMeta(
    cliRef: 'startRedactionFlow',
    appRef: null, // exempted — pipeline lives in the CLI host (see above).
    yamlKeys: ['redact'],
    description: 'Redaction pipeline policy (issue #391).',
  ),
  SharedSetting.imageRegistry: _SettingMeta(
    cliRef: 'startImagesFlow',
    appRef: null, // exempted — request-build global lives in the CLI host.
    yamlKeys: ['images'],
    description: 'Image registry kill switch + per-request cap (issue #395).',
  ),
  SharedSetting.contextWindowCap: _SettingMeta(
    cliRef: 'startContextCapFlow',
    appRef: null, // exempted — CLI agent loop only (see above).
    yamlKeys: ['agent'],
    description: 'Owner-side context cap (issue #394).',
  ),
  SharedSetting.resiliencePolicy: _SettingMeta(
    cliRef: 'startResilienceFlow',
    appRef: null, // exempted — lives in the CLI host (see above).
    yamlKeys: ['providerTimeouts', 'retry'],
    description: 'Provider failure resilience (issue #393).',
  ),
};

/// The [SharedSetting] that owns the yaml top-level [key], or null when no
/// shared setting covers it (the key must then be in [fileOnlyConfigKeys]
/// or it is unclassified — the completeness gate fails).
SharedSetting? settingForYamlKey(String key) {
  for (final entry in sharedSettingMetadata.entries) {
    if (entry.value.yamlKeys.contains(key)) return entry.key;
  }
  return null;
}

/// Whether [key] is classified: owned by a [SharedSetting] or documented
/// as file-only. The completeness gate (test/parity/
/// settings_completeness_test.dart) fails on any parsed key where this is
/// false.
bool isClassifiedYamlKey(String key) =>
    settingForYamlKey(key) != null || fileOnlyConfigKeys.containsKey(key);

/// Internal metadata record used by the parity tests.
final class _SettingMeta {
  const _SettingMeta({
    required this.cliRef,
    required this.appRef,
    required this.yamlKeys,
    required this.description,
  });

  /// A string that MUST appear in at least one file under `lib/src/cli/`.
  final String cliRef;

  /// A string that MUST appear in at least one file under `flutter_app/lib/`.
  /// `null` means this setting is exempted from the app (must be listed in
  /// [appOnlySettings]).
  final String? appRef;

  /// The top-level `~/.fah/config.yaml` keys this setting owns (empty for
  /// settings that live outside the yaml — env/secure-store keys, the DAP
  /// json config). The completeness gate maps every parsed key to exactly
  /// one owner.
  final List<String> yamlKeys;

  /// Human-readable description shown in test failure messages.
  final String description;
}
