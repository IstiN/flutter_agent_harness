/// Static configuration for an [AgentCli] session — extracted from
/// `agent_cli.dart` to keep it under the 2800-line gate.
part of 'agent_cli.dart';

/// Static configuration for an [AgentCli] session.
final class AgentCliConfig {
  /// Creates an [AgentCliConfig]. Not const: [modelRolesResolver] and
  /// [cubeSettings] are mutable (the settings-hub flows create/rewrite
  /// them on demand).
  AgentCliConfig({
    required this.model,
    required this.apiKey,
    required this.env,
    required this.sessionRoot,
    this.folderModelStateApplies = true,
    this.presenceStore,
    this.sessionName,
    this.providerKind = 'openai-completions',
    this.envVarIsSet,
    this.envVarValue,
    this.modelsFetcher,
    this.modelsHttpClient,
    this.tuiMouseCapture = true,
    this.systemPrompt,
    this.promptOverrides,
    this.visionConfig,
    this.transcribeConfig,
    this.webSearchConfig,
    this.sqliteEngine,
    this.lspConfig,
    this.mcpConfig,
    this.a2aConfig,
    this.plugins = const [],
    this.pluginConfig = const {},
    this.promptTemplateDirs = const [],
    this.initialMode = 'code',
    this.approvalMode = ApprovalMode.yolo,
    this.alwaysAllowTools = const {},
    this.modelRolesResolver,
    this.ttsr,
    this.memoryConfig,
    this.modelsConfig,
    this.onModelsConfigChanged,
    this.onModelChanged,
    this.onProviderChanged,
    this.secureKeys,
    this.customProviders,
    this.onSecretStored,
    this.onSecretGranted,
    this.onModeChanged,
    this.onApprovalChanged,
    this.skillsAccess = SkillsAccess.granted,
    this.skillsDisableShellExecution = false,
    this.onSkillsAccessChanged,
    this.isShiftPressed,
    this.processId,
    this.homeDir,
    this.tuiProgramHooks,
    this.openRouterOAuthExchangeFn,
    this.chatGptOAuthExchangeFn,
    this.copilotDeviceFlowFn,
    this.copilotUserFn,
    this.codeMieSsoAuthenticateFn,
    this.codeMieGuidedSetupFn,
    this.compactionSettings,
    this.cubeSpec,
    this.cubeSource,
    this.cubeSettings,
    this.onCubeSettingsChanged,
    this.cubeRegistryClient,
    this.osName,
  });

  /// The user's home directory, when the host has one (used for user-level
  /// skill/context discovery: `~/.fah/skills`, `~/.fah/AGENTS.md`). Null on
  /// sandboxed hosts (web) where only the project FS exists.
  final String? homeDir;

  /// Override for the compaction thresholds (ratio-based trigger, reserve
  /// and recent-token budgets). When `null`, `defaultCompactionSettings`
  /// is used (ratio 0.7, reserve 50000, keep 80000). Hosts plumb their
  /// `compaction:` yaml section through this field.
  final CompactionSettings? compactionSettings;

  /// Optional fa_cube sandbox spec applied for the whole session (from the
  /// `--cube`/`--cube-config` flags or the `cube:` config section). The
  /// execution env wraps it in a [SandboxedExecutionEnv]: filesystem and
  /// shell operations clamp to the cube's policies, `/cube` swaps it live.
  /// Null = no cube — the env passes through untouched.
  final CubeSpec? cubeSpec;

  /// Where [cubeSpec] came from: an explicit manifest path (contains `/`)
  /// or a cube name. `/cube reload` re-resolves it; `/cube use` overwrites
  /// it. Null when no cube was requested.
  final String? cubeSource;

  /// The host OS name (e.g. `linux`, `macos`), supplied by the executable —
  /// lib/src stays dart:io-free. `/cube` uses it to describe the OS sandbox
  /// backend. Null (tests, web) reports a generic passthrough instead.
  final String? osName;

  /// The `package:http` client for the fa1.dev cube registry
  /// (`/cube templates` / `/cube install`). Tests inject a mock; web hosts
  /// pass their shared browser-capable client. Null uses a fresh
  /// `http.Client()`.
  final http.Client? cubeRegistryClient;

  /// The live `cube:` config section (the saved sandbox startup default).
  /// The settings-hub Cube sandbox flow rewrites it; the host persists the
  /// new value after [onCubeSettingsChanged] fires. Mutable like
  /// [modelRolesResolver] ([CubeSettings] itself is immutable).
  CubeSettings? cubeSettings;

  /// Called when the saved cube default changes (the settings-hub Cube
  /// sandbox flow) so the executable can persist it. The flow awaits the
  /// hook before confirming, so persistence lands with the feedback line.
  final Future<void> Function()? onCubeSettingsChanged;

