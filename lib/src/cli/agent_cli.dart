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
import '../exceptions.dart';
import '../model.dart';
import '../providers/anthropic.dart';
import '../providers/google.dart';
import '../providers/openai_completions.dart';
import '../session/session_repo.dart';
import '../session/session_tree.dart';
import '../tools/ask_tool.dart';
import '../tools/builtin_tools.dart';
import '../tools/inspect_image.dart';
import '../plugins/plugin.dart';
import '../types.dart';
import '../usage_summary.dart';
import 'prompt_templates.dart';

/// Terminal IO abstracted for testability.
///
/// The real implementation (in `bin/fah.dart`) binds [lines] to stdin,
/// [write]/[writeln] to stdout, and [interrupts] to SIGINT; tests substitute
/// scripted lines and capture output in memory.
abstract interface class CliIO {
  /// User-typed input lines, without the trailing newline.
  Stream<String> get lines;

  /// Cancel signals (Ctrl-C). Each event aborts the current run.
  Stream<void> get interrupts;

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
    this.providerKind = 'openai-completions',
    this.systemPrompt,
    this.visionConfig,
    this.plugins = const [],
    this.pluginConfig = const {},
    this.promptTemplateDirs = const [],
    this.initialMode = 'code',
    this.approvalMode = ApprovalMode.yolo,
    this.alwaysAllowTools = const {},
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
  /// is injected into [AgentCli].
  final String apiKey;

  /// Execution environment backing the built-in tools and session storage.
  final ExecutionEnv env;

  /// Root directory for JSONL sessions (cwd-encoded layout, like pi).
  final String sessionRoot;

  /// Provider adapter kind: `openai-completions`, `anthropic`, or `google`.
  final String providerKind;

  /// System prompt override; defaults to [defaultAgentCliSystemPrompt].
  final String? systemPrompt;

  /// Optional vision model configuration. When provided, the `inspect_image`
  /// tool is registered and routes image analysis to a dedicated model.
  ///
  /// Prefer using the `inspect_image` plugin via [plugins] / [pluginConfig].
  final InspectImageConfig? visionConfig;

  /// Plugins to register at startup.
  final List<FahPlugin> plugins;

  /// Per-plugin configuration from `.fah/packages.yaml` (keyed by plugin name).
  final Map<String, dynamic> pluginConfig;
}

