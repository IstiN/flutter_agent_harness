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
import '../agent/auto_compactor.dart';
import '../agent/tool_registry.dart';
import '../a2a/a2a_config.dart';
import '../a2a/a2a_manager.dart';
import '../task/task.dart';
import 'agent_tree.dart';
import '../task/agent_discovery.dart';
import '../task/subagent.dart';
import '../task/subagent_manager.dart';
import '../task/subagent_tools.dart';
import '../skills/skills.dart';
import '../prompts/project_context.dart';
import '../prompts/prompts.g.dart' show cliMessagingSectionPrompt;
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
import '../providers/dial.dart';
import '../providers/models_endpoint.dart';
import '../providers/openrouter_oauth.dart';
import '../prompts/prompt_overrides.dart';
import 'chatgpt_oauth_server.dart';
import 'codemie_sso_server.dart';
import 'openrouter_oauth_server.dart';
import '../secrets/secure_key_store.dart';
import '../session/session_record.dart';
import '../session/session_repo.dart';
import 'custom_providers.dart';
import 'provider_flow.dart';
import '../session/session_storage.dart';
import '../session/session_tree.dart';
import '../tools/ask_tool.dart';
import '../tools/request_secret_tool.dart';
import '../tools/builtin_tools.dart';
import '../tools/checkpoint_tool.dart';
import '../tools/generate_image.dart';
import '../tools/inspect_image.dart';
import '../tools/shell_jobs.dart';
import '../tools/sqlite/sqlite_reader.dart';
import '../tools/transcribe_audio.dart';
import '../memory/compaction_memory_hook.dart';
import '../memory/memory_controller.dart';
import '../messaging/file_messaging_repository.dart';
import '../memory/memory_tools.dart';
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
part 'provider_keys.dart';
part 'agent_cli_mcp.dart';
part 'agent_cli_config.dart';
part 'settings_flow.dart';
part 'agent_commands.dart';
part 'approval_commands.dart';

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
    // Long-term memory: controller owns project + user scope stores,
    // lazily initialized. Null when disabled (no LLM provider for search).
    _memory = MemoryController(
      env: config.env,
      projectRoot: config.env.cwd,
      userRoot: config.homeDir,
    );
    final decoratedEnv = SessionVarsExecutionEnv(config.env, _sessionEnvVars);
    // Session-scoped background shell jobs (bash background / steer-yield);
    // settle notifications re-enter the conversation like task completions.
    _shellJobs = ShellJobRegistry(
      env: decoratedEnv,
      onSettled: _onShellJobSettled,
    );
    final coreTools = <AgentTool>[
      ...builtinTools(
        // Session-correlation env vars (FAH_SESSION_ID/FILE/PROVIDER/MODEL)
        // for the bash tool; resolved live, so `/provider` switches and
        // session (re)creation are picked up per exec.
        decoratedEnv,
        webSearch: config.webSearchConfig,
        model: () => _agent.state.model,
        sqlite: config.sqliteEngine,
        lsp: config.lspConfig,
        mcp: _mcp.manager,
        shellJobs: _shellJobs,
      ),
      ...memoryTools(
        _memory,
        onChanged: () => unawaited(_refreshMemorySection()),
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
      // Image generation: resolves the `imageGeneration` slot from the
      // models config (or falls back to the main connection) lazily per
      // call, so `/models set imageGeneration ...` is picked up live.
      generateImageTool(
        env: config.env,
        modelsConfig: config.modelsConfig,
        mainBaseUrl: () => _agent.state.model.baseUrl,
        mainModelId: () => _agent.state.model.id,
        mainApiKey: () => _apiKey,
        resolveKey: _resolveMediaKey,
      ),
      ...pluginTools,
    ];
    // The `task` tool (omp's background subagents): children draw from the
    // core tool surface (never `task` itself), completions are injected back
    // into the parent conversation as async-result messages. Child sessions
    // are REAL JSONL sessions in the same repo, created at child COMPLETION
    // (not at register — creating a session mid-spawn loses the steering
    // race), so `/agents open <id>` can switch into them with the full
    // transcript. The registry itself persists into the parent session as
    // `subagent_registry` custom records, so a resumed session rehydrates
    // its agents (and `/sessions`-shared repos make agents visible across
    // instances of the same cwd).
    _subagentManager = SubagentManager(
      parentSessionId: '',
      // The messaging fabric: per-agent inboxes colocated with the project's
      // sessions (`<sessionRoot>/<cwd-slug>/messages`). Any Fa instance
      // sharing the repo can exchange messages with this one's agents.
      messaging: FileMessagingRepository(
        env: config.env,
        root:
            '${config.sessionRoot}/${encodeSessionCwd(config.env.cwd)}/messages',
        decodeSessionCwd: decodeSessionCwd,
        homeDir: config.homeDir,
      ),
      selfId: 'main',
      sink: (registry) async {
        final session = _session;
        if (session == null) return;
        await session.appendCustomEntry(
          customType: 'subagent_registry',
          data: registry,
        );
      },
      source: () async {
        final session = _session;
        if (session == null) return const [];
        final entries = await session.getEntries();
        List<Map<String, dynamic>> latest = const [];
        for (final entry in entries) {
          if (entry is CustomRecord &&
              entry.customType == 'subagent_registry' &&
              entry.data is List) {
            latest = [
              for (final item in entry.data as List)
                if (item is Map<String, dynamic>) item,
            ];
          }
        }
        return latest;
      },
    );
    // Phase 5a: A2A remote agents from the `a2a:` config section. Connects
    // lazily per server (never blocks boot).
    _a2aManager = A2aManager(config.a2aConfig);
    // Discover agent types from .fah/agents/ and .agents/agents/ (fire-and-forget;
    // the registry starts with built-ins and merges discovered types when they arrive).
    final agentRoots = defaultAgentRoots(
      cwd: config.env.cwd,
      homeDir: config.homeDir,
    );
    unawaited(discoverAgentsFromRoots(agentRoots));
    _taskConfig = TaskToolConfig(
      childTools: coreTools,
      streamFunction: _streamFunction,
      model: config.model,
      rolesResolver: config.modelRolesResolver,
      subagentManager: _subagentManager,
      a2aManager: _a2aManager,
      // Real JSONL child sessions, created at child completion (fast
      // register keeps the steering race away; the transcript lands when
      // the child finishes).
      childSessionFactory: (parentId, childId) async {
        final session = await _repo.create(
          JsonlSessionCreateOptions(
            cwd: config.env.cwd,
            metadata: {
              'agent': 'subagent',
              'id': childId,
              'parent': parentId,
              'model': _agent.state.model.id,
            },
          ),
        );
        return session;
      },
    );
    final monitoringTools = subagentMonitoringTools(
      manager: _subagentManager,
      jobs: _taskConfig.jobManager,
    );
    _toolRegistry = ToolRegistry([
      ...coreTools,
      ...monitoringTools,
      taskTool(config: _taskConfig),
    ]);
    _agent = Agent(
      model: config.model,
      systemPrompt: config.systemPrompt ?? _currentMode.systemPrompt,
      streamFunction: _streamFunction,
      toolRegistry: _toolRegistry,
    );
    // The main agent's inbox in the messaging fabric: messages from
    // children (agent_message to "main") and from other Fa instances
    // sharing the messaging root arrive at turn boundaries.
    _agent.externalSteeringSource = _mainInboxMessages;
    // Non-draining probe for the same inbox: mid-run mail also triggers the
    // tool phase's soft-yield so a long bash/task call does not delay it.
    _agent.externalSteeringProbe = () async {
      final count = await _subagentManager.pendingInboxCount(
        _subagentManager.selfId,
      );
      return count > 0;
    };
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

  /// Removes a saved custom provider from the registry (the `/provider`
  /// picker's Delete action). Clears the active-entry marker when needed and
  /// notifies [AgentCliConfig.onProviderChanged] so the host persists the
  /// registry — deletion never switches the active model, so without the
  /// notification the deletion silently vanished on restart.
  void removeProvider(CustomProviderEntry entry) {
    final registry = config.customProviders;
    if (registry == null) return;
    registry.entries.removeWhere((e) => e.name == entry.name);
    if (_activeCustomName == entry.name) _activeCustomName = null;
    io.writeln('deleted provider ${entry.name}');
    config.onProviderChanged?.call(_providerKind, _apiKey);
  }

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

  /// The session's background shell jobs (`bash background: true` and
  /// steer-yielded foreground commands); settle notifications are injected
  /// like task-job completions.
  late final ShellJobRegistry _shellJobs;

  /// Retained-subagent registry (Phase 3a): tracks every spawned child so
  /// `task_status`/`task_observe`/`task_send` work after completion.
  late final SubagentManager _subagentManager;

  /// The session's retained-subagent registry (tests, the app settings
  /// Agents panel, hosts observing children).
  SubagentManager get subagentManager => _subagentManager;
  late final A2aManager _a2aManager;

  /// Agent types discovered from `.fah/agents/` + `.agents/agents/`.
  List<TaskAgentDefinition> _discoveredAgents = const [];

  late final Agent _agent;
  late final ApprovalManager _approval;
  late final ToolRegistry _toolRegistry;

  /// Long-term memory controller (project + user scope stores). Always
  /// constructed; search is disabled when no LLM provider is injected.
  late final MemoryController _memory;
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

  /// Memo fields for the status line's live context estimate
  /// (see `_liveContextTokens` in approval_commands.dart): keyed on the
  /// transcript size plus the in-flight stream's text length.
  (int, int)? _ctxCacheKey;
  int _ctxCacheValue = 0;
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
      memorySection: _memorySection,
      messagingSection: _messagingSection(),
    );
  }

  /// The `## Agent messaging` prompt section: the agent's own mailbox in
  /// the fabric + how discovery/addressing work. Empty until the session
  /// (and thus the mailbox prefix) exists.
  String _messagingSection() {
    final prefix = _subagentManager.mailboxPrefix;
    if (_subagentManager.messaging == null || prefix.isEmpty) return '';
    return cliMessagingSectionPrompt.replaceAll(
      '{{mailbox}}',
      _subagentManager.mailboxOf(_subagentManager.selfId),
    );
  }

  /// The cached `<memory>` prompt section (durable facts from past
  /// sessions). Loaded asynchronously after startup and refreshed on every
  /// `memory_add` — the prompt composition itself stays synchronous.
  var _memorySection = '';

  /// Re-reads the `<memory>` section from the memory stores and recomposes
  /// the prompt when it changed.
  Future<void> _refreshMemorySection() async {
    final section = await _memory.formatPromptSection();
    if (section == _memorySection) return;
    _memorySection = section;
    _applyPromptComposition();
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

  /// DIAL deployments whose `features.cache` flag the `/openai/models`
  /// payload reports on (manual `cache_breakpoint` markers honored). Empty
  /// until the first models fetch — unknown models keep the optimistic
  /// marker + fallback behavior (see [streamDial]).
  Set<String> _dialCacheModels = const {};

  /// Per-provider cached model lists: entry name → model ids. Refreshed
  /// lazily for ALL saved providers so `/model` can switch across
  /// providers in one pick.
  final Map<String, List<String>> _allProvidersModelCache = {};
  bool _allProvidersCacheRefreshed = false;

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
    _syncMailboxPrefix();
    // Phase 3a: rehydrate the subagent registry from the resumed session's
    // `subagent_registry` records — agents of this session are visible again
    // (across restarts AND across instances sharing the session repo).
    unawaited(_subagentManager.rehydrate());
    // Phase 2: session-start maintenance trigger — fire-and-forget when the
    // last run is >24h old; never blocks the first turn.
    unawaited(
      _memory.maintenanceDue().then((due) async {
        if (due) await _memory.maintain();
      }),
    );
    final interruptSub = io.interrupts.listen((_) {
      if (isBusy) _agent.abort();
    });
    final taskSub = _taskConfig.jobManager.completions.listen(
      _onTaskJobCompleted,
    );
    // The inbox watcher: incoming inter-agent mail while IDLE wakes the
    // agent into a turn (mid-run mail is already delivered by the steering
    // poll). This is what makes two Fa instances chat live.
    final inboxTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_wakeOnInboxMail()),
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
      inboxTimer.cancel();
      await _settled;
      // A session nobody wrote to leaves no file behind.
      await deleteSessionIfEmpty();
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
    // Durable facts from past sessions join the prompt asynchronously
    // (memory stores initialize lazily; recompose on arrival).
    unawaited(_refreshMemorySection());
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

  /// Deletes the active session's file when nothing was ever said in it:
  /// opening the CLI and leaving (or only poking slash commands) must not
  /// litter the sessions list with empty files. Best-effort — exit and
  /// session switching never fail on it. A session that owns subagents is
  /// NOT empty: its `subagent_registry` record is real content.
  Future<void> deleteSessionIfEmpty() async {
    if (_agent.state.messages.isNotEmpty) return;
    if (_subagentManager.handles.isNotEmpty) return;
    final session = _session;
    if (session == null) return;
    try {
      await _repo.delete(await session.getMetadata());
      _session = null;
    } on Object {
      // Best-effort cleanup.
    }
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
      mouseCapture: config.tuiMouseCapture,
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
    'addProvider': _tuiPickAddProvider,
    'settings': _tuiPickSetting,
    'agents': pickAgentFromTree,
    'agentAction': pickAgentAction,
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
    try {
      final session = await _repo.open(metadata);
      final label = await session.getSessionName() ?? metadata.id;
      await _switchToMetadata(metadata, label);
    } on Object catch (error) {
      // Never let a broken session file kill the TUI through the picker's
      // Cmd — report inline instead.
      io.writeln(_errorLine('failed to open session ${metadata.id}: $error'));
    }
  }

  /// A provider-picker selection: `custom` starts the guided flow,
  /// `saved:<name>` switches to a saved custom provider, anything else is a
  /// catalog provider name.
  Future<void> _tuiPickProvider(String key) async {
    if (key == 'add') return _openAddProviderPicker();
    if (key.startsWith('saved:')) return _tuiPickSavedProviderEdit(key);
    await _tuiPickCatalogOrSaved(key);
  }

  /// A `saved:<name>` selection from the provider picker opens the edit/delete
  /// sub-picker for the matching saved provider.
  Future<void> _tuiPickSavedProviderEdit(String key) async {
    final name = key.substring('saved:'.length);
    final entry = config.customProviders?.find(name);
    if (entry != null) _providerEditOrDelete(entry);
  }

  /// The preset picker for adding a new provider: catalog presets each
  /// launching their specific setup flow, plus `Custom` as the generic
  /// openai-compatible path.
  void _openAddProviderPicker() {
    _tuiController?.openPicker('addProvider', 'Add provider', [
      const MenuItem(
        key: 'preset:openrouter',
        label: 'OpenRouter',
        description: 'OAuth or API key — 300+ models',
      ),
      const MenuItem(
        key: 'preset:chatgpt',
        label: 'ChatGPT (Codex)',
        description: 'account sign-in via OAuth',
      ),
      const MenuItem(
        key: 'preset:codemie',
        label: 'CodeMie',
        description: 'organization SSO sign-in',
      ),
      const MenuItem(
        key: 'preset:dial',
        label: 'DIAL',
        description: 'EPAM DIAL Core — Api key + deployment',
      ),
      const MenuItem(
        key: 'preset:kimi',
        label: 'Kimi Code',
        description: 'api.kimi.com — key: kimi.com/code/console',
      ),
      const MenuItem(
        key: 'preset:zai',
        label: 'Z.AI',
        description: 'GLM models — key: z.ai/manage-apikey/apikey-list',
      ),
      const MenuItem(
        key: 'preset:minimax',
        label: 'MiniMax',
        description: 'api.minimax.io — key: platform.minimax.io/interface-key',
      ),
      const MenuItem(
        key: 'preset:openai',
        label: 'OpenAI',
        description: 'api.openai.com — API key',
      ),
      const MenuItem(
        key: 'preset:anthropic',
        label: 'Anthropic',
        description: 'api.anthropic.com — API key',
      ),
      const MenuItem(
        key: 'preset:google',
        label: 'Google',
        description: 'Gemini models — API key',
      ),
      const MenuItem(
        key: 'custom',
        label: 'Custom',
        description: 'any OpenAI-compatible endpoint',
      ),
    ]);
  }

  /// Routes a preset-picker selection to the matching setup flow.
  Future<void> _tuiPickAddProvider(String key) async {
    if (key == 'custom') return _startProviderFlow();
    if (!key.startsWith('preset:')) return;
    await _addProviderHandlers[key.substring('preset:'.length)]?.call();
  }

  /// Preset name → the setup flow it launches.
  late final Map<String, Future<void> Function()> _addProviderHandlers = {
    'openrouter': () => _handleOpenRouterOAuthCommand(headless: false),
    'chatgpt': () => _handleChatGptOAuthCommand(headless: false),
    'codemie': () => _handleCodeMieSsoCommand(defaultCodeMieBaseUrl),
    'dial': () => _startDialProviderSetup(),
    'openai': () async => _startProviderFlow(initialType: 'openai'),
    'anthropic': () async => _startProviderFlow(initialType: 'anthropic'),
    'google': () async => _startProviderFlow(initialType: 'google'),
    'kimi': () async => _startProviderFlow(
      initialType: 'openai',
      initialBaseUrl: 'https://api.kimi.com/coding/v1',
      initialName: 'kimi',
      initialModelId: 'k3',
    ),
    'zai': () async => _startProviderFlow(
      initialType: 'openai',
      initialBaseUrl: 'https://api.z.ai/api/coding/paas/v4',
      initialName: 'z.ai',
      initialModelId: 'glm-4.5',
    ),
    'minimax': () async => _startProviderFlow(
      initialType: 'minimax',
      initialBaseUrl: 'https://api.minimax.io/v1',
      initialName: 'minimax',
      initialModelId: 'MiniMax-M3',
    ),
  };

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
    final List<SessionMetadata> sessions;
    try {
      sessions = await _repo.list(cwd: config.env.cwd);
    } on Object catch (error) {
      // A failing store must surface as an inline error, never kill the TUI
      // (a Cmd exception in dart_tui terminates the whole program silently).
      io.writeln(_errorLine('failed to list sessions: $error'));
      return;
    }
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
  /// session. An unreadable session file degrades to its id with an
  /// "(unreadable)" note instead of failing the whole picker.
  Future<MenuItem> _sessionPickerItem(
    int i,
    SessionMetadata metadata,
    SessionMetadata? current,
  ) async {
    String label;
    try {
      final session = await _repo.open(metadata);
      label = await session.getSessionName() ?? metadata.id;
    } on Object {
      label = '${metadata.id} (unreadable)';
    }
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

  /// The main agent's inbox as steering messages: each pending fabric
  /// message becomes a user message attributed to its sender, so the
  /// transcript reads like a chat between agents.
  Future<List<Message>> _mainInboxMessages() async {
    final queued = await _subagentManager.drainMessages(
      _subagentManager.selfId,
    );
    return [
      for (final message in queued)
        UserMessage.text('from ${message.fromId}: ${message.text.trim()}'),
    ];
  }

  /// Namespaces this instance's mailboxes with the active session id: two
  /// Fa instances sharing the messaging root never drain each other's
  /// inboxes. Called after every session init/switch.
  void _syncMailboxPrefix() {
    _subagentManager.mailboxPrefix = _session?.cachedId ?? '';
    // The prompt's messaging section carries the live mailbox address.
    _applyPromptComposition();
    // Presence: a zero-mail instance is discoverable in agent_directory.
    final fabric = _subagentManager.messaging;
    if (fabric != null && _subagentManager.mailboxPrefix.isNotEmpty) {
      unawaited(
        fabric.register(_subagentManager.mailboxOf(_subagentManager.selfId)),
      );
    }
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
    await deleteSessionIfEmpty();
    _subagentManager.reset();
    final metadata = await _findSessionByName(trimmed);
    if (metadata != null) {
      await _switchToMetadata(metadata, trimmed);
      return;
    }
    _agent.reset();
    _checkpoints.clear();
    _ttsr?.reset();
    _session = await _createSession(name: trimmed);
    _syncMailboxPrefix();
    _persistedCount = 0;
    io.writeln("created session '$trimmed'");
  }

  /// Switches to an existing session by metadata (picker, /resume).
  Future<void> _switchToMetadata(SessionMetadata metadata, String label) async {
    await deleteSessionIfEmpty();
    _subagentManager.reset();
    _agent.reset();
    _checkpoints.clear();
    _ttsr?.reset();
    _session = await _loadSession(metadata);
    _syncMailboxPrefix();
    // Now that `_session` is assigned, the registry source can read the
    // resumed session's `subagent_registry` records.
    unawaited(_subagentManager.rehydrate());
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
    await deleteSessionIfEmpty();
    _subagentManager.reset();
    _agent.reset();
    _checkpoints.clear();
    _ttsr?.reset();
    _session = await _createSession(name: trimmed);
    _syncMailboxPrefix();
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
    // Warm the endpoint metadata (model list, dial cache features, reported
    // limits) BEFORE the first turn: the request then already carries the
    // detected max token caps and the dial marker gating. Failures are
    // silent — the catalog defaults keep applying.
    try {
      await _refreshModelCache();
    } on Object {
      // Swallowed: see _refreshModelCache.
    }
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

  /// Resolves a named secret (env first, then the secure store) for media
  /// slot `apiKeyName` overrides. Returns null when the name is unknown.
  Future<String?> _resolveMediaKey(String name) async {
    final value = config.envVarValue?.call(name);
    if (value != null && value.isNotEmpty) return value;
    return config.secureKeys?.read(name);
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
    // Real user input resets the inbox wake streak (the ping-pong guard).
    _inboxWakeStreak = 0;
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

  /// Called when a background shell job settles (the same async-result flow
  /// as task-job completions): a transcript note, then a system-notice
  /// steered into the running turn or run as a fresh turn while idle.
  void _onShellJobSettled(ShellJobEntry job) {
    io.writeln(
      _style.dim('[bash] ${job.id} exited(${job.exitCode}) — ${job.logPath}'),
    );
    if (_exited) return;
    final message =
        '<system-notice>\n'
        'Background shell job ${job.id} finished with exit code '
        '${job.exitCode}.\n'
        'Command: ${job.command}\n'
        'Log: ${job.logPath}\n'
        'Check the result with bash_job (action: output) or by reading the '
        'log file, and act on it when the result was awaited.\n'
        '</system-notice>';
    if (isBusy) {
      // Mid-run: the steering queue delivers it at the next step boundary.
      _agent.steer(UserMessage.text(message));
    } else {
      _startRun(message);
    }
  }

  Future<void> _afterRun() async {
    // A TTSR abort/inject/retry chain may still be in flight when the
    // aborted run settles; persist only once the whole chain completed.
    await _ttsr?.settled;
    await _persistMessages();
    await _maybeAutoCompact();
  }

  /// Idle-wake guard: one inbox-triggered run at a time.
  var _inboxWakeRunning = false;

  /// Consecutive inbox-triggered runs without any user input — capped so
  /// two chatty instances cannot ping-pong forever (mail still accumulates
  /// and is delivered at the next real turn).
  var _inboxWakeStreak = 0;
  static const _maxInboxWakeStreak = 10;

  /// The inbox watcher tick: while IDLE, new inter-agent mail starts a turn
  /// (the loop's first steering poll drains the inbox into the run). Mid-run
  /// mail needs no wake — the per-turn steering poll already delivers it.
  Future<void> _wakeOnInboxMail() async {
    if (_exited || isBusy || _inboxWakeRunning) return;
    if (_inboxWakeStreak >= _maxInboxWakeStreak) return;
    final count = await _subagentManager.pendingInboxCount(
      _subagentManager.selfId,
    );
    if (count == 0) return;
    _inboxWakeStreak++;
    _inboxWakeRunning = true;
    io.writeln(
      _style.dim('[mail] $count new message(s) — waking up to answer'),
    );
    _startRun(
      '<system-notice>New inter-agent mail arrived ($count message(s)) — '
      'the messages follow below as user messages. Read them and act: reply '
      'with the agent_message tool to the sender address when a response is '
      'expected, or just incorporate the information.</system-notice>',
    );
    unawaited(_settled.whenComplete(() => _inboxWakeRunning = false));
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
    final session = _session;
    if (session == null) return;
    if (_agent.state.messages.isEmpty) return;
    final tokens = estimateContextTokens(_agent.state.messages).tokens;
    if (!shouldCompact(
      tokens,
      _agent.state.model.contextWindow,
      config.compactionSettings ?? defaultCompactionSettings,
    )) {
      return;
    }
    await _runAutoCompact('[auto-compacted]');
  }

  /// `/compact` manual override: same AutoCompactor pipeline as the
  /// auto-trigger, but unconditional. Honours the user's explicit ask
  /// even when the threshold isn't crossed.
  Future<void> _runManualCompact() async {
    final session = _session;
    if (session == null) return;
    if (_agent.state.messages.isEmpty) {
      io.writeln('nothing to compact');
      return;
    }
    await _runAutoCompact('[compacted]');
  }

  /// Builds the per-host smol/main summarizers and runs the shared
  /// [AutoCompactor]. Used by both [_maybeAutoCompact] (gated by
  /// [shouldCompact]) and [_runManualCompact] (unconditional).
  Future<void> _runAutoCompact(String label) async {
    final smol = config.modelRolesResolver?.resolveRole(smolModelRole);
    final ok = await AutoCompactorFactory(
      session: _session!,
      state: _agent.state,
      window: _agent.state.model.contextWindow,
      settings: config.compactionSettings ?? defaultCompactionSettings,
      sources: AutoCompactorSources(
        smolStream: smol?.stream,
        smolModel: smol?.model,
        mainStream: _streamFunction,
        mainModel: _agent.state.model,
      ),
      hooks: _AutoCompactorCliHooks(this),
      prompts: CompactionPrompts.fromOverrides(config.promptOverrides),
      memoryExtractionHook: (text) async {
        final hook = compactionMemoryHook(
          memory: _memory,
          stream: smol?.stream ?? _streamFunction,
          model: smol?.model ?? _agent.state.model,
        );
        await hook?.call(text);
      },
      force: label == '[compacted]',
    ).run();
    _persistedCount = _agent.state.messages.length;
    if (label == '[compacted]' && ok) {
      // Manual `/compact` echoes the legacy "compacted" line; the
      // auto-trigger prints its own per-pass "[auto-compacted]" line via
      // [_AutoCompactorCliHooks.onPass].
      io.writeln('$label $_persistedCount messages kept');
    }
  }

  /// Writes a diagnostic line to the log file (`~/.fah/logs/fa.log`).
  /// TUI/stderr stay clean — the AutoCompactor hook streams progress to
  /// the user, the log captures everything for post-mortem.
  void _logDiagnostic(String message) {
    final path = _diagnosticLogPath;
    if (path == null) return;
    unawaited(_appendDiagnosticLog(path, message));
  }

  /// Appends one timestamped [message] to [path], creating the log directory
  /// on first use. Isolated from [_logDiagnostic] so the public entry point
  /// stays small.
  Future<void> _appendDiagnosticLog(String path, String message) async {
    final line = '${DateTime.now().toIso8601String()} $message\n';
    try {
      if (!_diagnosticLogDirEnsured) {
        _diagnosticLogDirEnsured = true;
        await config.env.createDir(
          '${config.homeDir}/.fah/logs',
          recursive: true,
        );
      }
      await config.env.appendFile(path, line);
    } catch (_) {
      // Diagnostics must never break the CLI.
    }
  }

  /// Returns a user-facing hint for a compaction failure, pointing at the
  /// `smol` role config when the summarization model hit a provider limit.
  String _compactionFailureHint(Object error) {
    final text = error.toString();
    if (text.contains('usage limit') ||
        text.contains('access_terminated_error') ||
        text.contains('rate limit') ||
        text.contains('429')) {
      return '$error\n\n'
          'Compaction uses the `smol` role model (see `roles.smol` in '
          '~/.fah/config.yaml). The current smol model/provider returned '
          'the error above. Switch it to a model/key with available quota, '
          'e.g. via `/settings` → Agent models, or edit ~/.fah/config.yaml.';
    }
    return text;
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
    if (command == '/memory') {
      await _handleMemoryCommand(rest);
      return true;
    }
    if (command == '/agents') {
      await handleAgentsCommand(rest);
      return true;
    }
    if (command == '/a2a') {
      _printA2aStatus();
      return true;
    }
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

  /// `/a2a` — Phase 5a status: per-server connecting/connected/failed.
  void _printA2aStatus() {
    for (final line in formatA2aStatusLines(_a2aManager)) {
      io.writeln(line);
    }
  }

  /// `/memory [maintain]` — Phase 2 memory surface: stats by default,
  /// `maintain` runs the consolidation pipeline now.
  Future<void> _handleMemoryCommand(String rest) async {
    final sub = rest.split(RegExp(r'\s+')).first.trim();
    if (sub == 'maintain') {
      await _runMemoryMaintain();
      return;
    }
    await _printMemoryStats();
  }

  /// The `/memory maintain` branch: runs maintenance with the running-guard
  /// feedback.
  Future<void> _runMemoryMaintain() async {
    io.writeln('maintaining memory (levels + consolidation)…');
    final started = await _memory.maintain();
    if (!started) {
      io.writeln('maintenance already running — skipped');
      return;
    }
    io.writeln('memory maintenance complete');
  }

  /// The bare `/memory` branch: entry counts per type + last maintenance.
  Future<void> _printMemoryStats() async {
    for (final line in formatMemoryStatsLines(
      await _memory.list(limit: 500),
      await _memory.lastMaintenanceAt(),
      await _memory.maintenanceDue(),
    )) {
      io.writeln(line);
    }
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
        _syncMailboxPrefix();
        _persistedCount = 0;
        io.writeln('new session started');
      case '/compact':
        // `/compact` is a manual override — always run the compactor even
        // when the auto-trigger threshold isn't crossed. The user is
        // asking for it explicitly, so we honour the request.
        await _runManualCompact();
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

  /// Whether a guided flow is between prompts.
  var _providerFlowActive = false;

  /// Answers buffered while no flow prompt was pending.
  final _promptLineBuffer = <String>[];

  /// Runtime secrets granted via `request_secret`.
  final Map<String, String> _runtimeSecrets = {};

  /// Path of the diagnostic log file under `~/.fah/logs/fa.log`. Null
  /// when the host has no `homeDir` (web build, sandbox).
  String? get _diagnosticLogPath {
    final home = config.homeDir;
    if (home == null || home.isEmpty) return null;
    return '$home/.fah/logs/fa.log';
  }

  var _diagnosticLogDirEnsured = false;

  String? _activeCustomName;
  Completer<String?>? _wizardPickerAnswer;
}

/// [AutoCompactorHooks] impl that drives the CLI TUI / stderr and the
/// diagnostic log file (`~/.fah/logs/fa.log`). One per run; cheap to
/// allocate.
class _AutoCompactorCliHooks implements AutoCompactorHooks {
  _AutoCompactorCliHooks(this.cli);

  final AgentCli cli;

  @override
  void onPass(AutoCompactorPass pass) {
    cli.io.writeln(
      '[auto-compacted${pass.pass == 1 ? '' : ' pass=${pass.pass}'}] '
      '${pass.tokensBefore} tokens summarized',
    );
    cli._logDiagnostic(
      'auto-compact pass ${pass.pass} '
      'fallback=${pass.fallback ?? '-'} '
      'tokens ${pass.tokensBefore}→${pass.tokensAfter} '
      'ok=${pass.ok} error=${pass.error ?? '-'}',
    );
  }

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {
    cli.io.writeln(
      'compaction transient error (attempt $attempt/$maxAttempts); '
      'retrying in ${backoff.inSeconds}s — $error',
    );
    cli._logDiagnostic(
      'compact retry attempt=$attempt backoff=${backoff.inSeconds}s '
      'error=$error',
    );
  }

  @override
  void onDone(int passes, int tokens) {
    if (passes > 0) {
      cli._logDiagnostic('auto-compact done passes=$passes tokens=$tokens');
    }
  }

  @override
  void onBothRolesFailed(Object lastError) {
    final hint = cli._compactionFailureHint(lastError);
    cli.io.writeln('compaction both roles failed: $hint');
    cli.io.writeln(
      'compaction both roles failed; the agent cannot make progress '
      'until you switch models (e.g. `/model`) or start a new session '
      '(`/new`).',
    );
  }
}