  /// Optional override for the OpenRouter OAuth code exchange. Tests inject a
  /// fake here so the `/provider openrouter oauth` flow can run without
  /// network. Production leaves this null and uses the real exchange endpoint.
  final Future<OpenRouterOAuthKey> Function({
    required String code,
    required String codeVerifier,
    String? label,
  })?
  openRouterOAuthExchangeFn;

  /// Optional override for the ChatGPT OAuth code exchange. Tests inject a
  /// fake here so the `/provider chatgpt oauth` flow can run without network.
  /// Production leaves this null and uses the real exchange endpoint.
  final Future<ChatGptOAuthCredentials> Function({
    required String code,
    required String redirectUri,
    required String verifier,
  })?
  chatGptOAuthExchangeFn;

  /// Optional override for the whole Copilot device flow (grant + poll),
  /// returning the GitHub token. Tests inject a fake so `/provider copilot`
  /// runs without network; production runs the real flow against
  /// github.com. [clientId] is the FA_COPILOT_CLIENT_ID override (null =
  /// the pinned VS Code Copilot client id); [onStatus] receives the
  /// waiting lines.
  final Future<String> Function({
    String? clientId,
    void Function(String status)? onStatus,
  })?
  copilotDeviceFlowFn;

  /// Optional override for the GitHub account lookup behind `/provider
  /// copilot` (GET api.github.com/user → login). Tests inject a fake;
  /// production calls [fetchGitHubLogin].
  final Future<String> Function(String githubToken)? copilotUserFn;

  /// Optional override for the CodeMie SSO browser flow
  /// (`/provider codemie sso`). Tests inject a fake returning canned
  /// credentials; production runs the localhost-callback browser flow.
  final Future<CodeMieSsoCredentials?> Function(
    String codeMieUrl,
    void Function(String) onStatus,
  )?
  codeMieSsoAuthenticateFn;

  /// Optional override for the post-SSO guided project/model selection.
  /// Tests inject a fake returning a canned model id; production runs the
  /// real guided flow (fetch projects, fetch models, pickers).
  final Future<String?> Function(
    String apiBase,
    String token,
    Future<String?> Function(
      String title,
      List<(String, String, String)> options,
    )
    pickOption,
    Future<String?> Function(String question, {bool secret}) askLine,
  )?
  codeMieGuidedSetupFn;

  /// Directories to scan for `/name` prompt templates (`.md` files).
  final List<String> promptTemplateDirs;

  /// Initial mode name (`code`, `architect`, `review`).
  final String initialMode;

  /// Initial approval mode (`/approval` switches it at runtime). Defaults to
  /// [ApprovalMode.yolo] — pre-approval-model CLI behavior — while critical
  /// `bash` patterns still prompt (or are denied when non-interactive).
  /// [ApprovalMode.unattended] additionally skips the critical interceptor:
  /// the session never blocks, for runs without a user present.
  final ApprovalMode approvalMode;

  /// Tools always-allowed from previous sessions (`/allow`, "approve always"
  /// answers), persisted by the embedding executable.
  final Set<String> alwaysAllowTools;

  /// Optional model-roles resolver (roles/fallback chains/key rotation from
  /// the CLI config). When set and its `default` role resolves, the agent
  /// runs through the resolver's fallback stream instead of the plain
  /// [providerKind]/[apiKey] wiring, compaction summarizes through the
  /// `smol` role, and `/model` renders the roles overview. Mutable: the
  /// settings-hub agent-models flow creates one on demand when the config
  /// had no `roles:` section (auxiliary roles resolve lazily; the default
  /// chain stays untouched).
  ModelRolesResolver? modelRolesResolver;

  /// Optional TTSR configuration (stream rules from the CLI config and the
  /// project rules file). When set and enabled, a [TtsrController] watches
  /// the agent's streams and drives abort/inject/retry on rule matches.
  final TtsrConfig? ttsr;

  /// Optional `memory:` section of `~/.fah/config.yaml` — long-term memory
  /// storage path overrides (git-backed project memory). Null = the
  /// historical `.fah/memory` layout.
  final MemoryConfig? memoryConfig;

  /// The live models config (the `models:` section of `~/.fah/config.yaml`),
  /// shared with the executable: `/models set`/`/models remove` mutate its
  /// media slot overrides and `/model <name>` resolves its custom model
  /// definitions; the host persists it after [onModelsConfigChanged]. Null
  /// (web, tests without one) disables the models-config commands.
  final ModelsConfig? modelsConfig;

  /// Called when the models config changes (`/models set`,
  /// `/models remove`) so the executable can persist it.
  final void Function()? onModelsConfigChanged;