/// Builds the [StreamFunction] for a provider [kind] (`openai-completions`,
/// `anthropic`, `google`) with a static [apiKey]. Throws [ConfigException]
/// for unknown kinds.
StreamFunction providerStreamFunction(String kind, String apiKey) {
  return switch (kind) {
    'openai-completions' =>
      (model, context, {cancelToken}) => streamOpenAICompletions(
        model,
        context,
        OpenAICompletionsOptions(apiKey: apiKey, cancelToken: cancelToken),
      ),
    'anthropic' => (model, context, {cancelToken}) => streamAnthropic(
      model,
      context,
      AnthropicOptions(apiKey: apiKey, cancelToken: cancelToken),
    ),
    'google' => (model, context, {cancelToken}) => streamGoogle(
      model,
      context,
      GoogleOptions(apiKey: apiKey, cancelToken: cancelToken),
    ),
    _ => throw ConfigException('Unknown provider kind: $kind'),
  };
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
    this.prompt = 'fah> ',
  }) : _streamFunction =
           streamFunction ??
           providerStreamFunction(config.providerKind, config.apiKey),
       _modes = builtInAgentModes(config.env.cwd) {
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

    _agent = Agent(
      model: config.model,
      systemPrompt: config.systemPrompt ?? _currentMode.systemPrompt,
      streamFunction: _streamFunction,
      toolRegistry: ToolRegistry([
        ...builtinTools(config.env),
        // Non-interactive input (piped) gets a null ask callback: ask calls
        // then fail with a "host cannot answer" error result (safe default).
        askTool(callback: io.isInteractive ? _answerAskQuestions : null),
        if (config.visionConfig != null)
          inspectImageTool(config.env, config.visionConfig!),
        ...pluginTools,
      ]),
    );
    _approval = ApprovalManager(
      mode: config.approvalMode,
      alwaysAllow: config.alwaysAllowTools,
      // Non-interactive input (piped) gets no prompt callback: prompt-policy
      // calls are then denied with a "no approval UI" reason (safe default).
      prompt: io.isInteractive ? _promptForApproval : null,
    );
    attachApproval(_agent, _approval);
    _agent.subscribe(_onAgentEvent);
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

  /// The static configuration.
  final AgentCliConfig config;

  /// Terminal IO.
  final CliIO io;

  /// The input prompt written when the agent is idle.
  final String prompt;

  final StreamFunction _streamFunction;
  late final Agent _agent;
  late final ApprovalManager _approval;
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
    _session = await _createSession();
    final interruptSub = io.interrupts.listen((_) {
      if (isBusy) _agent.abort();
    });
    try {
      await _printBanner();
      io.write(prompt);
      await for (final line in io.lines) {
        await _handleLine(line);
        if (_exited) break;
        if (!isBusy) io.write(prompt);
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

  Future<Session> _createSession() {
    return _repo.create(
      JsonlSessionCreateOptions(
        cwd: config.env.cwd,
        metadata: {'agent': 'fah', 'model': _agent.state.model.id},
      ),
    );
  }

  Future<void> _printBanner() async {
    final model = _agent.state.model;
    final metadata = await _session!.getMetadata();
    io.writeln('fah — flutter_agent_harness CLI');
    io.writeln('model: ${model.id} (${model.api})');
    io.writeln('cwd: ${config.env.cwd}');
    io.writeln('session: ${metadata.path}');
    io.writeln('Type /help for commands.');
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
    if (trimmed.startsWith('/')) {
      await _handleCommand(trimmed);
    } else {
      _startRun(line);
    }
  }

  void _startRun(String text) {
    final settled = _agent.prompt(text).then((_) => _afterRun()).catchError((
      Object error,
    ) {
      io.writeln('error: $error');
    });
    _settled = settled;
    unawaited(
      settled.then((_) {
        if (!_exited) io.write(prompt);
      }),
    );
  }

  Future<void> _afterRun() async {
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
      final manager = CompactionManager(
        summarize: streamFunctionSummarizer(
          _streamFunction,
          _agent.state.model,
        ),
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
        _printHelp();
      case '/stats':
        _printStats();
      case '/model':
        await _switchModel(rest);
      case '/reset':
        _agent.reset();
        _session = await _createSession();
        _persistedCount = 0;
        io.writeln('new session started');
      case '/compact':
        await _compact('[compacted]');
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
        } else {
          io.writeln('unknown command: $command (try /help)');
        }
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

  Future<void> _switchModel(String modelId) async {
    final current = _agent.state.model;
    if (modelId.isEmpty) {
      io.writeln('model: ${current.id} (${current.api})');
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

  void _printHelp() {
    io.writeln('commands:');
    io.writeln('  /exit              quit');
    io.writeln('  /reset             start a new session');
    io.writeln('  /compact           summarize history to free context');
    io.writeln('  /stats             show token and cost totals');
    io.writeln('  /model <id>        show or switch the model');
    io.writeln('  /mode [name]       show or switch the active mode');
    io.writeln(
      '  /approval [mode]   show or set tool approval (always-ask|write|yolo)',
    );
    io.writeln('  /allow [tool]      always-allow a tool (or list them)');
    io.writeln('  /code              switch to coding mode');
    io.writeln('  /architect         switch to architect mode');
    io.writeln('  /review            switch to review mode');
    io.writeln('  /help              this help');
    io.writeln(
      'While a run is streaming, typed input steers the agent; '
      'Ctrl-C aborts the run.',
    );
    if (_pluginSlashCommands.isNotEmpty) {
      io.writeln('plugin commands:');
      for (final entry in _pluginSlashCommands.entries) {
        io.writeln('  ${entry.key}');
      }
    }
    if (_templates.isNotEmpty) {
      io.writeln('prompt templates:');
      for (final t in _templates) {
        final hint = t.argumentHint ?? '';
        io.writeln('  /${t.name} $hint');
      }
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
            io.writeln('');
            _streamedText = false;
          }
          switch (message.stopReason) {
            case StopReason.error:
              io.writeln('error: ${message.errorMessage ?? 'unknown error'}');
            case StopReason.aborted:
              io.writeln('aborted: ${message.errorMessage ?? 'aborted'}');
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
