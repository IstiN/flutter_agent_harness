/// The terminal CLI core: a REPL that wires an [Agent] with the built-in
/// tools, streams events to the user, persists sessions, and compacts
/// context — all behind the injectable [CliIO] abstraction so it is fully
/// testable without a real terminal.
///
/// Shaped after pi-mono's coding-agent REPL (`packages/coding-agent/src/
/// cli` + `modes`), reduced to a plain line-based interface: assistant text
/// streams live, tool executions render as one-liners, and slash commands
/// (`/exit`, `/reset`, `/compact`, `/stats`, `/model`, `/help`) manage the
/// session. While a run is streaming, typed input is steered into the agent
/// (pi's first-class steering), and [CliIO.interrupts] abort it.
///
/// The real terminal wiring (stdin/stdout, SIGINT) lives in `bin/fah.dart`;
/// this library stays pure Dart.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../agent/agent.dart';
import 'key_event.dart';
import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../agent/tool_registry.dart';
import '../task/task.dart';
import '../skills/skills.dart';
import '../prompts/project_context.dart';
import '../approval/approval.dart';
import '../approval/approval_hook.dart';
import '../cancel_token.dart';
import '../compaction/compaction.dart';
import '../compaction/token_estimation.dart';
import '../context.dart';
import '../env/execution_env.dart';
import '../exceptions.dart';
import '../lsp/lsp_tool.dart';
import '../model.dart';
import '../model_roles/model_roles.dart';
import '../prompts/prompt_overrides.dart';
import '../secrets/secure_key_store.dart';
import '../session/session_repo.dart';
import 'custom_providers.dart';
import 'provider_flow.dart';
import '../session/session_storage.dart';
import '../session/session_tree.dart';
import '../tools/ask_tool.dart';
import '../tools/builtin_tools.dart';
import '../tools/checkpoint_tool.dart';
import '../tools/inspect_image.dart';
import '../tools/sqlite/sqlite_reader.dart';
import '../tools/transcribe_audio.dart';
import '../plugins/plugin.dart';
import '../ttsr/ttsr.dart';
import '../types.dart';
import '../usage_summary.dart';
import '../web_search/web_search.dart';
// The interactive dart_tui REPL is VM-only (raw terminal + FFI); web builds
// of the root library get a no-op stub with the same host-facing API.
import 'fa_tui_stub.dart' if (dart.library.io) 'fa_tui.dart';
import 'prompt_templates.dart';
import 'tui_repl.dart';

export '../model_roles/provider_catalog.dart' show providerStreamFunction;

part 'provider_commands.dart';

/// Terminal IO abstracted for testability.
///
/// The real implementation (in `bin/fah.dart`) binds [lines] to stdin,
/// [write]/[writeln] to stdout, and [interrupts] to SIGINT; tests substitute
/// scripted lines and capture output in memory.
///
/// The two output methods are separate channels: [write] carries the primary
/// stream (assistant text deltas, the input prompt), [writeln] carries
/// one-line diagnostics (tool indicators, notices, errors). The interactive
/// terminal merges both on stdout; a headless host routes [writeln] to
/// stderr so stdout stays pipeable.
abstract interface class CliIO {
  /// User-typed input lines, without the trailing newline.
  Stream<String> get lines;

  /// Cancel signals (Ctrl-C). Each event aborts the current run.
  Stream<void> get interrupts;

  /// Raw key events when the terminal is in raw mode. Non-raw hosts (tests,
  /// headless, web) provide an empty stream.
  Stream<KeyEvent> get keys;

  /// Whether the underlying terminal supports raw-mode character input with
  /// ANSI escape sequences. True for dart:io terminals; false for tests and
  /// headless runs.
  bool get supportsRawMode;

  /// Writes [text] without a trailing newline (streaming deltas).
  void write(String text);

  /// Writes [text] followed by a newline.
  void writeln(String text);

  /// Whether a human is present to answer approval prompts (a real terminal,
  /// not piped input). When false, the CLI installs no approval prompt
  /// callback, so prompt-policy tool calls are denied with a reason — the
  /// safe non-interactive default.
  bool get isInteractive;

  /// Terminal width in columns. Non-TUI hosts use the 80-column default.
  int get columns => 80;

  /// Terminal height in rows. Non-TUI hosts use the 24-row default.
  int get rows => 24;
}

/// Static configuration for an [AgentCli] session.
final class AgentCliConfig {
  /// Creates an [AgentCliConfig].
  const AgentCliConfig({
    required this.model,
    required this.apiKey,
    required this.env,
    required this.sessionRoot,
    this.sessionName,
    this.providerKind = 'openai-completions',
    this.envVarIsSet,
    this.envVarValue,
    this.modelsFetcher,
    this.systemPrompt,
    this.promptOverrides,
    this.visionConfig,
    this.transcribeConfig,
    this.webSearchConfig,
    this.sqliteEngine,
    this.lspConfig,
    this.plugins = const [],
    this.pluginConfig = const {},
    this.promptTemplateDirs = const [],
    this.initialMode = 'code',
    this.approvalMode = ApprovalMode.yolo,
    this.alwaysAllowTools = const {},
    this.modelRolesResolver,
    this.ttsr,
    this.onModelChanged,
    this.onProviderChanged,
    this.secureKeys,
    this.customProviders,
    this.onSecretStored,
    this.onModeChanged,
    this.onApprovalChanged,
    this.isShiftPressed,
    this.homeDir,
  });

  /// The user's home directory, when the host has one (used for user-level
  /// skill/context discovery: `~/.fah/skills`, `~/.fah/AGENTS.md`). Null on
  /// sandboxed hosts (web) where only the project FS exists.
  final String? homeDir;

  /// Directories to scan for `/name` prompt templates (`.md` files).
  final List<String> promptTemplateDirs;

  /// Initial mode name (`code`, `architect`, `review`).
  final String initialMode;

  /// Initial approval mode (`/approval` switches it at runtime). Defaults to
  /// [ApprovalMode.yolo] — pre-approval-model CLI behavior — while critical
  /// `bash` patterns still prompt (or are denied when non-interactive).
  final ApprovalMode approvalMode;

  /// Tools always-allowed from previous sessions (`/allow`, "approve always"
  /// answers), persisted by the embedding executable.
  final Set<String> alwaysAllowTools;

  /// Optional model-roles resolver (roles/fallback chains/key rotation from
  /// the CLI config). When set and its `default` role resolves, the agent
  /// runs through the resolver's fallback stream instead of the plain
  /// [providerKind]/[apiKey] wiring, compaction summarizes through the
  /// `smol` role, and `/model` renders the roles overview.
  final ModelRolesResolver? modelRolesResolver;

  /// Optional TTSR configuration (stream rules from the CLI config and the
  /// project rules file). When set and enabled, a [TtsrController] watches
  /// the agent's streams and drives abort/inject/retry on rule matches.
  final TtsrConfig? ttsr;

  /// Called when the user switches the active model via `/model`.
  final void Function(Model model)? onModelChanged;

  /// Called when the user switches the active provider via `/provider`
  /// (legacy wiring only; roles mode reports through [onModelChanged]).
  /// Carries the new provider adapter kind and the resolved API key so the
  /// executable can redact an explicitly passed token and persist the
  /// provider/model/baseUrl triple. The key may be empty (keyless custom
  /// endpoints); it is never persisted by the executable.
  final void Function(String providerKind, String apiKey)? onProviderChanged;

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

  /// Called when the user switches the active mode via `/mode`, `/code`,
  /// `/architect`, or `/review`.
  final void Function(String mode)? onModeChanged;

  /// Called when the approval state changes (`/approval`, `/allow`, or an
  /// "approve always" prompt answer) so the executable can persist it.
  final void Function()? onApprovalChanged;

  /// Host-provided Shift modifier check (e.g. macOS Core Graphics via FFI).
  /// When null, Shift+Enter is not specially handled.
  final bool Function()? isShiftPressed;

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

  /// Plugins to register at startup.
  final List<FahPlugin> plugins;

  /// Per-plugin configuration from `.fah/packages.yaml` (keyed by plugin name).
  final Map<String, dynamic> pluginConfig;
}

/// The default system prompt for the CLI agent.
String defaultAgentCliSystemPrompt(String cwd) =>
    defaultAgentMode(cwd).systemPrompt;

/// Known model ids shown by `/models` and the `/model` picker. Maps the
/// provider name stored on the active [Model] to a short, useful subset.
const _knownModels = <String, List<String>>{
  'openrouter': [
    'anthropic/claude-sonnet-4',
    'openai/gpt-4o-mini',
    'google/gemini-2.5-pro',
    'anthropic/claude-opus-4',
    'openai/gpt-4.1-mini',
  ],
  'anthropic': ['claude-sonnet-4-5', 'claude-opus-4', 'claude-haiku-4'],
  'google': ['gemini-2.5-pro', 'gemini-2.0-flash'],
  'openai': ['gpt-4o-mini', 'gpt-4o', 'gpt-4.1-mini'],
};

/// Adapts [CliIO] to the [PluginIO] surface exposed to plugins.
final class _PluginIO implements PluginIO {
  _PluginIO(this._io);

  final CliIO _io;

  @override
  void write(String text) => _io.write(text);

  @override
  void writeln(String text) => _io.writeln(text);
}

/// Wraps another [CliIO] and routes [write]/[writeln] into the active
/// [FaTuiController] output history while it is running. Input and interrupt
/// streams are delegated unchanged.
final class _TuiCliIO implements CliIO {
  _TuiCliIO(this._delegate);

  final CliIO _delegate;
  FaTuiController? _tui;

  @override
  Stream<String> get lines => _delegate.lines;

  @override
  Stream<void> get interrupts => _delegate.interrupts;

  @override
  Stream<KeyEvent> get keys => _delegate.keys;

  @override
  bool get supportsRawMode => _delegate.supportsRawMode;

  @override
  bool get isInteractive => _delegate.isInteractive;

  @override
  int get columns => _delegate.columns;

  @override
  int get rows => _delegate.rows;

  @override
  void write(String text) {
    final tui = _tui;
    if (tui != null) {
      tui.sendOutput(text);
    } else {
      _delegate.write(text);
    }
  }

  @override
  void writeln(String text) {
    final tui = _tui;
    if (tui != null) {
      tui.sendOutput(text, newline: true);
    } else {
      _delegate.writeln(text);
    }
  }
}

/// Minimal ANSI styling helper. When [enabled] is false all methods return
/// the input unchanged, which keeps tests deterministic and avoids escape
/// sequences in headless / piped output.
final class _Style implements TuiStyle {
  _Style({required this.enabled});
  final bool enabled;

  String _wrap(String text, String code) =>
      enabled ? '\x1B[${code}m$text\x1B[0m' : text;

  @override
  String bold(String text) => _wrap(text, '1');
  @override
  String dim(String text) => _wrap(text, '2');
  String italic(String text) => _wrap(text, '3');
  String underline(String text) => _wrap(text, '4');
  @override
  String cyan(String text) => _wrap(text, '36');
  @override
  String green(String text) => _wrap(text, '32');
  @override
  String yellow(String text) => _wrap(text, '33');
  String red(String text) => _wrap(text, '31');
  @override
  String magenta(String text) => _wrap(text, '35');