  /// Called when the user switches the active model via `/model`.
  ///
  /// Awaiting the callback: the persistence it performs (global config +
  /// the per-folder model state) must complete before the process can exit
  /// — a `/model x` + `/exit` one-two would otherwise lose the switch.
  final Future<void> Function(Model model)? onModelChanged;

  /// Called when the user switches the active provider via `/provider`
  /// (legacy wiring only; roles mode reports through [onModelChanged]).
  /// Carries the new provider adapter kind and the resolved API key so the
  /// executable can redact an explicitly passed token and persist the
  /// provider/model/baseUrl triple. The key may be empty (keyless custom
  /// endpoints); it is never persisted by the executable.
  final Future<void> Function(String providerKind, String apiKey)?
  onProviderChanged;

  /// The platform secure-storage cache (macOS Keychain / Secret Service /
  /// Windows Credential Locker), preloaded by the host at startup. Backs the
  /// `/key` command and lets `/provider ... <token>` persist the token.
  /// Null (web, tests) disables secure storage: tokens stay session-only.
  final SecureKeyCache? secureKeys;

  /// The saved custom-provider registry (the `customProviders:` config
  /// section), shared with the executable: the CLI mutates it (wizard adds,
  /// per-provider model memory), the host persists it. Null (web, tests
  /// without one) disables saved providers — the wizard still switches but
  /// adds nothing to the list.
  final CustomProviderRegistry? customProviders;

  /// Called when the user stores a secret via `/key set`, so the executable
  /// can redact the value from tool results and session files.
  final void Function(String name, String value)? onSecretStored;

  /// Called when the agent requests a secret via the `request_secret` tool
  /// and the user grants it, so the executable can redact the value from
  /// tool results and inject it into the shell environment.
  final void Function(String name, String value)? onSecretGranted;

  /// Called when the user switches the active mode via `/mode`, `/code`,
  /// `/architect`, or `/review`.
  final void Function(String mode)? onModeChanged;

  /// Called when the approval state changes (`/approval`, `/allow`, or an
  /// "approve always" prompt answer) so the executable can persist it.
  final void Function()? onApprovalChanged;

  /// Consent for discovering third-party skill roots (Claude/Copilot/Codex
  /// directories). [SkillsAccess.granted] is the default (opt-out discovery —
  /// migrating users keep their existing skills with zero setup);
  /// [SkillsAccess.ask] makes an interactive host prompt once at startup
  /// (persisted via [onSkillsAccessChanged]); a headless run treats `ask` as
  /// denied. Own roots (`.fah/skills`, `.agents/skills`) are always
  /// discovered.
  final SkillsAccess skillsAccess;

  /// When true, `!`command`` shell injections inside skill bodies are not
  /// executed; the placeholder renders as a disabled note instead.
  final bool skillsDisableShellExecution;

  /// Called when the skills-access consent changes (startup prompt,
  /// `/skills access ...`) so the executable can persist it.
  final void Function(SkillsAccess access)? onSkillsAccessChanged;

  /// Host-provided Shift modifier check (e.g. macOS Core Graphics via FFI).
  /// When null, Shift+Enter is not specially handled.
  final bool Function()? isShiftPressed;

  /// The host process id (diagnostics on the presence heartbeat). Null
  /// where the platform exposes no pid (web).
  final int? processId;

  /// Headless TUI test hooks (scripted key bytes, captured frames) handed to
  /// the TUI controller — null in production, where the dart_tui program
  /// reads stdin and renders to the real terminal.
  final TuiProgramHooks? tuiProgramHooks;

  /// The model to run. `/model <id>` swaps the id at runtime.
  final Model model;

  /// API key for the provider. Only used when no [StreamFunction] override
  /// is injected into [AgentCli] and no [modelRolesResolver] covers the
  /// default role.
  final String apiKey;

  /// Execution environment backing the built-in tools and session storage.
  final ExecutionEnv env;

  /// Root directory for JSONL sessions (cwd-encoded layout, like pi).
  final String sessionRoot;

  /// Whether the saved per-folder model memory may override the resolved
  /// config for session loads (bin/fah.dart computes it from the launch
  /// pins: --model/--provider/--base-url and the FA_PROVIDER_* preconfig
  /// disable it). Defaults to true so tests and embedded hosts behave like
  /// an unpinned launch.
  final bool folderModelStateApplies;

  /// Live-session presence heartbeats: the running CLI registers its
  /// session here so the Fa app (sharing the sessions root) can mark the
  /// session live and attach to it. Null (tests, web) disables presence.
  final SessionPresenceStore? presenceStore;

  /// Optional session name to resume or create on startup.
  final String? sessionName;

  /// Provider adapter kind: `openai-completions`, `anthropic`, or `google`.
  final String providerKind;

