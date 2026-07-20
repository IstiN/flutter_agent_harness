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

import '../agent/agent.dart';
import 'key_event.dart';
import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../agent/tool_registry.dart';
import '../approval/approval.dart';
import '../approval/approval_hook.dart';
import '../cancel_token.dart';
import '../compaction/compaction.dart';
import '../compaction/token_estimation.dart';
import '../context.dart';
import '../env/execution_env.dart';
import '../lsp/lsp_tool.dart';
import '../model.dart';
import '../model_roles/model_roles.dart';
import '../prompts/prompt_overrides.dart';
import '../session/session_repo.dart';
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
import 'prompt_templates.dart';
import 'tui_repl.dart';

export '../model_roles/provider_catalog.dart' show providerStreamFunction;

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
    this.onModeChanged,
    this.onApprovalChanged,
  });

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

  /// Called when the user switches the active mode via `/mode`, `/code`,
  /// `/architect`, or `/review`.
  final void Function(String mode)? onModeChanged;

  /// Called when the approval state changes (`/approval`, `/allow`, or an
  /// "approve always" prompt answer) so the executable can persist it.
  final void Function()? onApprovalChanged;

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
}

/// The CLI harness: agent + built-in tools + session persistence +
/// compaction, driven by a [CliIO].
class AgentCli {
  /// Creates an [AgentCli]. [streamFunction] overrides the provider adapter
  /// (used in tests); otherwise one is built from
  /// [AgentCliConfig.providerKind] and [AgentCliConfig.apiKey].
  AgentCli({
    required this.config,
    required this.io,
    StreamFunction? streamFunction,
    this.prompt = 'fa> ',
    bool useColor = false,
    bool useTui = false,
    this._version = '0.0.0',
  }) : _style = _Style(enabled: useColor),
       _useTui = useTui && io.supportsRawMode,
       _modes = builtInAgentModes(
         config.env.cwd,
         overrides: config.promptOverrides,
       ) {
    _currentMode = _modes[config.initialMode] ?? _modes['code']!;
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

    _toolRegistry = ToolRegistry([
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
    ]);
    _streamFunction =
        streamFunction ??
        providerStreamFunction(config.providerKind, config.apiKey);
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
  String get systemPrompt => config.systemPrompt ?? _currentMode.systemPrompt;

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
  /// model-roles wiring and `/model` switches replace it.
  late StreamFunction _streamFunction;
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
  var _exited = false;
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
  final Map<String, SlashCommand> _pluginSlashCommands = {};
  final Map<String, AgentMode> _modes;
  late AgentMode _currentMode;
  List<PromptTemplate> _templates = [];

  /// Model ids shown by the most recent `/model` picker, so `/model N` can
  /// select by number without retyping the full id.
  List<String>? _lastModelList;

  Map<String, dynamic> _pluginConfig(String name) {
    final raw = config.pluginConfig[name];
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const {};
  }

  /// Merges multiple streams into one broadcast stream.
  static Stream<T> _mergeStreams<T>(List<Stream<T>> streams) {
    final controller = StreamController<T>.broadcast();
    final subscriptions = <StreamSubscription<T>>[];
    var doneCount = 0;
    void onDone() {
      if (++doneCount >= streams.length) {
        controller.close();
      }
    }

    for (final stream in streams) {
      subscriptions.add(
        stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: onDone,
        ),
      );
    }
    controller.onCancel = () async {
      await Future.wait(subscriptions.map((s) => s.cancel()));
    };
    return controller.stream;
  }

  /// Whether a run is currently streaming.
  bool get isBusy => _agent.state.isStreaming;