  /// The site's teal accent (#5eead4), used for the banner title.
  String teal(String text) =>
      enabled ? '\x1B[38;2;94;234;212m$text\x1B[0m' : text;

  /// The site's indigo accent-2 (#818cf8), used for tool call markers.
  String indigo(String text) =>
      enabled ? '\x1B[38;2;129;140;248m$text\x1B[0m' : text;
}

/// Reduces a provider error blob to something readable on one line:
/// unwraps OpenRouter's `metadata.raw` upstream JSON recursively, prefers
/// the most specific message, and caps the result at 300 chars.
String compactProviderError(String message) {
  Map<String, dynamic>? decodeJson(String text) {
    final start = text.indexOf('{');
    if (start < 0) return null;
    try {
      final decoded = jsonDecode(text.substring(start));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }

  String? extract(Map<String, dynamic> json) {
    final error = json['error'];
    if (error is! Map<String, dynamic>) return null;
    final metadata = error['metadata'];
    if (metadata is Map<String, dynamic>) {
      final raw = metadata['raw'];
      if (raw is String) {
        final upstream = decodeJson(raw);
        final upstreamMessage = upstream == null ? null : extract(upstream);
        if (upstreamMessage != null) {
          final provider = metadata['provider_name'];
          return provider is String
              ? '$upstreamMessage ($provider)'
              : upstreamMessage;
        }
      }
    }
    final msg = error['message'];
    return msg is String && msg.isNotEmpty ? msg : null;
  }

  var result = message;
  final json = decodeJson(message);
  final extracted = json == null ? null : extract(json);
  if (extracted != null) {
    final code = RegExp(r'^\d{3}').firstMatch(message)?.group(0);
    result = '${code != null ? '$code: ' : ''}$extracted';
  }
  if (result.length > 300) result = '${result.substring(0, 300)}…';
  return result;
}

/// The CLI harness: agent + built-in tools + session persistence +
/// compaction, driven by a [CliIO].
class AgentCli {
  /// Creates an [AgentCli]. [streamFunction] overrides the provider adapter
  /// (used in tests); otherwise one is built from
  /// [AgentCliConfig.providerKind] and [AgentCliConfig.apiKey].
  AgentCli({
    required this.config,
    required CliIO io,
    StreamFunction? streamFunction,
    this.prompt = 'fa> ',
    bool useColor = false,
    bool useTui = false,
    this._version = '0.0.0',
  }) : io = useTui && io.supportsRawMode ? _TuiCliIO(io) : io,
       _style = _Style(enabled: useColor),
       _useTui = useTui && io.supportsRawMode,
       _modes = builtInAgentModes(
         config.env.cwd,
         overrides: config.promptOverrides,
       ) {
    _currentMode = _modes[config.initialMode] ?? _modes['code']!;
    _providerKind = config.providerKind;
    _apiKey = config.apiKey;
    final pluginTools = <AgentTool>[];
    for (final plugin in config.plugins) {
      final context = PluginContext(
        env: config.env,
        io: _PluginIO(io),
        config: _pluginConfig(plugin.name),
      );
      plugin.register(context);
      pluginTools.addAll(context.tools);
      _pluginSlashCommands.addAll(context.slashCommands);
    }

    _streamFunction =
        streamFunction ??
        providerStreamFunction(config.providerKind, config.apiKey);
    final coreTools = <AgentTool>[
      ...builtinTools(
        config.env,
        webSearch: config.webSearchConfig,
        model: () => _agent.state.model,
        sqlite: config.sqliteEngine,
        lsp: config.lspConfig,
      ),
      // Non-interactive input (piped) gets a null ask callback: ask calls
      // then fail with a "host cannot answer" error result (safe default).
      askTool(callback: io.isInteractive ? _answerAskQuestions : null),
      if (config.visionConfig != null)
        inspectImageTool(config.env, config.visionConfig!),
      if (config.transcribeConfig != null)
        transcribeAudioTool(config.env, config.transcribeConfig!),
      ...pluginTools,
    ];
    // The `task` tool (omp's background subagents): children draw from the
    // core tool surface (never `task` itself), completions are injected back
    // into the parent conversation as async-result messages.
    _taskConfig = TaskToolConfig(
      childTools: coreTools,
      streamFunction: _streamFunction,
      model: config.model,
      rolesResolver: config.modelRolesResolver,
    );
    _toolRegistry = ToolRegistry([...coreTools, taskTool(config: _taskConfig)]);
    _agent = Agent(
      model: config.model,
      systemPrompt: config.systemPrompt ?? _currentMode.systemPrompt,
      streamFunction: _streamFunction,
      toolRegistry: _toolRegistry,
    );
    // Model roles: when the default role resolves, the agent runs through
    // the resolver's fallback stream (rotation/failover per provider call).
    // A resolver without a default role leaves the legacy wiring in place
    // and only serves auxiliary roles (e.g. smol for compaction).
    final rolesResolver = config.modelRolesResolver;
    if (rolesResolver != null) {
      rolesResolver.onNotice = _onRolesNotice;
      if (rolesResolver.resolveRole(defaultModelRole) != null) {
        rolesResolver.applyToAgent(_agent);
        _streamFunction = _agent.streamFunction;
        _rolesDriven = true;
      }
    }
    _approval = ApprovalManager(
      mode: config.approvalMode,
      alwaysAllow: config.alwaysAllowTools,
      // Non-interactive input (piped) gets no prompt callback: prompt-policy
      // calls are then denied with a "no approval UI" reason (safe default).
      prompt: io.isInteractive ? _promptForApproval : null,
    );
    attachApproval(_agent, _approval);
    _checkpoints = CheckpointRewindController(
      agent: _agent,
      sink: CheckpointSessionSink(
        session: () => _session,
        persistedMessageCount: () => _persistedCount,
        persistMessage: _persistOneMessage,
      ),
      // The rewind prunes the transcript after persisting the detour itself;
      // realign the batch-persistence cursor with the pruned count.
      onRewindApplied: (messageCount) => _persistedCount = messageCount,
    );
    // Register after agent construction (the controller needs the agent);
    // the registry's executor consults the live registry, while the agent's
    // tool list was seeded at construction and needs the explicit update.
    _toolRegistry.registerAll(_checkpoints.tools);
    _agent.state.tools = _toolRegistry.tools;
    _agent.subscribe(_onAgentEvent);
    final ttsrConfig = config.ttsr;
    if (ttsrConfig != null && ttsrConfig.settings.enabled) {
      final manager = TtsrManager(settings: ttsrConfig.settings);
      for (final rule in ttsrConfig.rules) {
        manager.addRule(rule);
      }
      for (final warning in manager.warnings) {
        io.writeln('[ttsr] $warning');
      }
      if (manager.hasRules()) {
        _ttsr = TtsrController(
          agent: _agent,
          manager: manager,
          sink: TtsrSessionSink(
            session: () => _session,
            persistedMessageCount: () => _persistedCount,
            persistMessage: _persistOneMessage,
            persistInjection: _persistTtsrInjection,
          ),
          onTriggered: (rules) => io.writeln(
            '[ttsr] rule violation: '
            '${rules.map((rule) => rule.name).join(', ')} — retrying',
          ),
          onWarning: (message) => io.writeln('[ttsr] $message'),
        );
      }
    }
  }

  /// The active mode.
  AgentMode get currentMode => _currentMode;

  /// The effective system prompt sent to the model.
  String get systemPrompt => _agent.state.systemPrompt;

  /// The underlying [Agent] driving the session.
  Agent get agent => _agent;

  /// The approval gate attached to the agent: mode, per-tool overrides, and
  /// the session always-allow set (`/approval`, `/allow`).
  ApprovalManager get approval => _approval;

  /// The checkpoint/rewind controller: its `checkpoint` and `rewind` tools
  /// are registered on the agent, and it applies rewinds at turn end.
  CheckpointRewindController get checkpoints => _checkpoints;

  /// The TTSR controller, when stream rules are configured ([AgentCliConfig.ttsr]).
  TtsrController? get ttsr => _ttsr;

  /// The static configuration.
  final AgentCliConfig config;

  /// Terminal IO.
  final CliIO io;

  /// The input prompt written when the agent is idle.
  final String prompt;

  /// The provider stream backing runs and (legacy) compaction. Mutable:
  /// model-roles wiring and `/model`/`/provider` switches replace it.
  late StreamFunction _streamFunction;

  /// The live provider adapter kind and API key. Initialized from
  /// [AgentCliConfig.providerKind]/[AgentCliConfig.apiKey]; a `/provider`
  /// switch replaces them (the `/models` fetch and the banner key-status
  /// line read the live values, the executable persists [providerKind]).
  late String _providerKind;
  late String _apiKey;

  /// Whether the live key came from an explicit `/provider` token (the key
  /// status line then reads "provided" instead of naming an env var).
  var _explicitToken = false;

  /// The live provider adapter kind (see [_providerKind]).
  String get providerKind => _providerKind;

  /// The `task` tool's session config: child tool surface, stream wiring,
  /// and the background [TaskJobManager] whose completions are injected
  /// back into the parent conversation (omp's async-result flow).
  late final TaskToolConfig _taskConfig;
  late final Agent _agent;
  late final ApprovalManager _approval;
  late final ToolRegistry _toolRegistry;
  late final CheckpointRewindController _checkpoints;
  TtsrController? _ttsr;
  final _Style _style;
  final bool _useTui;
  final String _version;

  /// Whether the default role resolved and drives the agent (roles mode).
  /// The banner's key-status line reads env var names from the live model's
  /// provider then; legacy mode reads them from the provider kind.
  var _rolesDriven = false;
  final _usage = UsageAccumulator();
  late final _repo = JsonlSessionRepo(
    fs: config.env,
    sessionsRoot: config.sessionRoot,
  );
  Session? _session;
  var _persistedCount = 0;
  var _streamedText = false;

  /// Whether the current assistant message already printed its `fa> ` prefix
  /// and whether any thinking deltas were streamed (TUI-only progress for
  /// reasoning models).
  var _assistantPrefixPrinted = false;
  var _streamedThinking = false;
  var _exited = false;

  /// Set when the user interrupts (Esc/Ctrl-C); the TUI drain loop discards
  /// queued messages instead of starting new turns after an abort.
  var _abortRequested = false;
  Future<void> _settled = Future<void>.value();

  /// The pending approval-prompt answer, if a tool call is waiting on the
  /// user. While set, [_handleLine] routes typed lines here instead of
  /// steering them into the agent.
  Completer<String>? _pendingApprovalAnswer;

  /// The pending ask-menu input line, if an `ask` tool call is waiting on
  /// the user. Unlike the approval prompt, EMPTY lines are routed here too:
  /// empty input is the menu's free-text affordance. Completes with `null`
  /// on cancel (Ctrl-C, input shutdown).
  Completer<String?>? _pendingAskAnswer;

  /// The pending CLI-prompt input line, if a guided flow (the custom
  /// provider setup) is waiting on a free-form answer. Like the ask routing,
  /// EMPTY lines complete too (the key step's "none" affordance); `null` on
  /// cancel (Ctrl-C, input shutdown).
  Completer<String?>? _pendingPromptAnswer;
  final Map<String, SlashCommand> _pluginSlashCommands = {};
  final Map<String, AgentMode> _modes;
  late AgentMode _currentMode;
  List<PromptTemplate> _templates = [];

  /// Discovered agent skills (progressive disclosure into the system
  /// prompt) and project context files, loaded once per CLI run.
  List<Skill> _skills = const [];
  List<ProjectContextFile> _contextFiles = const [];

  /// Rebuilds the agent's system prompt from the active mode (or the
  /// explicit override) plus the project-context and skills sections
  /// (pi/kimi-style: appended after the base prompt).
  void _applyPromptComposition() {
    final base = config.systemPrompt ?? _currentMode.systemPrompt;
    final contextSection = formatProjectContext(_contextFiles);
    final skillsSection = formatSkillsForPrompt(_skills);
    _agent.state.systemPrompt = [
      base,
      if (contextSection.isNotEmpty) contextSection,
      if (skillsSection.isNotEmpty) skillsSection,
    ].join('\n\n');
  }

  /// Model ids shown by the most recent `/model` picker, so `/model N` can
  /// select by number without retyping the full id.
  List<String>? _lastModelList;

  /// Cache of model ids fetched from an OpenAI-compatible `/models` endpoint,
  /// plus the in-flight refresh future so concurrent callers coalesce.
  List<String> _modelCache = const [];
  Future<void>? _modelCacheFuture;

  /// Reference to the active TUI controller so asynchronous model-list updates
  /// can refresh the picker while it is open.
  FaTuiController? _tuiController;

  Map<String, dynamic> _pluginConfig(String name) {
    final raw = config.pluginConfig[name];
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const {};
  }

  /// Whether a run is currently streaming.
  bool get isBusy => _agent.state.isStreaming;

  /// Runs the REPL until `/exit` or the input stream closes.
  Future<void> run() async {
    _templates = await loadPromptTemplates(
      config.env,
      config.promptTemplateDirs,
    );
    final roots = defaultSkillRoots(
      cwd: config.env.cwd,
      homeDir: config.homeDir,
    );
    _skills = await discoverSkills(
      config.env,
      projectRoots: roots.projectRoots,
      userRoots: roots.userRoots,
    );
    _contextFiles = await loadProjectContextFiles(
      config.env,
      userFile: config.homeDir == null
          ? null
          : '${config.homeDir}/.fah/AGENTS.md',
    );
    _applyPromptComposition();
    _session = await _initializeSession();
    final interruptSub = io.interrupts.listen((_) {
      if (isBusy) _agent.abort();
    });
    final taskSub = _taskConfig.jobManager.completions.listen(
      _onTaskJobCompleted,
    );
    try {
      if (_useTui) {
        // The TUI prints the banner itself into its output history (buffered
        // by the controller until the program's event loop is listening).
        await _runTuiRepl();
      } else {
        await _printBanner();
        final resumedLabel = await _resumedSessionLabel();
        if (resumedLabel != null) {
          _replayRestoredHistory(_agent.state.messages, resumedLabel);
        }
        _writeIdlePrompt();
        final lineIterator = StreamIterator<String>(io.lines);
        while (await lineIterator.moveNext()) {
          var line = lineIterator.current;
          if (line.trim() == '/') {
            final choice = await _showLineModeMenu(lineIterator);
            if (choice != null) line = choice;
          }
          await _handleLine(line);
          if (_exited) break;
          // No idle prompt while a guided flow owns input: its questions
          // would interleave with the status bar, and each answered prompt
          // would print a redundant one.
          if (!isBusy && !_providerFlowActive) _writeIdlePrompt();
        }
      }
    } finally {
      // Input ended (EOF) or the REPL is shutting down: never leave a tool
      // call waiting on an answer that cannot arrive.
      _pendingApprovalAnswer?.complete('n');
      _pendingApprovalAnswer = null;
      _pendingAskAnswer?.complete(null);
      _pendingAskAnswer = null;
      await interruptSub.cancel();
      await taskSub.cancel();
      await _settled;
    }
  }

  Future<void> _runTuiRepl() async {
    late final FaTuiController controller;
    controller = FaTuiController(
      callbacks: FaTuiCallbacks(
        onSubmit: (line) async {
          controller.sendBusy(true);
          try {
            await _handleLine(line);
            // Runs are fire-and-forget (_startRun only records the future):
            // wait for the run to actually settle so the busy spinner lives
            // for the whole stream instead of flashing for one frame.
            await _settled;
            // Drain queued messages one-by-one as separate turns (kimi-cli
            // semantics), capped to bound a self-sustaining queue; an Esc
            // abort discards the queue instead of starting new work.
            var drainedRounds = 0;
            for (;;) {
              final queued = await controller.drainQueue();
              if (queued.isEmpty) break;
              if (_abortRequested || drainedRounds >= 20) {
                io.writeln('queued message(s) dropped');
                break;
              }
              drainedRounds++;
              for (final msg in queued) {
                await _handleLine(msg);
                await _settled;
                if (_abortRequested) break;
              }
            }
          } finally {
            _abortRequested = false;
            controller.sendBusy(false);
          }
          // `/exit` marks the session exited during handling. Quit in a later
          // event-loop batch: dart_tui drains the whole queue before rendering
          // and skips the render when a quit lands in the same batch, which
          // would swallow the farewell output just pushed above.
          if (_exited) {
            unawaited(
              Future<void>.delayed(
                const Duration(milliseconds: 100),
                controller.sendQuit,
              ),
            );
          }
        },
        onModelSelected: _tuiSelectModel,
        buildSlashMenu: _buildSlashMenu,
        buildModelMenu: _buildModelMenu,
        statusLine: _statusLine,
        prompt: prompt,
        onInterrupt: () {
          // Marks the drain loop to discard queued messages (kimi-cli drops
          // the queue on cancel instead of starting new turns).
          _abortRequested = true;
          if (isBusy) _agent.abort();
        },
        isShiftPressed: config.isShiftPressed,
        opensPicker: (key) => const {
          '/sessions',
          '/mode',
          '/approval',
          '/provider',
        }.contains(key),
        onPickerSelected: _tuiPickerSelected,
        onPickerCancelled: _tuiPickerCancelled,
        onSteer: (messages) async {
          for (final message in messages) {
            _agent.steer(UserMessage.text(message));
          }
        },
      ),
      isExited: () => _exited,
    );
    _tuiController = controller;
    final tuiIo = io;
    if (tuiIo is _TuiCliIO) tuiIo._tui = controller;

    // The banner is part of the TUI output history so it stays visible above
    // the input line inside the alternate screen.
    await _printBanner();

    final resumedLabel = await _resumedSessionLabel();
    if (resumedLabel != null) {
      _replayRestoredHistory(_agent.state.messages, resumedLabel);
    }

    // Warm the model cache in the background so the first /models picker is
    // fast; failures are silent and the cache falls back to the hardcoded list.
    unawaited(_refreshModelCache());

    await controller.run();
    if (tuiIo is _TuiCliIO) tuiIo._tui = null;
    _tuiController = null;
  }

  List<MenuItem> _buildSlashMenu(String prefix) {
    final lower = prefix.toLowerCase();
    final items = <MenuItem>[];
    for (final entry in _slashCommands.entries) {
      if (entry.key.toLowerCase().contains(lower) ||
          entry.value.toLowerCase().contains(lower)) {
        items.add(
          MenuItem(key: entry.key, label: entry.key, description: entry.value),
        );
      }
    }
    for (final entry in _pluginSlashCommands.entries) {
      if (entry.key.toLowerCase().contains(lower)) {
        items.add(MenuItem(key: entry.key, label: entry.key));
      }
    }
    for (final t in _templates) {
      final name = '/${t.name}';
      if (name.toLowerCase().contains(lower)) {
        items.add(
          MenuItem(key: name, label: name, description: t.argumentHint ?? ''),
        );
      }
    }
    return items;
  }

  List<MenuItem> _buildModelMenu(String filter) {
    // If we have no cached models yet, kick off a background fetch and show a
    // loading placeholder. The picker will refresh automatically when the list
    // arrives.
    if (_modelCache.isEmpty && _modelCacheFuture == null) {
      unawaited(_refreshModelCache());
    }
    final models = _modelCandidates(filter);
    if (models.isEmpty) {
      return const [MenuItem(key: '', label: 'loading models...')];
    }
    return [
      for (var i = 0; i < models.length; i++)
        MenuItem(key: models[i], label: '${i + 1}) ${models[i]}'),
    ];
  }

  Future<void> _tuiSelectModel(String modelId) async {
    await _handleModelCommand(modelId);
  }

  /// Routes a generic TUI picker selection (sessions/mode/approval) to the
  /// same handlers the typed slash command would use.
  Future<void> _tuiPickerSelected(String pickerId, String key) async {
    // Wizard pickers (a guided flow's multiple-choice questions) complete
    // their pending answer instead of the command handlers.
    final wizard = _wizardPickerAnswer;
    if (wizard != null && pickerId.startsWith('wizard:')) {
      if (!wizard.isCompleted) wizard.complete(key);
      _wizardPickerAnswer = null;
      return;
    }
    switch (pickerId) {
      case 'sessions':
        final index = int.tryParse(key);
        final list = _lastSessionList;
        if (index != null &&
            list != null &&
            index >= 0 &&
            index < list.length) {
          final metadata = list[index];
          final session = await _repo.open(metadata);
          final label = await session.getSessionName() ?? metadata.id;
          await _switchToMetadata(metadata, label);
        }
      case 'mode':
        await _switchMode(key);
      case 'approval':
        _handleApprovalMode(key);
      case 'provider':
        if (key == 'custom') {
          _startProviderFlow();
        } else if (key.startsWith('saved:')) {
          final entry = config.customProviders?.find(
            key.substring('saved:'.length),
          );
          if (entry != null) await _switchToSavedProvider(entry);
        } else {
          await _handleProviderCommand(key);
        }
    }
  }

  /// A generic picker dismissed with Esc: wizard pickers resolve their
  /// pending answer as cancelled (the flow then aborts cleanly).
  void _tuiPickerCancelled(String pickerId) {
    final wizard = _wizardPickerAnswer;
    if (wizard != null && pickerId.startsWith('wizard:')) {
      if (!wizard.isCompleted) wizard.complete(null);
      _wizardPickerAnswer = null;
    }
  }

  /// The sessions shown by the most recent `/sessions` picker, so a picker
  /// selection resolves to metadata without a second round trip.
  List<SessionMetadata>? _lastSessionList;

  Future<void> _openSessionsPicker() async {
    final sessions = await _repo.list(cwd: config.env.cwd);
    if (sessions.isEmpty) {
      io.writeln('no sessions for ${config.env.cwd}');
      return;
    }
    _lastSessionList = sessions;
    final current = await _session?.getMetadata();
    final items = <MenuItem>[];
    for (var i = 0; i < sessions.length; i++) {
      final metadata = sessions[i];
      final session = await _repo.open(metadata);
      final name = await session.getSessionName();
      final label = name ?? metadata.id;
      final marker = current?.path == metadata.path ? ' (current)' : '';
      items.add(
        MenuItem(
          key: '$i',
          label: '${i + 1}) $label',
          description:
              '${metadata.createdAt.toLocal().toIso8601String()}$marker',
        ),
      );
    }
    _tuiController?.openPicker('sessions', 'Sessions', items);
  }

  void _openModePicker() {
    final items = [
      for (final name in _modes.keys.toList()..sort())
        MenuItem(
          key: name,
          label: name,
          description: name == _currentMode.name ? '(current)' : '',
        ),
    ];
    _tuiController?.openPicker('mode', 'Select mode', items);
  }

  void _openApprovalPicker() {
    const descriptions = {
      'always-ask': 'prompt before every write/exec tool call',
      'write': 'auto-approve writes, prompt for exec',
      'yolo': 'auto-approve everything',
    };
    final items = [
      for (final mode in ApprovalMode.values)
        MenuItem(
          key: mode.label,
          label: mode.label,
          description:
              '${descriptions[mode.label] ?? ''}'
              '${mode == _approval.mode ? ' (current)' : ''}',
        ),
    ];
    _tuiController?.openPicker('approval', 'Approval mode', items);
  }

  /// Fetches the model list from an OpenAI-compatible `/models` endpoint and
  /// refreshes the TUI picker if it is currently open. Failures are swallowed
  /// so the UI keeps working with the hardcoded fallback list.
  Future<void> _refreshModelCache() async {
    if (_modelCacheFuture != null) return _modelCacheFuture!;
    final completer = Completer<void>();
    _modelCacheFuture = completer.future;
    try {
      final model = _agent.state.model;
      if (model.api == 'openai-completions') {
        final fetch = config.modelsFetcher ?? _fetchOpenAiCompatibleModels;
        final ids = await fetch(model.baseUrl, apiKey: _apiKey);
        if (ids.isNotEmpty) {
          _modelCache = ids;
          _tuiController?.sendModelsRefresh();
        }
      }
    } finally {
      _modelCacheFuture = null;
      completer.complete();
    }
  }

  Future<List<String>> _fetchOpenAiCompatibleModels(
    String baseUrl, {
    required String apiKey,
  }) async {
    final normalized = baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$normalized/models');
    final headers = <String, String>{'Accept': 'application/json'};
    if (apiKey.isNotEmpty) headers['Authorization'] = 'Bearer $apiKey';
    try {
      final response = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return const [];
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final data = body['data'] as List<dynamic>? ?? const <dynamic>[];
      final ids = data
          .whereType<Map<String, dynamic>>()
          .map((m) => m['id'] as String?)
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toList();
      ids.sort();
      return ids;
    } on Object {
      return const [];
    }
  }

  Future<Session> _initializeSession() async {
    final name = config.sessionName?.trim();
    if (name != null && name.isNotEmpty) {
      final metadata = await _findSessionByName(name);
      if (metadata != null) {
        return _loadSession(metadata);
      }
      return _createSession(name: name);
    }
    return _createSession();
  }

  Future<Session> _createSession({String? name}) async {
    final session = await _repo.create(
      JsonlSessionCreateOptions(
        cwd: config.env.cwd,
        metadata: {'agent': 'fah', 'model': _agent.state.model.id},
      ),
    );
    if (name != null && name.isNotEmpty) {
      await session.appendSessionName(name);
    }
    return session;
  }

  Future<SessionMetadata?> _findSessionByName(String name) async {
    final sessions = await _repo.list(cwd: config.env.cwd);
    for (final metadata in sessions) {
      final session = await _repo.open(metadata);
      final sessionName = await session.getSessionName();
      if (sessionName != null && sessionName.trim() == name.trim()) {
        return metadata;
      }
    }
    return null;
  }

  Future<Session> _loadSession(SessionMetadata metadata) async {
    final session = await _repo.open(metadata);
    final messages = await session.buildContextMessages();
    _agent.state.messages = messages;
    _persistedCount = messages.length;
    return session;
  }

  /// The label for a startup-resumed session's replay header, or null when
  /// this run started a fresh session (no messages to replay).
  Future<String?> _resumedSessionLabel() async {
    if (_agent.state.messages.isEmpty) return null;
    final session = _session;
    if (session == null) return null;
    return await session.getSessionName() ?? (await session.getMetadata()).id;
  }

  Future<void> _switchSession(String name) async {
    final trimmed = name.trim();
    final metadata = await _findSessionByName(trimmed);
    if (metadata != null) {
      await _switchToMetadata(metadata, trimmed);
      return;
    }
    _agent.reset();
    _checkpoints.clear();
    _ttsr?.reset();
    _session = await _createSession(name: trimmed);
    _persistedCount = 0;
    io.writeln("created session '$trimmed'");
  }

  /// Switches to an existing session by metadata (picker, /resume).
  Future<void> _switchToMetadata(SessionMetadata metadata, String label) async {
    _agent.reset();
    _checkpoints.clear();
    _ttsr?.reset();
    _session = await _loadSession(metadata);
    io.writeln("switched to session '$label'");
    _replayRestoredHistory(_agent.state.messages, label);
  }

  /// Replays a restored session's transcript into the output so a resume
  /// doesn't look empty: the last few messages (user/assistant/tool calls,
  /// each capped to a couple of rows) with a header counting the rest.
  void _replayRestoredHistory(List<Message> messages, String label) {
    if (messages.isEmpty) return;
    const maxShown = 10;
    const maxRows = 2;
    final skipped = messages.length > maxShown ? messages.length - maxShown : 0;
    final shown = messages.sublist(skipped);
    final count = skipped > 0
        ? 'last $maxShown of ${messages.length}'
        : '${messages.length}';
    io.writeln(_style.dim('─── restored session: $label ($count messages)'));
    for (final message in shown) {
      for (final line in _replayLines(message, maxRows)) {
        io.writeln(line);
      }
    }
    io.writeln(_style.dim('─' * 20));
  }

  /// One compact replay entry (≤ [maxRows] rows), or none for messages the
  /// replay skips (tool results — their calls are already shown).
  List<String> _replayLines(Message message, int maxRows) {
    final String text;
    final String prefix;
    switch (message) {
      case UserMessage(:final content):
        prefix = 'you: ';
        text = content is String
            ? content
            : (content as List<ContentBlock>)
                  .whereType<TextContent>()
                  .map((b) => b.text)
                  .join(' ');
      case AssistantMessage(:final content):
        final texts = content
            .whereType<TextContent>()
            .map((b) => b.text)
            .join(' ')
            .trim();
        final calls = content
            .whereType<ToolCall>()
            .map((c) => '[${c.name}]')
            .join(' ');
        text = [texts, calls].where((s) => s.isNotEmpty).join(' ');
        prefix = 'fa:  ';
      default:
        return const [];
    }
    if (text.trim().isEmpty) return const [];
    final rows = text.split('\n');
    final head = rows.take(maxRows).toList();
    final suffix = rows.length > maxRows ? ' …' : '';
    final indent = ' ' * prefix.length;
    return [
      for (var i = 0; i < head.length; i++)
        '${i == 0 ? prefix : indent}${head[i]}${i == head.length - 1 ? suffix : ''}',
    ];
  }

  /// `/resume`: switches to the most recently created session for the
  /// current directory (the repo lists sessions newest-first).
  Future<void> _resumeLastSession() async {
    final sessions = await _repo.list(cwd: config.env.cwd);
    if (sessions.isEmpty) {
      io.writeln('no sessions for ${config.env.cwd}');
      return;
    }
    final latest = sessions.first;
    final current = await _session?.getMetadata();
    final session = await _repo.open(latest);
    final label = await session.getSessionName() ?? latest.id;
    if (current?.path == latest.path) {
      io.writeln("already on the latest session '$label'");
      return;
    }
    await _switchToMetadata(latest, label);
  }

  Future<void> _renameSession(String name) async {
    final trimmed = name.trim();
    final session = _session;
    if (session == null) {
      io.writeln('no active session');
      return;
    }
    await session.appendSessionName(trimmed);
    io.writeln("renamed current session to '$trimmed'");
  }

  Future<void> _listSessions() async {
    final sessions = await _repo.list(cwd: config.env.cwd);
    if (sessions.isEmpty) {
      io.writeln('no sessions for ${config.env.cwd}');
      return;
    }
    final current = await _session?.getMetadata();
    io.writeln('sessions for ${config.env.cwd}:');
    for (var i = 0; i < sessions.length; i++) {
      final metadata = sessions[i];
      final session = await _repo.open(metadata);
      final sessionName = await session.getSessionName();
      final label = sessionName ?? metadata.id;
      final marker = current?.path == metadata.path ? '*' : ' ';
      io.writeln(
        '  $marker${i + 1}) $label  '
        '${_style.dim(metadata.createdAt.toLocal().toIso8601String())}',
      );
    }
    io.writeln(
      _style.dim('switch: /session <name> · rename: /rename-session <name>'),
    );
  }

  Future<void> _createNamedSession(String name) async {
    final trimmed = name.trim();
    final existing = await _findSessionByName(trimmed);
    if (existing != null) {
      io.writeln("session '$trimmed' already exists");
      return;
    }
    _agent.reset();
    _checkpoints.clear();
    _ttsr?.reset();
    _session = await _createSession(name: trimmed);
    _persistedCount = 0;
    io.writeln("created session '$trimmed'");
  }

  /// Runs a single non-interactive prompt (headless mode: `fah "<prompt>"`)
  /// and returns the process exit code: 0 on success, 1 when the run ends
  /// with a provider error, 130 when aborted (Ctrl-C via
  /// [CliIO.interrupts]). Tool errors the agent recovers from still exit 0 —
  /// the exit code reflects the run's terminal state, like claude/pi.
  ///
  /// Unlike [run] there is no banner, no input prompt, no slash-command
  /// handling, and no steering; the session persists exactly like a REPL
  /// turn (including auto-compaction). The host's [CliIO] should be
  /// non-interactive (approval/ask prompts are then denied per the
  /// non-interactive rule) and route [CliIO.writeln] diagnostics to stderr
  /// so [CliIO.write] (the assistant text) is the only stdout content.
  Future<int> runHeadless(String prompt) async {
    _session = await _initializeSession();
    final interruptSub = io.interrupts.listen((_) {
      if (isBusy) _agent.abort();
    });
    final taskSub = _taskConfig.jobManager.completions.listen(
      _onTaskJobCompleted,
    );
    try {
      await _agent.prompt(prompt);
      // Awaits any in-flight TTSR retry chain, persists the messages, and
      // auto-compacts — the same end-of-turn sequence as a REPL run.
      await _afterRun();
      // Background jobs (kimi's print-mode): don't exit while agents are in
      // flight. Settled jobs inject async-result messages through the
      // listener (re-wake runs), so loop until every job is terminal and
      // those reaction runs settle too (capped like kimi's drain limit).
      for (var round = 0; round < 10; round++) {
        final hasActive = _taskConfig.jobManager.jobs.any(
          (job) =>
              job.status == TaskJobStatus.queued ||
              job.status == TaskJobStatus.running,
        );
        if (!hasActive) break;
        await _taskConfig.jobManager.settled;
        await _settled;
        await _afterRun();
      }
    } catch (error) {
      io.writeln(_errorLine('$error'));
      return 1;
    } finally {
      await interruptSub.cancel();
      await taskSub.cancel();
    }
    // The exit code reads the final assistant message AFTER _afterRun: a
    // TTSR abort/retry chain replaces the aborted intermediate message with
    // the retry's outcome.
    return switch (_agent.state.messages.lastOrNull) {
      AssistantMessage(stopReason: StopReason.error) => 1,
      AssistantMessage(stopReason: StopReason.aborted) => 130,
      _ => 0,
    };
  }

  Future<void> _printBanner() async {
    final model = _agent.state.model;
    final metadata = await _session!.getMetadata();
    io.writeln(
      '${_style.bold(_style.teal('>_'))}${_style.bold('Fa')} '
      '${_style.dim('v$_version')}',
    );
    io.writeln(
      _style.dim('escape interrupt · ctrl+c clear/exit · / commands · ! bash'),
    );
    io.writeln(_style.dim('Press /help to show full commands and resources.'));
    io.writeln('');
    io.writeln(_style.bold('[Context]'));
    io.writeln('  ${config.env.cwd}');
    io.writeln('');
    io.writeln(_style.bold('[Model]'));
    io.writeln('  ${model.id} (${model.api})');
    io.writeln('  endpoint: ${model.baseUrl}');
    final keyStatus = _keyStatusLine(model);
    if (keyStatus != null) {
      io.writeln(
        keyStatus.startsWith('key: no key set')
            ? '  ${_style.yellow(keyStatus)}'
            : '  $keyStatus',
      );
    }
    io.writeln('');
    io.writeln(_style.bold('[Session]'));
    final sessionName = await _session?.getSessionName();
    if (sessionName != null && sessionName.isNotEmpty) {
      io.writeln('  $sessionName');
    }
    io.writeln('  ${metadata.path}');
  }

  /// The banner's key-status line: the name of the env var supplying the
  /// provider key (never the value), or a "no key set" warning when the
  /// provider expects a key the host does not have. Null when the provider
  /// declares no key env vars (custom/test providers) — no warning then —
  /// and null for a custom endpoint (base URL other than the catalog
  /// default), which may legitimately run keyless (local llama.cpp/Ollama/
  /// LM Studio servers).
  ///
  /// Legacy mode reads the names by provider KIND, matching the executable's
  /// key lookup: `openai-completions` accepts OPENROUTER_API_KEY/
  /// OPENAI_API_KEY even on custom endpoints, where the model's provider
  /// flips to `openai`. Roles mode keys per resolved chain entry, so the
  /// live model's provider names are the right ones there. An explicit
  /// `/provider` token has no env var to name and reads as "provided" — the
  /// value is never printed.
  String? _keyStatusLine(Model model) {
    final spec = catalogProvider(_rolesDriven ? model.provider : _providerKind);
    final names = spec?.apiKeyEnvNames;
    if (names == null || names.isEmpty) return null;
    final set = names
        .where((name) => config.envVarIsSet?.call(name) ?? false)
        .firstOrNull;
    if (set != null) return 'key: $set';
    if (!_rolesDriven && _explicitToken) return 'key: provided';
    if (spec != null && model.baseUrl != spec.defaultBaseUrl) return null;
    return 'key: no key set (want ${names.first})';
  }

  /// The `error:` diagnostic line for a failed run. Provider JSON blobs
  /// (OpenRouter wraps upstream errors in nested JSON) are compacted to the
  /// most specific message. A connection-level failure ("Connection
  /// refused" — a SocketException, or a package:http ClientException
  /// wrapping one; the provider adapters reduce both to their message
  /// string, so detection is textual) appends the endpoint hint: the
  /// effective base URL from the config or `--base-url` is almost always
  /// the thing to fix then.
  String _errorLine(String message) {
    final compact = compactProviderError(message);
    if (!compact.toLowerCase().contains('connection refused')) {
      return 'error: $compact';
    }
    return 'error: $compact — check the endpoint in ~/.fah/config.yaml '
        '(baseUrl: ${_agent.state.model.baseUrl}) or pass --base-url';
  }

  Future<void> _handleLine(String line) async {
    final trimmed = line.trim();
    // An ask question waiting for input owns the next line — including
    // empty ones (empty input switches the menu to free-text entry).
    final pendingAsk = _pendingAskAnswer;
    if (pendingAsk != null && !pendingAsk.isCompleted) {
      pendingAsk.complete(trimmed);
      return;
    }
    // A guided flow (custom provider setup) owns input while active: lines
    // complete its pending prompt — including empty ones (the key step's
    // "none" affordance) — or buffer for the next prompt, because piped
    // input outruns the flow's async gaps (a buffered answer must never
    // leak into a run).
    if (_providerFlowActive) {
      final pendingPrompt = _pendingPromptAnswer;
      if (pendingPrompt != null && !pendingPrompt.isCompleted) {
        pendingPrompt.complete(trimmed);
      } else {
        _promptLineBuffer.add(trimmed);
      }
      return;
    }
    if (trimmed.isEmpty) return;
    // A tool call waiting on an approval decision owns the next input line;
    // it must not be steered into the agent as a user message.
    final pendingApproval = _pendingApprovalAnswer;
    if (pendingApproval != null && !pendingApproval.isCompleted) {
      pendingApproval.complete(trimmed);
      return;
    }
    if (isBusy) {
      // While a run streams, typed input steers the agent (pi semantics).
      _agent.steer(UserMessage.text(line));
      return;
    }
    await _settled;
    if (trimmed.startsWith('!')) {
      await _runShellCommand(trimmed.substring(1));
    } else if (trimmed.startsWith('/skill:')) {
      await _runSkillCommand(trimmed.substring('/skill:'.length));
    } else if (trimmed.startsWith('/')) {
      await _handleCommand(trimmed);
    } else {
      _startRun(line);
    }
  }

  /// `/skill:<name> [args]` — explicit skill invocation (kimi's slash
  /// runner): the skill body is injected as the user message, with the args
  /// appended as the actual request.
  Future<void> _runSkillCommand(String rest) async {
    final splitAt = rest.indexOf(RegExp(r'\s'));
    final name = (splitAt < 0 ? rest : rest.substring(0, splitAt)).trim();
    final args = splitAt < 0 ? '' : rest.substring(splitAt).trim();
    final skill = _skills
        .where((s) => s.name.toLowerCase() == name.toLowerCase())
        .firstOrNull;
    if (skill == null) {
      io.writeln(
        'unknown skill: $name'
        '${_skills.isEmpty ? ' (no skills discovered)' : ''}',
      );
      return;
    }
    final body = await _readSkillBody(skill);
    if (body == null) {
      io.writeln('cannot read skill file: ${skill.filePath}');
      return;
    }
    io.writeln('skill ${skill.name} — ${skill.filePath}');
    final message = args.isEmpty ? body : '$body\n\nUser request:\n$args';
    if (isBusy) {
      _agent.steer(UserMessage.text(message));
    } else {
      _startRun(message);
    }
  }

  /// Reads a skill file and strips its YAML frontmatter.
  Future<String?> _readSkillBody(Skill skill) async {
    final text = (await config.env.readTextFile(skill.filePath)).valueOrNull;
    if (text == null) return null;
    if (!text.startsWith('---')) return text.trim();
    final end = text.indexOf('\n---', 3);
    if (end < 0) return text.trim();
    return text.substring(end + 4).trim();
  }

  /// `/skills` — lists the discovered skills (name, description, location).
  void _listSkills() {
    if (_skills.isEmpty) {
      io.writeln('no skills discovered (roots: .fah/skills, .agents/skills)');
      return;
    }
    io.writeln('skills:');
    for (final skill in _skills) {
      io.writeln(
        '  ${skill.name} — ${skill.description}  '
        '${_style.dim('${skill.filePath} (${skill.scope.name})')}',
      );
    }
  }

  void _startRun(String text) {
    final settled = _agent.prompt(text).then((_) => _afterRun()).catchError((
      Object error,
    ) {
      io.writeln(_errorLine('$error'));
    });
    _settled = settled;
    unawaited(
      settled.then((_) {
        if (!_exited) _writeIdlePrompt();
      }),
    );
  }

  Future<void> _afterRun() async {
    // A TTSR abort/inject/retry chain may still be in flight when the
    // aborted run settles; persist only once the whole chain completed.
    await _ttsr?.settled;
    await _persistMessages();
    await _maybeAutoCompact();
  }

  Future<void> _persistMessages() async {
    final session = _session;
    if (session == null) return;
    final messages = _agent.state.messages;
    for (final message in messages.skip(_persistedCount)) {
      await session.appendMessage(message);
    }
    _persistedCount = messages.length;
  }

  /// Persists one in-memory [message] at the session leaf on demand (the
  /// checkpoint/rewind controller's sink), keeping [_persistedCount] aligned
  /// so the run-end batch persistence skips it. Returns the new record id.
  Future<String> _persistOneMessage(Message message) async {
    final session = _session;
    if (session == null) return '';
    final id = await session.appendMessage(message);
    _persistedCount++;
    return id;
  }

  /// Persists a TTSR injection at the session leaf (the TTSR controller's
  /// sink): the reminder as a hidden `ttsr-injection` custom message (it
  /// projects into context as a user message and survives compaction) plus a
  /// `ttsr_injection` record of the rule names for session restore. Bumps
  /// [_persistedCount] by one — the in-memory injection message then counts
  /// as persisted.
  Future<void> _persistTtsrInjection(
    String content,
    List<String> ruleNames,
  ) async {
    final session = _session;
    if (session == null) return;
    await session.appendCustomMessageEntry(
      customType: ttsrInjectionCustomType,
      content: content,
      display: false,
      details: {'rules': ruleNames},
    );
    await session.appendCustomEntry(
      customType: ttsrInjectionRecordType,
      data: {'rules': ruleNames},
    );
    _persistedCount++;
  }

  Future<void> _maybeAutoCompact() async {
    final messages = _agent.state.messages;
    if (messages.isEmpty) return;
    final tokens = estimateContextTokens(messages).tokens;
    if (!shouldCompact(
      tokens,
      _agent.state.model.contextWindow,
      defaultCompactionSettings,
    )) {
      return;
    }
    await _compact('[auto-compacted]');
  }

  Future<void> _compact(String label) async {
    final session = _session;
    if (session == null) return;
    try {
      // Cheap summaries: when model roles are configured, compaction
      // resolves through the `smol` role (falling back to the default chain
      // when smol is unset, per role inheritance). The prompts come from the
      // config `prompts:` overrides when present.
      final smol = config.modelRolesResolver?.resolveRole(smolModelRole);
      final compactionPrompts = CompactionPrompts.fromOverrides(
        config.promptOverrides,
      );
      final manager = CompactionManager(
        summarize: streamFunctionSummarizer(
          smol?.stream ?? _streamFunction,
          smol?.model ?? _agent.state.model,
          prompts: compactionPrompts,
        ),
        prompts: compactionPrompts,
      );
      final record = await manager.compactSession(session);
      if (record == null) {
        io.writeln('nothing to compact');
        return;
      }
      // Replace the in-memory transcript with the session's projected
      // context (summary in place of the compacted region).
      _agent.state.messages = await session.buildContextMessages();
      _persistedCount = _agent.state.messages.length;
      io.writeln('$label ${record.tokensBefore} tokens summarized');
    } catch (error) {
      io.writeln('compaction failed: $error');
    }
  }

  Future<void> _handleCommand(String trimmed) async {
    final command = trimmed.split(RegExp(r'\s+')).first;
    final rest = trimmed.substring(command.length).trim();
    switch (command) {
      case '/exit':
        io.writeln('bye');
        _exited = true;
      case '/help':
        _printHelp(filter: rest);
      case '/stats':
        _printStats();
      case '/tasks':
        _listTaskJobs(rest);
      case '/skills':
        _listSkills();
      case '/model':
        await _handleModelCommand(rest);
      case '/models':
        await _listModels(rest);
      case '/provider':
        if (rest.isEmpty && _useTui && _tuiController != null) {
          _openProviderPicker();
        } else {
          await _handleProviderCommand(rest);
        }
      case '/provider-edit':
        _startProviderEditFlow();
      case '/key':
        await _handleKeyCommand(rest);
      case '/reset':
        _agent.reset();
        _checkpoints.clear();
        _ttsr?.reset();
        _session = await _createSession();
        _persistedCount = 0;
        io.writeln('new session started');
      case '/compact':
        await _compact('[compacted]');
      case '/sessions':
        // In the TUI a bare /sessions opens the picker (same as /models);
        // with an argument or in line mode it prints the list.
        if (rest.isEmpty && _useTui && _tuiController != null) {
          await _openSessionsPicker();
        } else {
          await _listSessions();
        }
      case '/session':
        await _handleSessionCommand(rest);
      case '/session-new':
        if (rest.trim().isEmpty) {
          io.writeln('usage: /session-new <name>');
        } else {
          await _createNamedSession(rest.trim());
        }
      case '/rename-session':
        if (rest.trim().isEmpty) {
          io.writeln('usage: /rename-session <name>');
        } else {
          await _renameSession(rest.trim());
        }
      case '/resume':
        await _resumeLastSession();
      case '/mode':
        if (rest.isEmpty && _useTui && _tuiController != null) {
          _openModePicker();
        } else {
          await _handleMode(rest);
        }
      case '/approval':
        if (rest.isEmpty && _useTui && _tuiController != null) {
          _openApprovalPicker();
        } else {
          _handleApprovalMode(rest);
        }
      case '/allow':
        _handleAllow(rest);
      case '/code' || '/architect' || '/review':
        await _switchMode(command.substring(1));
      default:
        final pluginHandler = _pluginSlashCommands[command];
        if (pluginHandler != null) {
          await pluginHandler(rest.split(RegExp(r'\s+')));
          return;
        }
        final expanded = expandPromptTemplate(trimmed, _templates);
        if (expanded != trimmed) {
          _startRun(expanded);
          return;
        }
        // Unknown slash command: treat it as a filter for the command menu.
        if (trimmed.startsWith('/') && trimmed.length > 1) {
          _printSlashMenu(trimmed);
          return;
        }
        io.writeln('unknown command: $command (try /help)');
    }
  }

  Future<void> _handleMode(String rest) async {
    if (rest.isEmpty) {
      io.writeln('mode: ${_currentMode.name}');
      io.writeln('modes: ${(_modes.keys.toList()..sort()).join(', ')}');
      return;
    }
    await _switchMode(rest);
  }

  Future<void> _handleSessionCommand(String rest) async {
    final trimmed = rest.trim();
    if (trimmed.isEmpty) {
      final session = _session;
      if (session == null) {
        io.writeln('no active session');
        return;
      }
      final metadata = await session.getMetadata();
      final name = await session.getSessionName();
      io.writeln('session: ${name ?? '(unnamed)'}  ${metadata.path}');
      io.writeln(_style.dim('rename: /rename-session <name>'));
      return;
    }
    await _switchSession(trimmed);
  }

  /// Renders the terminal approval prompt (y/n/a) and waits for the answer,
  /// which [_handleLine] routes into [_pendingApprovalAnswer]. A Ctrl-C
  /// interrupt while waiting answers "no" so the run can unwind.
  Future<ApprovalDecision> _promptForApproval(ApprovalRequest request) async {
    // Tool calls prepare sequentially (even in parallel batches), so at most
    // one prompt is pending; complete a stray one defensively.
    _pendingApprovalAnswer?.complete('n');
    final pending = Completer<String>();
    _pendingApprovalAnswer = pending;
    io.writeln('[approval] ${request.reason}');
    io.writeln(
      '[approval] tool: ${request.toolName} (${request.tier.name} tier) — '
      '${_formatArgs(request.arguments)}',
    );
    io.writeln(
      '[approval] allow? [y]es once / [n]o / [a]lways for '
      '"${request.toolName}"',
    );
    final interruptSub = io.interrupts.listen((_) {
      if (!pending.isCompleted) pending.complete('n');
    });
    final answer = await pending.future;
    await interruptSub.cancel();
    if (identical(_pendingApprovalAnswer, pending)) {
      _pendingApprovalAnswer = null;
    }
    final decision = switch (answer.toLowerCase()) {
      'y' || 'yes' => ApprovalDecision.approveOnce,
      'a' || 'always' => ApprovalDecision.approveAlways,
      _ => ApprovalDecision.deny,
    };
    if (decision == ApprovalDecision.approveAlways) {
      config.onApprovalChanged?.call();
    }
    return decision;
  }

  /// Reads one input line for the ask menu. Resolves to `null` on cancel
  /// (Ctrl-C interrupt or input shutdown), which the menu maps to "ask
  /// cancelled by user".
  Future<String?> _nextAskLine() async {
    // Ask forces its tool batch to sequential execution, so at most one
    // prompt is pending; complete a stray one defensively as cancelled.
    final stray = _pendingAskAnswer;
    if (stray != null && !stray.isCompleted) stray.complete(null);
    final pending = Completer<String?>();
    _pendingAskAnswer = pending;
    final interruptSub = io.interrupts.listen((_) {
      if (!pending.isCompleted) pending.complete(null);
    });
    final line = await pending.future;
    await interruptSub.cancel();
    if (identical(_pendingAskAnswer, pending)) {
      _pendingAskAnswer = null;
    }
    return line;
  }

  /// Whether a guided custom-provider setup is between prompts (guards
  /// against a second `/provider custom` while one is running). While true,
  /// input lines buffer here instead of steering or starting runs.
  var _providerFlowActive = false;

  /// Answers that arrived while no flow prompt was pending (piped input
  /// outruns the flow); consumed by the next `_promptLine` call.
  final _promptLineBuffer = <String>[];

  /// The registry entry name of the active custom provider, if one is
  /// (drives the per-provider model memory and the picker's `(current)`).
  String? _activeCustomName;

  /// The pending wizard-menu answer, if a guided flow's multiple-choice
  /// question is on screen (TUI). Completed by `_tuiPickerSelected` (or
  /// `_tuiPickerCancelled` on Esc).
  Completer<String?>? _wizardPickerAnswer;

  /// The stdin ask surface: walks [questions] one at a time and returns one
  /// answer per question, or `null` when the user cancels.
  Future<List<AskAnswer>?> _answerAskQuestions(
    List<AskQuestion> questions,
  ) async {
    final answers = <AskAnswer>[];
    for (var i = 0; i < questions.length; i++) {
      final answer = await _askOneQuestion(questions[i], i, questions.length);
      if (answer == null) return null;
      answers.add(answer);
    }
    return answers;
  }

  /// Renders one question as a numbered menu (+ "(Recommended)" marker) and
  /// reads the answer: a number selects an option, `m` opens the
  /// multi-select toggle (multiSelect questions only), empty input switches
  /// to free-text entry, any other non-number text is taken as the free-text
  /// answer directly, and `!` cancels the whole ask.
  Future<AskAnswer?> _askOneQuestion(
    AskQuestion question,
    int index,
    int total,
  ) async {
    final progress = total > 1 ? ' (${index + 1}/$total)' : '';
    io.writeln('[ask] ${question.question}$progress');
    for (var i = 0; i < question.options.length; i++) {
      final option = question.options[i];
      final description = option.description?.trim();
      final suffix = question.recommended == i ? ' (Recommended)' : '';
      io.writeln(
        '[ask]   ${i + 1}) ${option.label}'
        '${description == null || description.isEmpty ? '' : ' — $description'}'
        '$suffix',
      );
    }
    if (question.options.isEmpty) {
      io.writeln('[ask] type your answer (empty = cancel):');
      final text = await _nextAskLine();
      if (text == null || text.isEmpty) return null;
      return AskAnswer.text(text);
    }
    final multiHint = question.multiSelect ? ', m = multi-select' : '';
    io.writeln(
      '[ask] 1-${question.options.length} = select$multiHint, '
      'empty = your own answer, ! = cancel',
    );
    while (true) {
      final line = await _nextAskLine();
      if (line == null || line == '!') return null;
      if (line.isEmpty) return _readFreeTextAnswer();
      if (question.multiSelect && line.toLowerCase() == 'm') {
        return _askMultiSelect(question);
      }
      final number = int.tryParse(line);
      if (number == null) return AskAnswer.text(line);
      if (number >= 1 && number <= question.options.length) {
        return AskAnswer.selection([question.options[number - 1].label]);
      }
      io.writeln('[ask] no option $number — try again');
    }
  }

  /// The multi-select toggle loop: numbers toggle options, `d` (or empty
  /// input) confirms — falling back to free-text entry when nothing is
  /// selected — and `!` cancels.
  Future<AskAnswer?> _askMultiSelect(AskQuestion question) async {
    final selected = <int>{};
    while (true) {
      final picked = selected.isEmpty
          ? '-'
          : (selected.toList()..sort()).map((i) => '${i + 1}').join(', ');
      io.writeln(
        '[ask] multi-select: numbers toggle, d = done, ! = cancel '
        '(selected: $picked)',
      );
      final line = await _nextAskLine();
      if (line == null || line == '!') return null;
      if (line.isEmpty || line.toLowerCase() == 'd') {
        if (selected.isNotEmpty) {
          return AskAnswer.selection([
            for (final i in selected.toList()..sort())
              question.options[i].label,
          ]);
        }
        return _readFreeTextAnswer();
      }
      var invalid = false;
      for (final part in line.split(RegExp(r'[\s,]+'))) {
        final number = int.tryParse(part);
        if (number == null || number < 1 || number > question.options.length) {
          invalid = true;
          break;
        }
        if (!selected.remove(number - 1)) selected.add(number - 1);
      }
      if (invalid) {
        io.writeln('[ask] invalid selection "$line" — try again');
      }
    }
  }

  /// Free-text entry for the ask menu; an empty line cancels the whole ask.
  Future<AskAnswer?> _readFreeTextAnswer() async {
    io.writeln('[ask] type your answer (empty = cancel):');
    final text = await _nextAskLine();
    if (text == null || text.isEmpty) return null;
    return AskAnswer.text(text);
  }

  void _handleApprovalMode(String rest) {
    if (rest.isEmpty) {
      io.writeln('approval mode: ${_approval.mode.label}');
      io.writeln('approval modes: always-ask, write, yolo');
      final allowed = _approval.alwaysAllowedTools;
      io.writeln(
        'always-allowed tools: ${allowed.isEmpty ? '(none)' : allowed.join(', ')}',
      );
      return;
    }
    final mode = approvalModeFromLabel(rest);
    if (mode == null) {
      io.writeln('unknown approval mode: $rest (want always-ask|write|yolo)');
      return;
    }
    _approval.mode = mode;
    io.writeln('approval mode set to ${mode.label}');
    config.onApprovalChanged?.call();
  }

  void _handleAllow(String rest) {
    if (rest.isEmpty) {
      final allowed = _approval.alwaysAllowedTools;
      io.writeln(
        'always-allowed tools: ${allowed.isEmpty ? '(none)' : allowed.join(', ')}',
      );
      return;
    }
    final name = rest.split(RegExp(r'\s+')).first;
    final known = _agent.state.tools.any((tool) => tool.name == name);
    if (!known) {
      io.writeln('unknown tool: $name');
      return;
    }
    _approval.allowAlways(name);
    io.writeln('"$name" always allowed (persisted)');
    config.onApprovalChanged?.call();
  }

  Future<void> _switchMode(String name) async {
    final mode = _modes[name];
    if (mode == null) {
      io.writeln('unknown mode: $name');
      return;
    }
    _currentMode = mode;
    _applyPromptComposition();
    io.writeln('switched mode to ${mode.name}');
    config.onModeChanged?.call(mode.name);
  }

  /// Lists the known models for the active provider, optionally filtered by
  /// [filter]. The output is numbered so `/model N` can pick one. For
  /// OpenAI-compatible endpoints the list is fetched live from `/v1/models`
  /// and cached.
  Future<void> _listModels(String filter) async {
    if (_modelCache.isEmpty && _modelCacheFuture == null) {
      await _refreshModelCache();
    }
    final candidates = _modelCandidates(filter);
    if (candidates.isEmpty) {
      io.writeln('no known models for provider ${_agent.state.model.provider}');
      return;
    }
    io.writeln('models for ${_agent.state.model.provider}:');
    for (var i = 0; i < candidates.length; i++) {
      io.writeln('  ${i + 1}) ${candidates[i]}');
    }
    _lastModelList = candidates;
    io.writeln('use /model <n> or /model <id> to switch');
  }

  /// Returns the full list of known model ids for the active provider.
  List<String> _listModelsForMenu() => _modelCandidates('');

  /// Returns known model ids for the active provider, filtered by an optional
  /// lowercase substring. Prefers the live cache fetched from the provider's
  /// `/models` endpoint; falls back to the hardcoded subset when the cache is
  /// empty or the fetch has not completed yet.
  List<String> _modelCandidates([String filter = '']) {
    final provider = _agent.state.model.provider;
    final all = _modelCache.isNotEmpty
        ? _modelCache
        : (_knownModels[provider] ?? const <String>[]);
    if (filter.isEmpty) return all.toList();
    final lower = filter.toLowerCase();
    return all.where((id) => id.toLowerCase().contains(lower)).toList();
  }

  Future<void> _handleModelCommand(String rest) async {
    final trimmed = rest.trim();
    if (trimmed == '?') {
      await _listModels('');
      return;
    }
    if (trimmed.isEmpty) {
      // Bare `/model` in TUI mode opens the interactive picker; in line mode
      // it prints the active model and the roles overview.
      final controller = _tuiController;
      if (controller != null) {
        controller.openModelMenu();
        return;
      }
      await _switchModel('');
      return;
    }
    final number = int.tryParse(trimmed);
    final lastList = _lastModelList ?? _listModelsForMenu();
    if (number != null) {
      if (number < 1 || number > lastList.length) {
        io.writeln('invalid selection: $number (1-${lastList.length})');
        return;
      }
      await _switchModel(lastList[number - 1]);
      return;
    }
    await _switchModel(trimmed);
  }

  Future<void> _switchModel(String modelId) async {
    final current = _agent.state.model;
    final rolesResolver = config.modelRolesResolver;
    if (modelId.isEmpty) {
      io.writeln('model: ${current.id} (${current.api})');
      if (rolesResolver != null) io.writeln(rolesResolver.describeRoles());
      return;
    }
    if (rolesResolver != null) {
      // Roles mode: pin the default role to the requested model id on the
      // current provider (a single-entry chain for this session).
      rolesResolver.setDefaultChain([
        ModelRef(
          provider: current.provider,
          modelId: modelId,
          baseUrl: current.baseUrl,
          contextWindow: current.contextWindow,
          maxTokens: current.maxTokens,
        ),
      ]);
      rolesResolver.applyToAgent(_agent);
      _streamFunction = _agent.streamFunction;
      await _session?.appendModelChange(
        provider: current.provider,
        modelId: modelId,
      );
      io.writeln('switched model to $modelId');
      _recordCustomModel(modelId);
      config.onModelChanged?.call(_agent.state.model);
      return;
    }
    _agent.state.model = Model(
      id: modelId,
      name: modelId,
      api: current.api,
      provider: current.provider,
      baseUrl: current.baseUrl,
      reasoning: current.reasoning,
      input: current.input,
      cost: current.cost,
      contextWindow: current.contextWindow,
      maxTokens: current.maxTokens,
      headers: current.headers,
      compat: current.compat,
    );
    await _session?.appendModelChange(
      provider: current.provider,
      modelId: modelId,
    );
    io.writeln('switched model to $modelId');
    _recordCustomModel(modelId);
    config.onModelChanged?.call(_agent.state.model);
  }

  /// Renders the model-roles no-silent-degrade note: every retry, key
  /// rotation, and chain failover is announced inline, and the display
  /// model tracks the active chain entry.
  void _onRolesNotice(FallbackNotice notice) {
    io.writeln('[roles] ${notice.describe()}');
    final resolved = config.modelRolesResolver?.resolveRole(defaultModelRole);
    if (resolved != null) _agent.state.model = resolved.model;
  }

  /// Runs a raw shell command prefixed with `!` through [config.env] and
  /// prints its stdout/stderr/exit code directly.
  Future<void> _runShellCommand(String command) async {
    final result = await config.env.exec(command);
    switch (result) {
      case Ok(:final value):
        if (value.stdout.isNotEmpty) {
          io.write(value.stdout);
          if (!value.stdout.endsWith('\n')) io.write('\n');
        }
        if (value.stderr.isNotEmpty) io.writeln(value.stderr);
        if (value.exitCode != 0) {
          io.writeln('exit code: ${value.exitCode}');
        }
      case Err(:final error):
        io.writeln('shell error: ${error.message}');
    }
  }

  /// A compact status bar shown above every idle prompt: cwd, model, tokens,
  /// cost, and turn count.
  String _statusLine() {
    final model = _agent.state.model;
    final total = _usage.total;
    final cost = total.cost.total.toStringAsFixed(4);
    final cwd = config.env.cwd;
    // Current context pressure: the last assistant message's prompt size
    // against the model's context window (pi's `context: N% (used/max)`).
    final lastAssistant = _agent.state.messages
        .whereType<AssistantMessage>()
        .lastOrNull;
    final contextTokens = lastAssistant?.usage.input ?? 0;
    final window = model.contextWindow;
    final pct = window > 0 ? (contextTokens / window * 100).round() : 0;
    // kimi's toolbar badge: active background agents, when any.
    final activeJobs = _taskConfig.jobManager.jobs
        .where(
          (job) =>
              job.status == TaskJobStatus.queued ||
              job.status == TaskJobStatus.running,
        )
        .length;
    final badge = activeJobs > 0 ? ' · bg:$activeJobs' : '';
    return '$cwd · ctx $pct% '
        '(${_formatTokenCount(contextTokens)}/${_formatTokenCount(window)}) · '
        '${total.totalTokens}tok · \$$cost · turn ${_usage.turns}$badge · '
        '${model.id}';
  }

  /// Compact token counts like pi's `275k` / `1M`.
  static String _formatTokenCount(int value) {
    if (value >= 1000000) {
      final m = value / 1000000;
      return '${m.toStringAsFixed(m >= 10 ? 0 : 1)}M';
    }
    if (value >= 1000) {
      final k = value / 1000;
      return '${k.toStringAsFixed(k >= 100 ? 0 : 1)}k';
    }
    return '$value';
  }

  /// Prints a divider, the status bar, and the input prompt. Used whenever the
  /// REPL becomes idle after a command or a run. In TUI mode the prompt is
  /// already part of the rendered frame, so this is a no-op there.
  void _writeIdlePrompt() {
    if (_useTui) return;
    if (!_exited) {
      io.writeln(_style.dim('─' * 60));
      io.writeln(_style.dim(_statusLine()));
      io.write(_style.bold(_style.cyan(prompt)));
    }
  }

  static const _slashCommands = <String, String>{
    '/exit': 'quit',
    '/reset': 'start a new session',
    '/compact': 'summarize history to free context',
    '/stats': 'show token and cost totals',
    '/tasks': '[cancel <id>] — list background agents',
    '/skills': 'list discovered skills (invoke with /skill:<name>)',
    '/model': '<provider/model> — select model (opens selector)',
    '/models': '[filter] — list known models for the current provider',
    '/provider': '[name] [baseUrl] [token] | custom — switch provider/endpoint',
    '/provider-edit': 'edit the active provider via the guided setup',
    '/mode': '[name] — show or switch the active mode',
    '/session': '[name] — show current or switch/create a named session',
    '/session-new': '<name> — create a new named session',
    '/sessions': 'list named sessions for the current directory',
    '/resume': 'switch to the most recent session',
    '/rename-session': '<name> — rename the current session',
    '/approval': '[mode] — show or set tool approval',
    '/allow': '[tool] — always-allow a tool (or list them)',
    '/code': 'switch to coding mode',
    '/architect': 'switch to architect mode',
    '/review': 'switch to review mode',
    '/help': 'this help',
    '!': '<command> — run a shell command directly',
  };

  /// Prompt-based slash menu for terminals that cannot enter raw/ANSI mode.
  /// Shows a numbered list of commands and reads the user's choice from the
  /// same [lineIterator] that drives the REPL loop.
  Future<String?> _showLineModeMenu(StreamIterator<String> lineIterator) async {
    final commands = _slashCommands.entries.toList();
    io.writeln('');
    io.writeln(_style.bold('[Commands]'));
    for (var i = 0; i < commands.length; i++) {
      final entry = commands[i];
      io.writeln('  ${i + 1}) ${_style.cyan(entry.key)} ${entry.value}');
    }
    io.writeln('');
    io.write('Pick a command (number or name), or press Enter to cancel: ');
    if (!await lineIterator.moveNext()) return null;
    final trimmed = lineIterator.current.trim();
    if (trimmed.isEmpty) return null;
    // Numeric choice.
    final index = int.tryParse(trimmed);
    if (index != null && index >= 1 && index <= commands.length) {
      return commands[index - 1].key;
    }
    // Name choice; accept with or without leading slash.
    final name = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    if (_slashCommands.containsKey(name)) return name;
    io.writeln('unknown choice: $trimmed');
    return null;
  }

  void _printHelp({String filter = ''}) {
    final lower = filter.toLowerCase();
    final entries = _slashCommands.entries
        .where(
          (e) =>
              e.key.toLowerCase().contains(lower) ||
              e.value.toLowerCase().contains(lower),
        )
        .toList();
    if (entries.isEmpty) {
      if (filter.isNotEmpty) {
        io.writeln('unknown command: /$filter (try /help)');
      } else {
        io.writeln('no commands match "$filter"');
      }
      return;
    }
    if (filter.isEmpty) {
      io.writeln(_style.bold('[Commands]'));
    } else {
      io.writeln(_style.bold('[Commands matching "$filter"]'));
    }
    for (final entry in entries) {
      final name = entry.key.padRight(18);
      io.writeln('  ${_style.cyan(name)} ${entry.value}');
    }
    if (_pluginSlashCommands.isNotEmpty && filter.isEmpty) {
      io.writeln('');
      io.writeln(_style.bold('[Plugin commands]'));
      for (final entry in _pluginSlashCommands.entries) {
        io.writeln('  ${_style.cyan(entry.key)}');
      }
    }
    if (_templates.isNotEmpty && filter.isEmpty) {
      io.writeln('');
      io.writeln(_style.bold('[Prompt templates]'));
      for (final t in _templates) {
        final hint = t.argumentHint ?? '';
        io.writeln('  ${_style.cyan('/${t.name}')} $hint');
      }
    }
    if (filter.isEmpty) {
      io.writeln('');
      io.writeln(
        _style.dim(
          'While a run streams, type to steer the agent; Ctrl-C aborts.',
        ),
      );
    }
  }

  void _printSlashMenu(String prefix) {
    final filter = prefix.substring(1);
    _printHelp(filter: filter);
  }

  void _printStats() {
    final total = _usage.total;
    io.writeln('turns: ${_usage.turns}');
    io.writeln('input tokens: ${total.input}');
    io.writeln('output tokens: ${total.output}');
    io.writeln('cache read tokens: ${total.cacheRead}');
    io.writeln('cache write tokens: ${total.cacheWrite}');
    io.writeln('total tokens: ${total.totalTokens}');
    io.writeln('cost: \$${total.cost.total.toStringAsFixed(4)}');
  }

  /// Called when a background `task` job settles (omp's async-result flow):
  /// renders a transcript notification and injects the result back into the
  /// parent conversation — steered mid-run, or as a fresh re-wake run while
  /// idle (omp's idle flush via `agent.prompt`).
  void _onTaskJobCompleted(TaskJob job) {
    final result = job.result;
    final seconds = result == null
        ? ''
        : ' in ${(result.duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
    io.writeln(
      _style.dim(
        '[task] ${job.id} (${job.agent}) ${job.status.name}$seconds — '
        'agent://${job.id}',
      ),
    );
    if (_exited) return;
    final message = _buildAsyncResultMessage(job);
    if (isBusy) {
      // Mid-run: the steering queue delivers it at the next step boundary
      // (omp's non-interrupting aside between requests).
      _agent.steer(UserMessage.text(message));
    } else {
      _startRun(message);
    }
  }

  /// The async-result message re-injected into the parent conversation when
  /// a background job settles (omp's `<system-notice>` + `<task-result>`
  /// envelope, reduced: no artifact spill — the pointer is `agent://<id>`).
  static const _asyncResultPreviewChars = 4000;

  String _buildAsyncResultMessage(TaskJob job) {
    final result = job.result;
    final buffer = StringBuffer()
      ..writeln('<system-notice>')
      ..writeln(
        'Background agent ${job.id} (${job.agent}) finished with status: '
        '${job.status.name}.',
      )
      ..writeln('Task: ${job.task}')
      ..writeln()
      ..write(
        '<task-result id="${job.id}" agent="${job.agent}" '
        'status="${job.status.name}">',
      );
    final output = result?.output ?? '';
    if (output.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(
          output.length > _asyncResultPreviewChars
              ? '${output.substring(0, _asyncResultPreviewChars)}\n…\n'
                    '[Full output: agent://${job.id}]'
              : output,
        );
    }
    final error = result?.error;
    if (error != null) buffer.write('\nerror: $error');
    buffer
      ..write('\n</task-result>')
      ..write('\n</system-notice>');
    return buffer.toString();
  }

  /// `/tasks [cancel <id>]` — lists the session's background agents with
  /// their states (kimi's TaskList surface; cancelling a running job aborts
  /// its child run, which then settles as aborted).
  void _listTaskJobs(String rest) {
    final parts = rest
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    final verb = parts.isEmpty ? '' : parts.first;
    if (verb == 'cancel') {
      if (parts.length < 2) {
        io.writeln('usage: /tasks cancel <id>');
        return;
      }
      final job = _taskConfig.jobManager.job(parts[1]);
      if (job == null) {
        io.writeln('unknown task job: ${parts[1]}');
        return;
      }
      job.cancel();
      io.writeln('cancelled ${job.id}');
      return;
    }
    final jobs = _taskConfig.jobManager.jobs;
    if (jobs.isEmpty) {
      io.writeln('no background agents this session');
      return;
    }
    io.writeln('background agents:');
    for (final job in jobs) {
      final marker = switch (job.status) {
        TaskJobStatus.queued => '○',
        TaskJobStatus.running => '⠿',
        TaskJobStatus.completed => '✓',
        TaskJobStatus.failed || TaskJobStatus.aborted => '✗',
      };
      final duration = job.result?.duration;
      final elapsed = duration == null
          ? ''
          : ' ${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
      var task = job.task.replaceAll('\n', ' ');
      if (task.length > 60) task = '${task.substring(0, 60)}…';
      io.writeln(
        '  $marker ${job.id} (${job.agent}) ${job.status.name}$elapsed — '
        '$task  ${_style.dim('agent://${job.id}')}',
      );
    }
  }

  void _onAgentEvent(AgentEvent event, CancelToken cancelToken) {
    switch (event) {
      case MessageStartEvent(:final message):
        if (message is AssistantMessage) _assistantPrefixPrinted = false;
      case MessageUpdateEvent(:final assistantMessageEvent):
        if (assistantMessageEvent is TextDeltaEvent) {
          // The answer text starts on its own line after the dimmed
          // thinking block.
          if (_streamedThinking && !_streamedText) io.write('\n');
          _writeAssistantPrefix();
          io.write(assistantMessageEvent.delta);
          _streamedText = true;
        } else if (assistantMessageEvent is ThinkingDeltaEvent && _useTui) {
          // Reasoning models stream long thinking before any text; showing
          // it dimmed under the user message is the TUI's progress signal.
          io.write(_style.dim(assistantMessageEvent.delta));
          _streamedThinking = true;
        }
      case MessageEndEvent(:final message):
        if (message is AssistantMessage) {
          if (_streamedText || _streamedThinking) {
            // The trailing newline of the streamed text belongs to the
            // primary channel (write), not to diagnostics (writeln) — a
            // headless host routes only writeln to stderr.
            io.write('\n');
            _streamedText = false;
            _streamedThinking = false;
          }
          switch (message.stopReason) {
            case StopReason.error:
              io.writeln(_errorLine(message.errorMessage ?? 'unknown error'));
            case StopReason.aborted:
              // A TTSR abort is a rule trigger, not a failure — the
              // controller already announced it (omp renders a
              // notification instead of the aborted stop reason).
              if (!(_ttsr?.isAbortPending ?? false)) {
                io.writeln('aborted: ${message.errorMessage ?? 'aborted'}');
              }
            default:
              // A tolerated silent truncation (no finish_reason) is flagged
              // on the message — tell the user the reply may be cut off.
              if (message.errorMessage != null) {
                io.writeln(_style.dim('(${message.errorMessage})'));
                break;
              }
              // A turn that ends with neither text nor tool calls leaves the
              // user staring at silence (seen with OpenRouter free models
              // that burn the whole completion on reasoning). Say so.
              final hasText = message.content.any(
                (c) => c is TextContent && c.text.trim().isNotEmpty,
              );
              final hasToolCalls = message.content.any((c) => c is ToolCall);
              if (!hasText && !hasToolCalls) {
                io.writeln(
                  _style.dim(
                    '(empty response: the model returned no text — '
                    'it may be rate-limited or reasoning-only)',
                  ),
                );
              }
          }
        }
      case ToolExecutionStartEvent(:final toolName, :final args):
        io.writeln(
          '${_style.bold(_style.indigo('[$toolName]'))} '
          '${_style.dim(_formatArgs(args))}',
        );
      case ToolExecutionEndEvent(
        :final toolName,
        :final result,
        :final isError,
      ):
        final tool = _style.bold(_style.indigo('[$toolName]'));
        if (isError) {
          final text = result.content
              .whereType<TextContent>()
              .map((block) => block.text)
              .join();
          var snippet = text.split('\n').first;
          if (snippet.length > 120) {
            snippet = '${snippet.substring(0, 120)}...';
          }
          io.writeln('$tool ${_style.red('error')}: $snippet');
        } else {
          io.writeln('$tool ${_style.teal('done')}');
        }
      case TurnEndEvent(:final message):
        _usage.add(message.usage);
      default:
    }
  }

  /// Prints the `>_Fa ` prefix once per assistant message, before the first
  /// text delta. TUI-only: headless and line-mode output stay plain (a piped
  /// headless response must remain the bare assistant text).
  void _writeAssistantPrefix() {
    if (!_useTui || _assistantPrefixPrinted) return;
    io.write('${_style.bold(_style.teal('>_'))}${_style.bold('Fa')} ');
    _assistantPrefixPrinted = true;
  }

  String _formatArgs(Map<String, dynamic> args) {
    var formatted = args.entries
        .map((entry) => '${entry.key}=${_safeJsonEncode(entry.value)}')
        .join(', ');
    if (formatted.length > 100) {
      formatted = '${formatted.substring(0, 100)}...';
    }
    return formatted;
  }

  String _safeJsonEncode(Object? value) {
    try {
      return jsonEncode(value);
    } catch (_) {
      return '[unserializable]';
    }
  }
}
