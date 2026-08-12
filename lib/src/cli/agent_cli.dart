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
import 'package:yaml/yaml.dart';

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
import '../env/session_vars_execution_env.dart';
import '../exceptions.dart';
import '../lsp/lsp_tool.dart';
import '../mcp/mcp_config.dart';
import '../mcp/mcp_manager.dart';
import '../model.dart';
import '../model_roles/model_roles.dart';
import '../model_roles/vision_models.dart';
import '../providers/chatgpt_oauth.dart';
import '../providers/codemie_sso.dart';
import '../providers/models_endpoint.dart';
import '../providers/openrouter_oauth.dart';
import '../prompts/prompt_overrides.dart';
import 'chatgpt_oauth_server.dart';
import 'codemie_sso_server.dart';
import 'openrouter_oauth_server.dart';
import '../secrets/secure_key_store.dart';
import '../session/session_repo.dart';
import 'custom_providers.dart';
import 'provider_flow.dart';
import '../session/session_storage.dart';
import '../session/session_tree.dart';
import '../tools/ask_tool.dart';
import '../tools/request_secret_tool.dart';
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
import 'ask_menu.dart';
import 'slash_menu.dart';
import 'task_list.dart';
import 'text_format.dart';
import 'tui_helpers.dart';
import 'tui_prompt.dart';
import 'tui_replay.dart';
import 'tui_repl.dart';

export '../model_roles/provider_catalog.dart' show providerStreamFunction;

part 'provider_commands.dart';
part 'agent_cli_mcp.dart';
part 'agent_cli_config.dart';
part 'settings_flow.dart';

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