  /// Runs the REPL until `/exit` or the input stream closes.
  Future<void> run() async {
    _templates = await loadPromptTemplates(
      config.env,
      config.promptTemplateDirs,
    );
    _session = await _initializeSession();
    final interruptSub = io.interrupts.listen((_) {
      if (isBusy) _agent.abort();
    });
    try {
      await _printBanner();
      if (_useTui) {
        await _runTuiRepl();
      } else {
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
          if (!isBusy) _writeIdlePrompt();
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
      await _settled;
    }
  }

  Future<void> _runTuiRepl() async {
    final repl = TuiRepl(
      write: io.write,
      writeln: io.writeln,
      prompt: prompt,
      statusLine: _statusLine,
      style: _style,
      buildSlashMenu: _buildSlashMenu,
      buildModelMenu: _buildModelMenu,
      onSubmit: _handleLine,
      onModelSelected: _tuiSelectModel,
      onInterrupt: () {
        if (isBusy) _agent.abort();
      },
      isExited: () => _exited,
    );

    // In raw mode stdin can only have one listener, so drive the REPL from
    // key events only. For non-raw hosts (tests, headless, embedded panels)
    // keys is empty and we fall back to typed lines.
    final input = io.supportsRawMode
        ? io.keys
        : _mergeStreams<dynamic>([io.lines, io.keys]);
    await repl.run(input);
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

  List<MenuItem> _buildModelMenu() {
    final models = _listModelsForMenu();
    return [
      for (var i = 0; i < models.length; i++)
        MenuItem(key: models[i], label: '${i + 1}) ${models[i]}'),
    ];
  }

  Future<void> _tuiSelectModel(String modelId) async {
    await _handleModelCommand(modelId);
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

  Future<void> _switchSession(String name) async {
    final trimmed = name.trim();
    final metadata = await _findSessionByName(trimmed);
    if (metadata != null) {
      _agent.reset();
      _checkpoints.clear();
      _ttsr?.reset();
      _session = await _loadSession(metadata);
      io.writeln("switched to session '$trimmed'");
      return;
    }
    _agent.reset();
    _checkpoints.clear();
    _ttsr?.reset();
    _session = await _createSession(name: trimmed);
    _persistedCount = 0;
    io.writeln("created session '$trimmed'");
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
    try {
      await _agent.prompt(prompt);
      // Awaits any in-flight TTSR retry chain, persists the messages, and
      // auto-compacts — the same end-of-turn sequence as a REPL run.
      await _afterRun();
    } catch (error) {
      io.writeln(_errorLine('$error'));
      return 1;
    } finally {
      await interruptSub.cancel();
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
    io.writeln(_style.bold(_style.cyan('fa v$_version')));
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
    if (keyStatus != null) io.writeln('  $keyStatus');
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
  /// live model's provider names are the right ones there.
  String? _keyStatusLine(Model model) {
    final spec = catalogProvider(
      _rolesDriven ? model.provider : config.providerKind,
    );
    final names = spec?.apiKeyEnvNames;
    if (names == null || names.isEmpty) return null;
    final set = names
        .where((name) => config.envVarIsSet?.call(name) ?? false)
        .firstOrNull;
    if (set != null) return 'key: $set';
    if (spec != null && model.baseUrl != spec.defaultBaseUrl) return null;
    return 'key: no key set (want ${names.first})';
  }

  /// The `error:` diagnostic line for a failed run. A connection-level
  /// failure ("Connection refused" — a SocketException, or a package:http
  /// ClientException wrapping one; the provider adapters reduce both to
  /// their message string, so detection is textual) appends the endpoint
  /// hint: the effective base URL from the config or `--base-url` is almost
  /// always the thing to fix then.
  String _errorLine(String message) {
    if (!message.toLowerCase().contains('connection refused')) {
      return 'error: $message';
    }
    return 'error: $message — check the endpoint in ~/.fah/config.yaml '
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
    } else if (trimmed.startsWith('/')) {
      await _handleCommand(trimmed);
    } else {
      _startRun(line);
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
      case '/model':
        await _handleModelCommand(rest);
      case '/models':
        _listModels(rest);
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
        await _listSessions();
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
      case '/mode':
        await _handleMode(rest);
      case '/approval':
        _handleApprovalMode(rest);
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
    _agent.state.systemPrompt = mode.systemPrompt;
    io.writeln('switched mode to ${mode.name}');
    config.onModeChanged?.call(mode.name);
  }

  /// Lists the known models for the active provider, optionally filtered by
  /// [filter]. The output is numbered so `/model N` can pick one.
  void _listModels(String filter) {
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
  /// lowercase substring.
  List<String> _modelCandidates([String filter = '']) {
    final provider = _agent.state.model.provider;
    final all = _knownModels[provider] ?? const <String>[];
    if (filter.isEmpty) return all.toList();
    final lower = filter.toLowerCase();
    return all.where((id) => id.toLowerCase().contains(lower)).toList();
  }

  Future<void> _handleModelCommand(String rest) async {
    final trimmed = rest.trim();
    if (trimmed == '?') {
      _listModels('');
      return;
    }
    if (trimmed.isEmpty) {
      // Bare `/model` keeps the original behavior: print the active model
      // and, when model roles are configured, the roles overview.
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
    final model = _agent.state.model.id;
    final total = _usage.total;
    final tokens = total.totalTokens;
    final cost = total.cost.total.toStringAsFixed(4);
    final cwd = config.env.cwd;
    return '$cwd · ${tokens}tok · \$$cost · turn ${_usage.turns} · $model';
  }

  /// Prints a divider, the status bar, and the input prompt. Used whenever the
  /// REPL becomes idle after a command or a run.
  void _writeIdlePrompt() {
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
    '/model': '<provider/model> — select model (opens selector)',
    '/models': '[filter] — list known models for the current provider',
    '/mode': '[name] — show or switch the active mode',
    '/session': '[name] — show current or switch/create a named session',
    '/session-new': '<name> — create a new named session',
    '/sessions': 'list named sessions for the current directory',
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

  void _onAgentEvent(AgentEvent event, CancelToken cancelToken) {
    switch (event) {
      case MessageUpdateEvent(:final assistantMessageEvent):
        if (assistantMessageEvent is TextDeltaEvent) {
          io.write(assistantMessageEvent.delta);
          _streamedText = true;
        }
      case MessageEndEvent(:final message):
        if (message is AssistantMessage) {
          if (_streamedText) {
            // The trailing newline of the streamed text belongs to the
            // primary channel (write), not to diagnostics (writeln) — a
            // headless host routes only writeln to stderr.
            io.write('\n');
            _streamedText = false;
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
          }
        }
      case ToolExecutionStartEvent(:final toolName, :final args):
        io.writeln('[$toolName] ${_formatArgs(args)}');
      case ToolExecutionEndEvent(
        :final toolName,
        :final result,
        :final isError,
      ):
        if (isError) {
          final text = result.content
              .whereType<TextContent>()
              .map((block) => block.text)
              .join();
          var snippet = text.split('\n').first;
          if (snippet.length > 120) {
            snippet = '${snippet.substring(0, 120)}...';
          }
          io.writeln('[$toolName] error: $snippet');
        } else {
          io.writeln('[$toolName] done');
        }
      case TurnEndEvent(:final message):
        _usage.add(message.usage);
      default:
    }
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
