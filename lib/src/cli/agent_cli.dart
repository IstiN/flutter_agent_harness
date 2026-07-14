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
import '../agent/tool_registry.dart';
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
import '../tools/builtin_tools.dart';
import '../types.dart';
import '../usage_summary.dart';

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
  });

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
String defaultAgentCliSystemPrompt(String cwd) {
  return 'You are fah, a coding agent (also called fa). Never refer to '
      'yourself as pi, Claude, or any other assistant name. You help with '
      'software engineering tasks in the working directory $cwd. Use the '
      'read, write, ls, and bash tools to inspect and modify files and run '
      'commands. Be concise.';
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
           providerStreamFunction(config.providerKind, config.apiKey) {
    _agent = Agent(
      model: config.model,
      systemPrompt:
          config.systemPrompt ?? defaultAgentCliSystemPrompt(config.env.cwd),
      streamFunction: _streamFunction,
      toolRegistry: ToolRegistry(builtinTools(config.env)),
    );
    _agent.subscribe(_onAgentEvent);
  }

  /// The effective system prompt sent to the model.
  String get systemPrompt =>
      config.systemPrompt ?? defaultAgentCliSystemPrompt(config.env.cwd);

  /// The static configuration.
  final AgentCliConfig config;

  /// Terminal IO.
  final CliIO io;

  /// The input prompt written when the agent is idle.
  final String prompt;

  final StreamFunction _streamFunction;
  late final Agent _agent;
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

  /// The underlying agent (exposed for advanced wiring and tests).
  Agent get agent => _agent;

  /// Whether a run is currently streaming.
  bool get isBusy => _agent.state.isStreaming;

  /// Runs the REPL until `/exit` or the input stream closes.
  Future<void> run() async {
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
    if (trimmed.isEmpty) return;
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
      default:
        io.writeln('unknown command: $command (try /help)');
    }
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
  }

  void _printHelp() {
    io.writeln('commands:');
    io.writeln('  /exit        quit');
    io.writeln('  /reset       start a new session');
    io.writeln('  /compact     summarize history to free context');
    io.writeln('  /stats       show token and cost totals');
    io.writeln('  /model <id>  show or switch the model');
    io.writeln('  /help        this help');
    io.writeln(
      'While a run is streaming, typed input steers the agent; '
      'Ctrl-C aborts the run.',
    );
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