/// The default system prompt for the CLI agent.
String defaultAgentCliSystemPrompt(String cwd) =>
    defaultAgentMode(cwd).systemPrompt;

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
        _catalogStreamFunction(config.providerKind, config.apiKey);
    // MCP servers connect lazily in the background; their tools land in
    // the registry via _onMcpChanged (registered after the agent exists).
    _mcp = AgentCliMcpWiring(config: config.mcpConfig, cwd: config.env.cwd);
    final coreTools = <AgentTool>[
      ...builtinTools(
        // Session-correlation env vars (FAH_SESSION_ID/FILE/PROVIDER/MODEL)
        // for the bash tool; resolved live, so `/provider` switches and
        // session (re)creation are picked up per exec.
        SessionVarsExecutionEnv(config.env, _sessionEnvVars),
        webSearch: config.webSearchConfig,
        model: () => _agent.state.model,
        sqlite: config.sqliteEngine,
        lsp: config.lspConfig,
        mcp: _mcp.manager,
      ),
      // Non-interactive input (piped) gets a null ask callback: ask calls
      // then fail with a "host cannot answer" error result (safe default).
      askTool(callback: io.isInteractive ? _answerAskQuestions : null),
      // request_secret: let the agent ask for missing API keys securely.
      // In interactive mode the user types the value (echoed as dots in the
      // future; for now plain text like the ask flow). Non-interactive hosts
      // get null → the tool errors with guidance to set the key manually.
      requestSecretTool(
        callback: io.isInteractive ? _answerSecretRequest : null,
      ),
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
      rolesResolver.sessionId = () => _session?.cachedId;
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
    // MCP: late tool (re)registration and prompt updates flow through the
    // manager's change callback; servers connect in the background.
    final mcpManager = _mcp.manager;
    if (mcpManager != null) {
      mcpManager.onChanged = _onMcpChanged;
      mcpManager.start();
    }
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

  /// Session-correlation env vars injected into bash tool executions (see
  /// [SessionVarsExecutionEnv]). Read live per exec: the session is created
  /// after tool wiring, and `/provider`/`/model` switches must show up in
  /// later commands. Never secret values — ids, paths, kinds, model ids.
  Future<Map<String, String>> _sessionEnvVars() async {
    final session = _session;
    final metadata = session == null ? null : await session.getMetadata();
    return {
      if (metadata != null) sessionIdEnvVar: metadata.id,
      if (metadata != null) sessionFileEnvVar: metadata.path,
      providerEnvVar: _providerKind,
      modelEnvVar: _agent.state.model.id,
      ..._runtimeSecrets,
    };
  }

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

  /// The MCP wiring (manager + re-registration) — see agent_cli_mcp.dart.
  late AgentCliMcpWiring _mcp;

  /// Re-registers the MCP tool surface and rebuilds the prompt whenever a
  /// server connects, fails, or drops.
  void _onMcpChanged() {
    _mcp.reRegister(_toolRegistry, _agent, _applyPromptComposition);
  }

  /// Rebuilds the agent's system prompt from the active mode (or the
  /// explicit override) plus the project-context and skills sections
  /// (pi/kimi-style: appended after the base prompt).
  void _applyPromptComposition() {
    _agent.state.systemPrompt = _mcp.composePrompt(
      config.systemPrompt ?? _currentMode.systemPrompt,
      contextSection: formatProjectContext(_contextFiles),
      skillsSection: formatSkillsForPrompt(_skills),
    );
  }

  /// Reference to the active TUI controller so asynchronous model-list updates
  /// can refresh the picker while it is open.
  FaTuiController? _tuiController;

  /// Model ids shown by the most recent `/model` picker, so `/model N` can
  /// select by number without retyping the full id.
  List<String>? _lastModelList;

  /// Cache of model ids fetched from an OpenAI-compatible `/models` endpoint,
  /// plus the in-flight refresh future so concurrent callers coalesce.
  List<String> _modelCache = const [];
  Future<void>? _modelCacheFuture;

  /// Context windows reported by the endpoint's `/models` payload (see
  /// [parseModelsResponse] in provider_commands.dart); empty when the
  /// fetcher is replaced (tests) or the endpoint reports none. Drives
  /// automatic window correction so the catalog default (200k) stops lying
  /// for custom endpoints.
  Map<String, int> _modelContextWindows = const {};

  /// Max-output-token caps reported by the endpoint's `/models` payload
  /// (same source as [_modelContextWindows]); drives automatic `maxTokens`
  /// correction so the conservative catalog floor stops truncating answers.
  Map<String, int> _modelMaxTokens = const {};

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
    await _loadAgentContext();
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
        await _runLineRepl();
      }
    } finally {
      // Input ended (EOF) or the REPL is shutting down: never leave a tool
      // call waiting on an answer that cannot arrive.
      _cancelPendingAnswers();
      await interruptSub.cancel();
      await taskSub.cancel();
      await _settled;
    }
    await printSessionResumeHint();
  }

  /// Loads prompt templates, skills, and project context files, then applies
  /// the prompt composition.
  Future<void> _loadAgentContext() async {
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
  }

  /// Answers any pending approval/ask prompt defensively so a tool call
  /// never waits on an answer that cannot arrive.
  void _cancelPendingAnswers() {
    _pendingApprovalAnswer?.complete('n');
    _pendingApprovalAnswer = null;
    _pendingAskAnswer?.complete(null);
    _pendingAskAnswer = null;
  }

  /// The line-mode REPL: banner, restored-session replay, then the
  /// read-dispatch loop.
  Future<void> _runLineRepl() async {
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

  /// After an interactive run ends, prints the command that picks this
  /// session back up (kimi prints the resume hint on exit too). Skipped for
  /// sessions with nothing persisted yet — resuming those is pointless.
  /// Also called from the top-level idle-SIGINT path in `bin/fah.dart`,
  /// which exits 130 without returning from [run].
  Future<void> printSessionResumeHint() async {
    final session = _session;
    if (session == null || _persistedCount == 0) return;
    final name = await session.getSessionName();
    final id = name ?? (await session.getMetadata()).id;
    io.writeln(_style.dim("resume this session with: fa --session '$id'"));
  }

  Future<void> _runTuiRepl() async {
    final controller = _createTuiController();
    _tuiController = controller;
    _setTuiIo(controller);

    // The banner is part of the TUI output history so it stays visible above
    // the input line inside the alternate screen.
    await _printBanner();
    await _replayRestoredSession();

    // Warm the model cache in the background so the first /models picker is
    // fast; failures are silent and the cache falls back to the hardcoded list.
    unawaited(_refreshModelCache());

    await controller.run();
    _setTuiIo(null);
    _tuiController = null;
  }

  /// Routes [io]'s output through the TUI controller while it runs (null
  /// detaches after the run).
  void _setTuiIo(FaTuiController? controller) {
    final tuiIo = io;
    if (tuiIo is _TuiCliIO) tuiIo._tui = controller;
  }

  /// Wires the TUI controller's callbacks to the line handler, pickers, and
  /// interrupt/steer paths.
  FaTuiController _createTuiController() {
    late final FaTuiController controller;
    controller = FaTuiController(
      callbacks: FaTuiCallbacks(
        onSubmit: (line) => _handleTuiSubmit(controller, line),
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
          '/settings',
        }.contains(key),
        onPickerSelected: _tuiPickerSelected,
        onPickerCancelled: _tuiPickerCancelled,
        onSteer: _steerTuiMessages,
      ),
      isExited: () => _exited,
      programHooks: config.tuiProgramHooks,
    );
    return controller;
  }

  /// Steers every queued TUI message into the running agent.
  Future<void> _steerTuiMessages(List<String> messages) async {
    for (final message in messages) {
      _agent.steer(UserMessage.text(message));
    }
  }

  /// Replays the transcript when the TUI opens on a restored session.
  Future<void> _replayRestoredSession() async {
    final resumedLabel = await _resumedSessionLabel();
    if (resumedLabel != null) {
      _replayRestoredHistory(_agent.state.messages, resumedLabel);
    }
  }

  /// A TUI submit: runs the line, waits for the run to settle, drains the
  /// queued messages, and schedules the quit when `/exit` marked the
  /// session exited.
  Future<void> _handleTuiSubmit(FaTuiController controller, String line) async {
    controller.sendBusy(true);
    try {
      await _handleLine(line);
      // Runs are fire-and-forget (_startRun only records the future):
      // wait for the run to actually settle so the busy spinner lives
      // for the whole stream instead of flashing for one frame.
      await _settled;
      await _drainTuiQueue(controller);
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
  }

  /// Drains queued messages one-by-one as separate turns (kimi-cli
  /// semantics) — the loop itself is [drainQueueRounds]; an Esc abort
  /// discards the queue instead of starting new work.
  Future<void> _drainTuiQueue(FaTuiController controller) => drainQueueRounds(
    drain: controller.drainQueue,
    runRound: (queued) => runQueuedTurns(
      queued: queued,
      handle: _handleLine,
      settled: () => _settled,
      abortRequested: () => _abortRequested,
    ),
    abortRequested: () => _abortRequested,
    onDropped: () => io.writeln('queued message(s) dropped'),
  );

  List<MenuItem> _buildSlashMenu(String prefix) => buildSlashMenuItems(
    prefix,
    slashCommands: builtinSlashCommands,
    pluginSlashCommands: _pluginSlashCommands,
    templates: _templates,
  );

  /// Routes a generic TUI picker selection (sessions/mode/approval) to the
  /// same handlers the typed slash command would use.
  Future<void> _tuiPickerSelected(String pickerId, String key) async {
    // Wizard pickers (a guided flow's multiple-choice questions) complete
    // their pending answer instead of the command handlers.
    if (_completeWizardPicker(pickerId, key)) return;
    await _tuiPickerHandlers[pickerId]?.call(key);
  }

  /// Picker id → the handler the typed slash command would have used.
  late final Map<String, Future<void> Function(String)> _tuiPickerHandlers = {
    'sessions': _tuiPickSession,
    'mode': _switchMode,
    'approval': (key) async => _handleApprovalMode(key),
    'provider': _tuiPickProvider,
    'settings': _tuiPickSetting,
  };

  /// Completes the pending wizard-picker answer for [pickerId] (null [key]
  /// = dismissed with Esc); returns whether a wizard was waiting.
  bool _completeWizardPicker(String pickerId, String? key) {
    final wizard = _wizardPickerAnswer;
    if (wizard == null) return false;
    return _finishWizardPicker(pickerId, key, wizard);
  }

  /// Resolves a waiting wizard picker and clears the pending answer;
  /// returns whether [pickerId] is a wizard picker.
  bool _finishWizardPicker(
    String pickerId,
    String? key,
    Completer<String?> wizard,
  ) {
    if (!pickerId.startsWith('wizard:')) return false;
    _resolveWizard(wizard, key);
    return true;
  }

  /// Completes [wizard] (defensively no-op when already completed) and
  /// clears the pending answer.
  void _resolveWizard(Completer<String?> wizard, String? key) {
    if (!wizard.isCompleted) wizard.complete(key);
    _wizardPickerAnswer = null;
  }

  /// A sessions-picker selection: the key is the index into the most recent
  /// `/sessions` listing.
  Future<void> _tuiPickSession(String key) async {
    final metadata = listItemAt(_lastSessionList, int.tryParse(key) ?? -1);
    if (metadata == null) return;
    final session = await _repo.open(metadata);
    final label = await session.getSessionName() ?? metadata.id;
    await _switchToMetadata(metadata, label);
  }

  /// A provider-picker selection: `custom` starts the guided flow,
  /// `saved:<name>` switches to a saved custom provider, anything else is a
  /// catalog provider name.
  Future<void> _tuiPickProvider(String key) async {
    if (key == 'custom') {
      _startProviderFlow();
      return;
    }
    // Provider types that require interactive auth get their flow launched
    // instead of a plain catalog switch (codemie → SSO, chatgpt → OAuth).
    if (key == 'codemie') {
      await _handleCodeMieSsoCommand(defaultCodeMieBaseUrl);
      return;
    }
    if (key == 'chatgpt') {
      await _handleChatGptOAuthCommand(headless: false);
      return;
    }
    await _tuiPickCatalogOrSaved(key);
  }

  /// A non-`custom` provider-picker selection: a saved entry or a catalog
  /// provider name.
  Future<void> _tuiPickCatalogOrSaved(String key) async {
    if (key.startsWith('saved:')) {
      await _tuiPickSavedProvider(key.substring('saved:'.length));
      return;
    }
    await _handleProviderCommand(key);
  }

  /// A `saved:<name>` provider-picker selection restores the saved custom
  /// provider when it still exists.
  Future<void> _tuiPickSavedProvider(String name) async {
    final entry = config.customProviders?.find(name);
    if (entry != null) await _switchToSavedProvider(entry);
  }

  /// A generic picker dismissed with Esc: wizard pickers resolve their
  /// pending answer as cancelled (the flow then aborts cleanly).
  void _tuiPickerCancelled(String pickerId) {
    _completeWizardPicker(pickerId, null);
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
    _tuiController?.openPicker(
      'sessions',
      'Sessions',
      await _sessionPickerItems(sessions),
    );
  }

  /// Numbered picker items for [sessions], marking the active session.
  Future<List<MenuItem>> _sessionPickerItems(
    List<SessionMetadata> sessions,
  ) async {
    final current = await _session?.getMetadata();
    final items = <MenuItem>[];
    for (var i = 0; i < sessions.length; i++) {
      items.add(await _sessionPickerItem(i, sessions[i], current));
    }
    return items;
  }

  /// One numbered sessions-picker row, marked when it is the active
  /// session.
  Future<MenuItem> _sessionPickerItem(
    int i,
    SessionMetadata metadata,
    SessionMetadata? current,
  ) async {
    final session = await _repo.open(metadata);
    final name = await session.getSessionName();
    final label = name ?? metadata.id;
    final marker = current?.path == metadata.path ? ' (current)' : '';
    return MenuItem(
      key: '$i',
      label: '${i + 1}) $label',
      description: '${metadata.createdAt.toLocal().toIso8601String()}$marker',
    );
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
        metadata: {'agent': 'Fa', 'model': _agent.state.model.id},
      ),
    );
    if (name != null && name.isNotEmpty) {
      await session.appendSessionName(name);
    }
    return session;
  }

  /// Finds a session by display name OR by exact id (the exit hint prints
  /// `fa --session '<id>'` for unnamed sessions, so ids must resolve too).
  Future<SessionMetadata?> _findSessionByName(String name) async {
    final sessions = await _repo.list(cwd: config.env.cwd);
    for (final metadata in sessions) {
      if (metadata.id == name.trim()) return metadata;
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
  /// doesn't look empty: compact per-message rows filling a row budget from
  /// the END (see [buildReplayEntries] — a typical session replays in full,
  /// only marathon ones truncate, and the header says so).
  void _replayRestoredHistory(List<Message> messages, String label) {
    if (messages.isEmpty) return;
    // Below the TUI history cap (200 lines) so the replay never trims its
    // own head in TUI mode.
    final width = io.columns > 0 ? io.columns : 80;
    final (entries, firstIndex) = buildReplayEntries(
      messages,
      tui: _useTui,
      width: width,
      dim: _style.dim,
    );
    final count = firstIndex > 0
        ? 'last ${messages.length - firstIndex} of ${messages.length}'
        : '${messages.length}';
    io.writeln(_style.dim('─── restored session: $label ($count messages)'));
    for (final entry in entries) {
      for (final line in entry) {
        io.writeln(line);
      }
    }
    io.writeln(_style.dim('─' * 20));
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
    // An explicit /provider token (or a saved custom entry's key) IS the
    // active key: name its store slot. The value is never printed.
    if (!_rolesDriven && _explicitToken) return _explicitTokenKeyStatus(model);
    return _resolvedKeyStatus(model, spec, names);
  }

  /// Key status when an explicit token or saved-entry key is in play.
  String _explicitTokenKeyStatus(Model model) {
    final entryKey = _activeCustomKeyName();
    if (_hasStoredKey(entryKey)) return 'key: $entryKey';
    return _scopedTokenKeyStatus(model);
  }

  /// Whether [name] names a key present in the secure store.
  bool _hasStoredKey(String? name) =>
      name != null && config.secureKeys?.read(name) != null;

  /// Key status fallback for an explicit token: the host-scoped store slot,
  /// or the anonymous "provided" marker.
  String _scopedTokenKeyStatus(Model model) {
    final scoped = CustomProviderRegistry.keyNameFor(model.baseUrl);
    if (config.secureKeys?.read(scoped) != null) return 'key: $scoped';
    return 'key: provided';
  }

  /// Key status from the resolution order: genuine environment values first
  /// (they differ from the store's entry); then the active custom entry's
  /// slot (multi-account entries use name-scoped ones), the host-scoped
  /// slot, and legacy env-name entries (env or store — indistinguishable
  /// here).
  String? _resolvedKeyStatus(
    Model model,
    ProviderSpec? spec,
    List<String> names,
  ) {
    final keys = config.secureKeys;
    final envKey = _envKeyStatus(names);
    if (envKey != null) return envKey;
    final entryKey = _activeCustomKeyName();
    if (entryKey != null && keys?.read(entryKey) != null) {
      return 'key: $entryKey';
    }
    final scopedName = CustomProviderRegistry.keyNameFor(model.baseUrl);
    if (keys?.read(scopedName) != null) return 'key: $scopedName';
    return _fallbackKeyStatus(model, spec, names);
  }

  /// Key status fallback: any legacy env-name entry, else the "no key set"
  /// guidance (null for non-default endpoints without a key).
  String? _fallbackKeyStatus(
    Model model,
    ProviderSpec? spec,
    List<String> names,
  ) {
    final set = names
        .where((name) => config.envVarIsSet?.call(name) ?? false)
        .firstOrNull;
    if (set != null) return 'key: $set';
    if (spec != null && model.baseUrl != spec.defaultBaseUrl) return null;
    return 'key: no key set (want ${names.first})';
  }

  /// The first env-name holding a genuine environment value (differs from
  /// the store's entry), as a `key: <name>` status, or null.
  String? _envKeyStatus(List<String> names) {
    final keys = config.secureKeys;
    for (final name in names) {
      final value = config.envVarValue?.call(name);
      if (value != null && value.isNotEmpty && value != keys?.read(name)) {
        return 'key: $name';
      }
    }
    return null;
  }

  /// The active saved custom provider's secure-store key name, or null when
  /// none is active (or the entry is keyless).
  String? _activeCustomKeyName() {
    final name = _activeCustomName;
    if (name == null) return null;
    return config.customProviders?.find(name)?.keyName;
  }

  /// The `error:` diagnostic line for a failed run. Provider JSON blobs
  /// (OpenRouter wraps upstream errors in nested JSON) are compacted to the
  /// most specific message. A connection-level failure ("Connection
  /// refused" — a SocketException, or a package:http ClientException
  /// wrapping one; the provider adapters reduce both to their message
  /// string, so detection is textual) appends the endpoint hint: the
  /// effective base URL from the config or `--base-url` is almost always
  /// the thing to fix then. A 401-class auth failure appends the key
  /// diagnostic: which env var is in play, whether an environment value is
  /// shadowing a DIFFERENT stored key (env wins over the secure store — the
  /// classic stale-export footgun), or that no key resolved at all.
  String _errorLine(String message) {
    final compact = compactProviderError(message);
    if (_isAuthError(compact)) {
      return _style.red('error: $compact${_authHint()}');
    }
    if (!compact.toLowerCase().contains('connection refused')) {
      return _style.red('error: $compact');
    }
    return _style.red(
      'error: $compact — check the endpoint in ~/.fah/config.yaml '
      '(baseUrl: ${_agent.state.model.baseUrl}) or pass --base-url',
    );
  }

  /// 401-class detection across provider wordings (OpenAI/OpenRouter "401:
  /// API Key invalid", Anthropic "authentication_error", plain
  /// "Unauthorized").
  bool _isAuthError(String compact) {
    final lower = compact.toLowerCase();
    return RegExp(r'\b401\b').hasMatch(compact) ||
        lower.contains('unauthorized') ||
        lower.contains('authentication_error') ||
        (lower.contains('api key') && lower.contains('invalid'));
  }

  /// The ` — ...` suffix for [_errorLine] on auth failures. Never prints key
  /// material — names and sources only. Mirrors the provider key resolution
  /// order: genuine environment value → endpoint-scoped store entry →
  /// legacy env-name store entry.
  String _authHint() {
    if (_rolesDriven) {
      return ' — roles mode reads keys from the environment only; check '
          'the chain env vars in ~/.fah/config.yaml';
    }
    final spec = catalogProvider(_providerKind);
    final names = spec?.apiKeyEnvNames;
    final baseUrl = _agent.state.model.baseUrl;
    if (names == null || names.isEmpty) {
      return ' — check the credentials for $baseUrl';
    }
    final scopedName = CustomProviderRegistry.keyNameFor(baseUrl);
    // A genuine environment key in play: warn when it shadows a different
    // same-name store entry, else name it as the source.
    final envHint = _envActiveHint(names, baseUrl);
    if (envHint != null) return envHint;
    // Endpoint-scoped store key (what /provider and the wizard write): the
    // active custom entry's name-scoped slot first, then the host-scoped
    // one.
    final entryKey = _activeCustomKeyName();
    final scoped = entryKey ?? scopedName;
    final storedHint = _storedKeyHint(scoped, baseUrl);
    if (storedHint != null) return storedHint;
    // Legacy env-name store key (older versions wrote these).
    final legacy = names
        .where((name) => (config.envVarValue?.call(name) ?? '').isNotEmpty)
        .firstOrNull;
    if (legacy != null) return _storeHintMessage(legacy, baseUrl);
    return _noKeyHint(entryKey, baseUrl, spec, scopedName, names);
  }

  /// The hint naming a secure-store key as the source.
  String _storeHintMessage(String name, String baseUrl) {
    final label = config.secureKeys?.label ?? 'secure store';
    return ' — the key came from the $label ($name); verify it is valid '
        'for $baseUrl or replace it with /key set $name <value>';
  }

  /// The fallback hint when no key resolved (or the token was rejected).
  String _noKeyHint(
    String? entryKey,
    String baseUrl,
    ProviderSpec? spec,
    String scopedName,
    List<String> names,
  ) {
    final suggested =
        entryKey ??
        (baseUrl != spec?.defaultBaseUrl ? scopedName : names.first);
    return _explicitToken
        ? ' — the /provider token was rejected; set a fresh one with '
              '/key set $suggested <value>'
        : ' — no key set; store one with /key set $suggested <value>';
  }

  /// The hint for a genuine environment key, or null when none is in play.
  String? _envActiveHint(List<String> names, String baseUrl) {
    final envActive = _activeEnvKeyName(names);
    if (envActive == null) return null;
    return _envKeyHint(envActive, baseUrl);
  }

  /// The first env-name holding a genuine environment key (differs from the
  /// same-name store entry), or null.
  String? _activeEnvKeyName(List<String> names) {
    final keys = config.secureKeys;
    return names.where((name) {
      final value = config.envVarValue?.call(name);
      return value != null && value.isNotEmpty && value != keys?.read(name);
    }).firstOrNull;
  }

  /// The hint for a genuine environment key: the shadowing warning when a
  /// DIFFERENT same-name store entry exists, else the source note.
  String _envKeyHint(String envActive, String baseUrl) {
    final keys = config.secureKeys;
    final storedTwin = keys?.read(envActive);
    if (storedTwin != null && storedTwin.isNotEmpty) {
      final label = keys?.label ?? 'secure store';
      return ' — the environment variable $envActive shadows a DIFFERENT '
          'key in the $label; the env value is the one sent — fix or '
          'unset it, or /key delete $envActive';
    }
    return ' — the key came from the environment ($envActive); verify it '
        'is valid for $baseUrl or replace it with '
        '/key set $envActive <value>';
  }

  /// The hint for a key read from the secure store, or null when the slot is
  /// empty.
  String? _storedKeyHint(String name, String baseUrl) {
    if (config.secureKeys?.read(name) == null) return null;
    return _storeHintMessage(name, baseUrl);
  }

  Future<void> _handleLine(String line) async {
    final trimmed = line.trim();
    if (_routePendingInput(trimmed)) return;
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
    await _dispatchInput(line, trimmed);
  }

  /// Routes input owned by a pending prompt (ask question, guided provider
  /// flow, or a prompted slash command like `/key set NAME` — including
  /// empty lines, which buffer or complete the pending answer). Returns
  /// whether the line was consumed.
  bool _routePendingInput(String trimmed) {
    final pendingAsk = _pendingAskAnswer;
    if (pendingAsk != null && !pendingAsk.isCompleted) {
      pendingAsk.complete(trimmed);
      return true;
    }
    // A pending prompt answer can come from the guided provider flow OR
    // from a prompted slash command (e.g. `/key set NAME` in line mode).
    final pendingPrompt = _pendingPromptAnswer;
    if (pendingPrompt != null && !pendingPrompt.isCompleted) {
      pendingPrompt.complete(trimmed);
      return true;
    }
    // While a guided provider flow is active but between prompts, buffer
    // the lines so the flow's next _promptLine call drains them.
    if (_providerFlowActive) {
      _promptLineBuffer.add(trimmed);
      return true;
    }
    return false;
  }

  /// Settled, non-empty input: a shell command, a skill invocation, a slash
  /// command, or a prompt for the agent.
  Future<void> _dispatchInput(String line, String trimmed) async {
    if (trimmed.startsWith('!')) {
      await _runShellCommand(trimmed.substring(1));
      return;
    }
    if (trimmed.startsWith('/skill:')) {
      await _runSkillCommand(trimmed.substring('/skill:'.length));
      return;
    }
    if (trimmed.startsWith('/')) {
      await _handleCommand(trimmed);
      return;
    }
    _startRun(line);
  }

  /// `/skill:<name> [args]` — explicit skill invocation (kimi's slash
  /// runner): the skill body is injected as the user message, with the args
  /// appended as the actual request.
  Future<void> _runSkillCommand(String rest) async {
    final (name, args) = _parseSkillInvocation(rest);
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

  /// Splits `/skill:<name> [args]` into the skill name and its args.
  (String, String) _parseSkillInvocation(String rest) {
    final splitAt = rest.indexOf(RegExp(r'\s'));
    final name = (splitAt < 0 ? rest : rest.substring(0, splitAt)).trim();
    final args = splitAt < 0 ? '' : rest.substring(splitAt).trim();
    return (name, args);
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

  /// `/mcp`: prints the configured MCP servers and their live connection
  /// status, or a guidance line when none are configured.
  void _printMcpStatus() {
    final manager = _mcp.manager;
    if (manager == null || manager.config.servers.isEmpty) {
      io.writeln(
        'No MCP servers configured. Add servers to the mcp: section of '
        '~/.fah/config.yaml:\n'
        '  mcp:\n'
        '    servers:\n'
        '      example:\n'
        '        command: npx\n'
        '        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]\n'
        '      # or a remote server:\n'
        '      remote:\n'
        '        url: https://example.com/mcp',
      );
      return;
    }
    io.writeln('MCP servers:');
    final states = manager.states;
    for (final entry in manager.config.servers.entries) {
      final name = entry.key;
      final state = states[name];
      final status = switch (state?.status) {
        null => _style.dim('(connecting…)'),
        _ => switch (state!.status) {
          McpServerStatus.connected =>
            '${_style.green('connected')} — ${state.tools.length} tool(s)',
          McpServerStatus.failed =>
            '${_style.red('failed')}: ${state.error ?? 'unknown'}',
          McpServerStatus.connecting => _style.dim('(connecting…)'),
        },
      };
      final server = entry.value;
      final detail = server is McpStdioServerConfig
          ? '${server.command} ${(server.args).join(' ')}'
          : server is McpHttpServerConfig
          ? server.url
          : '';
      io.writeln('  $name — $status  ${_style.dim(detail)}');
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
    if (await _handleInfoCommand(command, rest)) return;
    if (await _handleModelProviderCommand(command, rest)) return;
    if (await _handleSessionSwitchCommand(command, rest)) return;
    if (await _handleModeCommand(command, rest)) return;
    await _handleUnknownCommand(trimmed, command, rest);
  }

  /// Info commands without a TUI picker variant. Returns whether [command]
  /// was handled.
  Future<bool> _handleInfoCommand(String command, String rest) async {
    // `/mcp` needs the async [rest == 'reload'] branch, so it is owned here
    // (the basic handler is synchronous); a plain `/mcp` still just prints
    // the status.
    if (command == '/mcp') {
      if (rest == 'reload') {
        await _reloadMcpConfig(this);
      } else {
        _printMcpStatus();
      }
      return true;
    }
    if (_handleInfoCommandBasic(command, rest)) return true;
    return _handleInfoCommandSession(command, rest);
  }

  /// `/exit`, `/help`, `/stats`, `/tasks`, `/skills`.
  bool _handleInfoCommandBasic(String command, String rest) {
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
      default:
        return false;
    }
    return true;
  }

  /// `/allow`, `/reset`, `/compact`.
  Future<bool> _handleInfoCommandSession(String command, String rest) async {
    switch (command) {
      case '/allow':
        _handleAllow(rest);
      case '/reset':
        _agent.reset();
        _checkpoints.clear();
        _ttsr?.reset();
        _session = await _createSession();
        _persistedCount = 0;
        io.writeln('new session started');
      case '/compact':
        await _compact('[compacted]');
      default:
        return false;
    }
    return true;
  }

  /// Model and provider commands. Returns whether [command] was handled.
  Future<bool> _handleModelProviderCommand(String command, String rest) async {
    switch (command) {
      case '/model':
        await _handleModelCommand(rest);
      case '/models':
        await _handleModelsCommand(rest);
      case '/model-edit':
        await _handleModelEdit(rest);
      case '/provider':
        await _providerSlash(rest);
      case '/provider-edit':
        _startProviderEditFlow();
      case '/key':
        await _handleKeyCommand(rest);
      default:
        return false;
    }
    return true;
  }

  /// `/provider`: a bare command opens the TUI picker; anything else goes to
  /// the provider command handler.
  Future<void> _providerSlash(String rest) async {
    if (rest.isEmpty && _useTui && _tuiController != null) {
      _openProviderPicker();
    } else {
      await _handleProviderCommand(rest);
    }
  }

  /// Session switching/naming commands. Returns whether [command] was
  /// handled.
  Future<bool> _handleSessionSwitchCommand(String command, String rest) async {
    switch (command) {
      case '/sessions':
        // In the TUI a bare /sessions opens the picker (same as /models);
        // with an argument or in line mode it prints the list.
        await _sessionsSlash(rest);
      case '/session':
        await _handleSessionCommand(rest);
      case '/session-new':
        await _namedSessionSlash(rest, 'session-new', _createNamedSession);
      case '/rename-session':
        await _namedSessionSlash(rest, 'rename-session', _renameSession);
      case '/resume':
        await _resumeLastSession();
      default:
        return false;
    }
    return true;
  }

  /// `/sessions`: a bare command opens the TUI picker; anything else prints
  /// the session list.
  Future<void> _sessionsSlash(String rest) async {
    if (rest.isEmpty && _useTui && _tuiController != null) {
      await _openSessionsPicker();
    } else {
      await _listSessions();
    }
  }

  /// A `/session-new`-style command requiring a name argument.
  Future<void> _namedSessionSlash(
    String rest,
    String command,
    Future<void> Function(String) action,
  ) async {
    if (rest.trim().isEmpty) {
      io.writeln('usage: /$command <name>');
    } else {
      await action(rest.trim());
    }
  }

  /// Mode and approval commands. Returns whether [command] was handled.
  Future<bool> _handleModeCommand(String command, String rest) async {
    switch (command) {
      case '/mode':
        await _modeSlash(rest);
      case '/approval':
        _approvalSlash(rest);
      case '/settings':
        await _settingsSlash(rest);
      case '/code' || '/architect' || '/review':
        await _switchMode(command.substring(1));
      default:
        return false;
    }
    return true;
  }

  /// `/mode`: a bare command opens the TUI picker; anything else goes to the
  /// mode handler.
  Future<void> _modeSlash(String rest) async {
    if (rest.isEmpty && _useTui && _tuiController != null) {
      _openModePicker();
    } else {
      await _handleMode(rest);
    }
  }

  /// `/approval`: a bare command opens the TUI picker; anything else sets
  /// the approval mode.
  void _approvalSlash(String rest) {
    if (rest.isEmpty && _useTui && _tuiController != null) {
      _openApprovalPicker();
    } else {
      _handleApprovalMode(rest);
    }
  }

  /// Anything that is not a builtin command: a plugin slash command, a
  /// prompt template, a menu filter, or simply unknown.
  Future<void> _handleUnknownCommand(
    String trimmed,
    String command,
    String rest,
  ) async {
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
      _printHelp(filter: trimmed.substring(1));
      return;
    }
    io.writeln('unknown command: $command (try /help)');
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
    // TUI mode: prompt through the on-screen approval zone (y/a/n keys).
    final tui = _tuiController;
    if (_useTui && tui != null) return _promptForApprovalTui(tui, request);
    return _promptForApprovalLine(request);
  }

  /// The TUI branch of [_promptForApproval]: the on-screen approval zone;
  /// a cancel (Esc) or an unexpected answer type denies.
  Future<ApprovalDecision> _promptForApprovalTui(
    FaTuiController tui,
    ApprovalRequest request,
  ) async {
    final result = await tui.openPrompt(ApprovalPromptSpec(request: request));
    if (result is! ApprovalPromptAnswer) return ApprovalDecision.deny;
    _noteApproveAlwaysAnswer(result.value);
    return result.value;
  }

  /// Persists the "always" preference change when [decision] is
  /// [ApprovalDecision.approveAlways] (both prompt surfaces).
  void _noteApproveAlwaysAnswer(ApprovalDecision decision) {
    if (decision == ApprovalDecision.approveAlways) {
      config.onApprovalChanged?.call();
    }
  }

  /// The line-mode branch of [_promptForApproval]: prints the prompt lines
  /// and waits for [_handleLine] to route the answer line (or an interrupt
  /// to answer "no").
  Future<ApprovalDecision> _promptForApprovalLine(
    ApprovalRequest request,
  ) async {
    // Tool calls prepare sequentially (even in parallel batches), so at most
    // one prompt is pending; complete a stray one defensively.
    _pendingApprovalAnswer?.complete('n');
    final pending = Completer<String>();
    _pendingApprovalAnswer = pending;
    _writeApprovalPromptLines(request);
    final interruptSub = io.interrupts.listen((_) {
      if (!pending.isCompleted) pending.complete('n');
    });
    final answer = await pending.future;
    await interruptSub.cancel();
    if (identical(_pendingApprovalAnswer, pending)) {
      _pendingApprovalAnswer = null;
    }
    final decision = _approvalDecisionFor(answer);
    _noteApproveAlwaysAnswer(decision);
    return decision;
  }

  /// The three `[approval]` prompt lines (reason, tool + args, choices).
  void _writeApprovalPromptLines(ApprovalRequest request) {
    io.writeln('[approval] ${request.reason}');
    io.writeln(
      '[approval] tool: ${request.toolName} (${request.tier.name} tier) — '
      '${formatArgs(request.arguments)}',
    );
    io.writeln(
      '[approval] allow? [y]es once / [n]o / [a]lways for '
      '"${request.toolName}"',
    );
  }

  /// Maps the typed approval answer to a decision; anything unrecognized
  /// denies (safe default).
  ApprovalDecision _approvalDecisionFor(String answer) =>
      switch (answer.toLowerCase()) {
        'y' || 'yes' => ApprovalDecision.approveOnce,
        'a' || 'always' => ApprovalDecision.approveAlways,
        _ => ApprovalDecision.deny,
      };

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

  /// Answers an `ask` question set by walking [questions] one at a time.
  Future<List<AskAnswer>?> _answerAskQuestions(
    List<AskQuestion> questions,
  ) async {
    // TUI mode: each question runs through the on-screen prompt zone.
    final tui = _tuiController;
    if (_useTui && tui != null) return _answerAskQuestionsTui(tui, questions);
    final answers = <AskAnswer>[];
    for (var i = 0; i < questions.length; i++) {
      final answer = await _askOneQuestion(questions[i], i, questions.length);
      if (answer == null) return null;
      answers.add(answer);
    }
    return answers;
  }

  /// The TUI branch of [_answerAskQuestions]: walks [questions] through the
  /// on-screen prompt zone; any cancel (Esc on the zone) or unexpected
  /// answer type aborts the whole batch, matching line mode.
  Future<List<AskAnswer>?> _answerAskQuestionsTui(
    FaTuiController tui,
    List<AskQuestion> questions,
  ) async {
    final answers = <AskAnswer>[];
    for (var i = 0; i < questions.length; i++) {
      final answer = await _answerOneAskQuestionTui(
        tui,
        questions[i],
        i,
        questions.length,
      );
      if (answer == null) return null;
      answers.add(answer);
    }
    return answers;
  }

  /// One TUI ask question: the prompt-zone answer, or null when cancelled
  /// (or the zone resolved with an unexpected type).
  Future<AskAnswer?> _answerOneAskQuestionTui(
    FaTuiController tui,
    AskQuestion question,
    int index,
    int total,
  ) async {
    final result = await tui.openPrompt(
      AskPromptSpec(
        header: 'Ask',
        question: question.question,
        index: index,
        total: total,
        options: question.options,
        multiSelect: question.multiSelect,
        recommended: question.recommended,
      ),
    );
    return result is AskPromptAnswer ? result.value : null;
  }

  /// Answers a `request_secret` call: prompts the user for the credential
  /// value via the same input mechanism as ask. Returns `null` on cancel
  /// (the agent sees "user declined"). The value is injected into the live
  /// shell env via the session-correlation env decorator so `$NAME` works
  /// in subsequent bash commands, and registered with the secret redactor.
  Future<RequestSecretResult?> _answerSecretRequest(
    String name,
    String reason,
  ) async {
    final tui = _tuiController;
    if (_useTui && tui != null) return _answerSecretTui(tui, name, reason);
    return _answerSecretLineMode(name, reason);
  }

  /// The TUI branch of [_answerSecretRequest].
  Future<RequestSecretResult?> _answerSecretTui(
    FaTuiController tui,
    String name,
    String reason,
  ) async {
    final result = await tui.openPrompt(
      SecretPromptSpec(name: name, reason: reason),
    );
    if (result is! SecretPromptAnswer) return null;
    _runtimeSecrets[name] = result.value.value;
    config.onSecretGranted?.call(name, result.value.value);
    return result.value;
  }

  /// The line-mode branch of [_answerSecretRequest].
  Future<RequestSecretResult?> _answerSecretLineMode(
    String name,
    String reason,
  ) async {
    io.writeln('[secret] $name needed: $reason');
    io.write('[secret] Enter value for $name (empty = decline): ');
    final line = await _nextAskLine();
    if (line == null || line.trim().isEmpty) return null;
    final value = line.trim();
    _runtimeSecrets[name] = value;
    config.onSecretGranted?.call(name, value);
    return RequestSecretResult(name: name, value: value, persisted: false);
  }

  /// Runtime secrets granted via `request_secret` — merged into the session
  /// env vars so `$NAME` works in bash tool executions.
  final Map<String, String> _runtimeSecrets = {};

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
    _printAskQuestion(question, index, total);
    if (question.options.isEmpty) return _readFreeTextAnswer();
    final multiHint = question.multiSelect ? ', m = multi-select' : '';
    io.writeln(
      '[ask] 1-${question.options.length} = select$multiHint, '
      'empty = your own answer, ! = cancel',
    );
    return _askSelectOption(question);
  }

  /// The question header and numbered option list (recommended flagged) —
  /// the lines come from [askQuestionLines].
  void _printAskQuestion(AskQuestion question, int index, int total) {
    for (final line in askQuestionLines(question, index, total)) {
      io.writeln(line);
    }
  }

  /// The single-select loop: a number picks an option, empty input falls
  /// through to free-text, `m` enters multi-select, `!` cancels.
  Future<AskAnswer?> _askSelectOption(AskQuestion question) async {
    while (true) {
      final line = await _nextAskLine();
      if (line == null || line == '!') return null;
      if (line.isEmpty) return _readFreeTextAnswer();
      if (question.multiSelect && line.toLowerCase() == 'm') {
        return _askMultiSelect(question);
      }
      final parsed = _parseOptionAnswer(question, line);
      if (parsed.answer != null) return parsed.answer;
      io.writeln('[ask] no option ${parsed.number} — try again');
    }
  }

  /// Parses one select-loop line: a valid number becomes a selection, a
  /// non-number becomes free text, and an out-of-range number comes back as
  /// ([AskAnswer?].answer = null, number) so the loop can complain and
  /// retry.
  ({AskAnswer? answer, int? number}) _parseOptionAnswer(
    AskQuestion question,
    String line,
  ) {
    final number = int.tryParse(line);
    if (number == null) return (answer: AskAnswer.text(line), number: null);
    if (number >= 1 && number <= question.options.length) {
      return (
        answer: AskAnswer.selection([question.options[number - 1].label]),
        number: number,
      );
    }
    return (answer: null, number: number);
  }

  /// The multi-select toggle loop: numbers toggle options, `d` (or empty
  /// input) confirms — falling back to free-text entry when nothing is
  /// selected — and `!` cancels.
  Future<AskAnswer?> _askMultiSelect(AskQuestion question) async {
    final selected = <int>{};
    while (true) {
      io.writeln(
        '[ask] multi-select: numbers toggle, d = done, ! = cancel '
        '(selected: ${pickedLabel(selected)})',
      );
      final line = await _nextAskLine();
      if (line == null || line == '!') return null;
      if (line.isEmpty || line.toLowerCase() == 'd') {
        return _finishMultiSelect(question, selected);
      }
      if (_toggleMultiSelectParts(question, selected, line)) {
        io.writeln('[ask] invalid selection "$line" — try again');
      }
    }
  }

  /// Done with multi-select: the toggled options as a selection, or
  /// free-text entry when nothing is selected.
  Future<AskAnswer?> _finishMultiSelect(
    AskQuestion question,
    Set<int> selected,
  ) async {
    if (selected.isNotEmpty) {
      return AskAnswer.selection([
        for (final i in selected.toList()..sort()) question.options[i].label,
      ]);
    }
    return _readFreeTextAnswer();
  }

  /// Toggles every number in [line] (space/comma separated). Returns whether
  /// any part was invalid.
  bool _toggleMultiSelectParts(
    AskQuestion question,
    Set<int> selected,
    String line,
  ) {
    for (final part in line.split(RegExp(r'[\s,]+'))) {
      final number = int.tryParse(part);
      if (number == null || number < 1 || number > question.options.length) {
        return true;
      }
      if (!selected.remove(number - 1)) selected.add(number - 1);
    }
    return false;
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
    // Error/aborted terminal messages carry Usage.zero — skip them, or the
    // gauge snaps back to 0% right after a failed run. Scanned from the END:
    // this runs on every rendered frame, so a full-history forward scan
    // (allocating lazy iterables over hundreds of messages) is wasted work.
    final lastAssistant = _agent.state.messages.reversed
        .whereType<AssistantMessage>()
        .where((m) => m.usage.input > 0)
        .firstOrNull;
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

  /// Prompt-based slash menu for terminals that cannot enter raw/ANSI mode.
  /// Shows a numbered list of commands and reads the user's choice from the
  /// same [lineIterator] that drives the REPL loop.
  Future<String?> _showLineModeMenu(StreamIterator<String> lineIterator) async {
    for (final line in lineModeMenuLines(_style)) {
      io.writeln(line);
    }
    io.write('Pick a command (number or name), or press Enter to cancel: ');
    if (!await lineIterator.moveNext()) return null;
    final trimmed = lineIterator.current.trim();
    if (trimmed.isEmpty) return null;
    final choice = _resolveMenuChoice(trimmed);
    if (choice == null) io.writeln('unknown choice: $trimmed');
    return choice;
  }

  /// Resolves a line-mode menu answer: a 1-based number, or a command name
  /// with or without the leading slash. Null when neither matches.
  String? _resolveMenuChoice(String trimmed) {
    final commands = builtinSlashCommands.entries.toList();
    // Numeric choice.
    final index = int.tryParse(trimmed);
    if (index != null && index >= 1 && index <= commands.length) {
      return commands[index - 1].key;
    }
    // Name choice; accept with or without leading slash.
    final name = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    if (builtinSlashCommands.containsKey(name)) return name;
    return null;
  }

  /// The numbered command list of the line-mode menu.
  void _printHelp({String filter = ''}) {
    for (final line in helpLines(
      filter: filter,
      pluginSlashCommands: _pluginSlashCommands,
      templates: _templates,
      style: _style,
    )) {
      io.writeln(line);
    }
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
      _cancelTaskJob(parts);
      return;
    }
    final jobs = _taskConfig.jobManager.jobs;
    if (jobs.isEmpty) {
      io.writeln('no background agents this session');
      return;
    }
    for (final line in taskJobLines(jobs, dim: _style.dim)) {
      io.writeln(line);
    }
  }

  /// `/tasks cancel <id>`: aborts the job's child run.
  void _cancelTaskJob(List<String> parts) {
    if (parts.length < 2) {
      io.writeln('usage: /tasks cancel <id>');
      return;
    }
    _cancelTaskJobById(parts[1]);
  }

  /// Cancels the job named [id], or reports it as unknown.
  void _cancelTaskJobById(String id) {
    final job = _taskConfig.jobManager.job(id);
    if (job == null) {
      io.writeln('unknown task job: $id');
      return;
    }
    job.cancel();
    io.writeln('cancelled ${job.id}');
  }

  void _onAgentEvent(AgentEvent event, CancelToken cancelToken) {
    switch (event) {
      case MessageStartEvent(:final message) || MessageEndEvent(:final message):
        _onMessageLifecycle(message, start: event is MessageStartEvent);
      case MessageUpdateEvent(:final assistantMessageEvent):
        _onMessageUpdate(assistantMessageEvent);
      case ToolExecutionStartEvent(:final toolName, :final args):
        _onToolExecutionStart(toolName, args);
      case ToolExecutionEndEvent(
        :final toolName,
        :final result,
        :final isError,
      ):
        _onToolExecutionEnd(toolName, result, isError: isError);
      case TurnEndEvent(:final message):
        _usage.add(message.usage);
      default:
    }
  }

  /// Message lifecycle for assistant turns: a start re-arms the
  /// once-per-message prefix; an end flushes the stream and reports the
  /// stop reason.
  void _onMessageLifecycle(Message message, {required bool start}) {
    if (message is! AssistantMessage) return;
    if (start) {
      _assistantPrefixPrinted = false;
      return;
    }
    _onAssistantMessageEnd(message);
  }

  /// Tool call header line: the bold indigo name plus dimmed args.
  void _onToolExecutionStart(String toolName, Map<String, dynamic> args) {
    io.writeln(
      '${_style.bold(_style.indigo('[$toolName]'))} '
      '${_style.dim(formatArgs(args))}',
    );
  }

  /// Streaming deltas: answer text (with the once-per-message prefix) and —
  /// TUI only — dimmed thinking as the progress signal.
  void _onMessageUpdate(AssistantMessageEvent assistantMessageEvent) {
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
  }

  /// End of an assistant message: flush the stream newline, then report the
  /// stop reason (errors, aborts, silent truncations, empty responses).
  void _onAssistantMessageEnd(AssistantMessage message) {
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
        _noteQuietMessageEnd(message);
    }
  }

  /// The non-error/non-abort stop reasons: a tolerated silent truncation
  /// warning, or a note when the turn produced neither text nor tool calls.
  void _noteQuietMessageEnd(AssistantMessage message) {
    // A tolerated silent truncation (no finish_reason) is flagged
    // on the message — tell the user the reply may be cut off.
    if (message.errorMessage != null) {
      io.writeln(_style.dim('(${message.errorMessage})'));
      return;
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

  /// Tool result line: a red error snippet or a teal done marker.
  void _onToolExecutionEnd(
    String toolName,
    ToolExecutionResult result, {
    required bool isError,
  }) {
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
  }

  /// Prints the `>_Fa ` prefix once per assistant message, before the first
  /// text delta. TUI-only: headless and line-mode output stay plain (a piped
  /// headless response must remain the bare assistant text).
  void _writeAssistantPrefix() {
    if (!_useTui || _assistantPrefixPrinted) return;
    io.write('${_style.bold(_style.teal('>_'))}${_style.bold('Fa')} ');
    _assistantPrefixPrinted = true;
  }
}