  /// Reports whether an environment variable is set (non-empty) on the
  /// host. The startup banner uses it to name the provider key env var in
  /// play — the name only, never the value. Null (tests, web) behaves as
  /// "unset", so the banner then warns instead of naming a var.
  final bool Function(String name)? envVarIsSet;

  /// Reads an environment variable's value on the host (null/empty treated
  /// as unset). `/provider` uses it to resolve the target provider's API key
  /// from its catalog env names when no explicit token is passed. Null
  /// (tests, web) means no key is ever found this way.
  final String? Function(String name)? envVarValue;

  /// Fetches model ids from an OpenAI-compatible `/models` endpoint (the
  /// `/models` picker and the custom-provider flow). Null uses the built-in
  /// HTTP implementation; tests inject a fake.
  final Future<List<String>> Function(String baseUrl, {required String apiKey})?
  modelsFetcher;

  /// HTTP client override for the non-OpenAI model-list dialects the
  /// settings flows dispatch to (DIAL deployments, CodeMie `/llm_models`) —
  /// [modelsFetcher] only covers the OpenAI shape. Null (production) lets
  /// the fetchers create their own client; tests inject a `MockClient`.
  final http.Client? modelsHttpClient;

  /// Whether the TUI captures the mouse for wheel scrolling. Default true:
  /// the session renders in the alternate screen, where the terminal has no
  /// native scrollback — without capture a two-finger scroll does nothing
  /// and the user cannot reach earlier output. Selection still works via
  /// the terminal's bypass modifier (Shift in most). `FA_TUI_MOUSE=0` opts
  /// out for always-on native select-to-copy.
  final bool tuiMouseCapture;

  /// System prompt override; defaults to [defaultAgentCliSystemPrompt].
  ///
  /// Wins over [promptOverrides] and the active mode's prompt (the
  /// `--system-prompt`/`--system-prompt-file` flags map here). A `/mode`
  /// switch replaces it with the mode's prompt.
  final String? systemPrompt;

  /// Prompt overrides from the CLI config `prompts:` section (resolved by
  /// the executable via `resolvePromptOverrides`). Replaces the mode system
  /// prompts (`cli/mode_*` names — startup and `/mode` switches) and the
  /// compaction summarization prompts (`compaction/*` names). Null or empty
  /// keeps the built-in prompts byte-identical.
  final PromptOverrides? promptOverrides;

  /// Optional vision model configuration. When provided, the `inspect_image`
  /// tool is registered and routes image analysis to a dedicated model.
  ///
  /// Prefer using the `inspect_image` plugin via [plugins] / [pluginConfig].
  final InspectImageConfig? visionConfig;

  /// Optional transcription endpoint configuration. When provided, the
  /// `transcribe_audio` tool is registered and routes audio transcription to
  /// a Whisper-compatible endpoint.
  ///
  /// Prefer using the `transcribe_audio` plugin via [plugins] /
  /// [pluginConfig].
  final TranscribeAudioConfig? transcribeConfig;

  /// Optional web search configuration. When provided, `web_search` and
  /// `web_fetch` are registered (see [builtinTools]); keyless DuckDuckGo
  /// works with all defaults, keyed providers read their API keys from the
  /// config's [SecretsStore].
  final WebSearchConfig? webSearchConfig;

  /// Optional SQLite engine enabling `read` targets like `data.db:table`.
  /// Pass the FFI-backed engine from `lib/io.dart` on native hosts; leave
  /// null on web (SQLite reads then return a clean "not supported" note).
  final SqliteEngine? sqliteEngine;

  /// Optional LSP configuration enabling the `lsp` tool (diagnostics /
  /// definition / references / rename). Pass a config with the process
  /// transport factory from `lib/io.dart` on native hosts; leave null on
  /// web (the tool is not registered).
  final LspToolConfig? lspConfig;

  /// Optional MCP configuration (the `mcp:` config section). Servers
  /// connect lazily in the background at startup; each advertised tool is
  /// registered as `mcp__<server>__<tool>` (exec approval tier) and the
  /// system prompt gains a tiny server-status section. Stdio servers need
  /// the process transport factory from `lib/io.dart`; remote (HTTP)
  /// servers work on every host. Null disables MCP.
  final McpToolConfig? mcpConfig;

  /// Optional A2A remote-agent configuration (the `a2a:` config section,
  /// Phase 5a). Servers connect lazily; items with the agent type
  /// `a2a:<name>` run against the remote agent through the `task` tool.
  /// Null disables A2A.
  final A2aConfig? a2aConfig;

  /// Plugins to register at startup.
  final List<FahPlugin> plugins;

  /// Per-plugin configuration from `.fah/packages.yaml` (keyed by plugin name).
  final Map<String, dynamic> pluginConfig;
}
