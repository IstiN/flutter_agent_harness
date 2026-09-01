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

import 'ansi_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import '../agent/agent.dart';
import 'agent_event_handler.dart';
import 'headless_prompt.dart';
import 'key_event.dart';
import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../agent/auto_compactor.dart';
import '../providers/models_for_endpoint.dart';
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
import '../skills/skill_renderer.dart';
import '../prompts/project_context.dart';
import '../prompts/prompts.g.dart' show cliMessagingSectionPrompt;
import '../approval/approval.dart';
import '../approval/approval_hook.dart';
import '../cancel_token.dart';
import '../compaction/compaction.dart';
import '../compaction/token_estimation.dart';
import '../context.dart';
import '../env/cwd_override_env.dart';
import '../env/execution_env.dart';
import '../env/session_vars_execution_env.dart';
import '../exceptions.dart';
import '../lsp/lsp_tool.dart';
import '../mcp/mcp_config.dart';
import '../mcp/mcp_manager.dart';
import '../model.dart';
import '../model_roles/model_roles.dart';
import 'tool_phase_labels.dart';
import '../model_roles/vision_models.dart';
import '../providers/chatgpt_codex_models.dart';
import '../providers/chatgpt_oauth.dart';
import '../providers/codemie_sso.dart';
import '../providers/copilot_device_flow.dart';
import '../providers/copilot_oauth.dart';
import '../providers/dial.dart';
import '../providers/models_endpoint.dart';
import '../providers/openrouter_oauth.dart';
import '../providers/provider_common.dart'
    show authExpiredProvider, stripAuthExpiredMarker;
import '../providers/transient_retry_stream.dart';
import '../prompts/prompt_overrides.dart';
import 'chatgpt_oauth_server.dart';
import 'codemie_sso_server.dart';
import 'openrouter_oauth_server.dart';
import '../secrets/secure_key_store.dart';
import '../session/session_record.dart';
import '../session/session_repo.dart';
import '../session/attach/session_presence.dart';
import 'custom_providers.dart';
import 'provider_flow.dart';
import '../session/session_storage.dart';
import '../session/session_tree.dart';
import '../tools/ask_tool.dart';
import '../tools/request_secret_tool.dart';
import '../tools/builtin_tools.dart';
import '../tools/checkpoint_tool.dart';
import '../tools/generate_image.dart';
import '../tools/generate_video.dart';
import '../tools/inspect_image.dart';
import '../tools/shell_jobs.dart';
import '../tools/sqlite/sqlite_reader.dart';
import '../tools/transcribe_audio.dart';
import '../memory/compaction_memory_hook.dart';
import '../memory/harness_llm_provider.dart';
import '../memory/memory_controller.dart';
import '../memory_config.dart';
import '../messaging/agent_message.dart';
import '../messaging/file_messaging_repository.dart';
import '../messaging/schedule_message_tool.dart';
import '../messaging/scheduled_messages.dart';
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

part 'provider_flow_helpers.dart';
part 'provider_commands.dart';
part 'agent_cli_compaction.dart';
part 'provider_models.dart';
part 'codemie_provider_commands.dart';
part 'provider_keys.dart';
part 'agent_cli_mcp.dart';
part 'agent_cli_config.dart';
part 'settings_flow.dart';
part 'agent_commands.dart';
part 'approval_commands.dart';
part 'skill_commands.dart';
part 'session_commands.dart';
part 'agent_cli_provider_presets.dart';
part 'agent_cli_inbox.dart';
part 'agent_cli_io.dart';

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
       _useTui = useTui && io.supportsRawMode {
    _env = CwdOverrideEnv(config.env);
    _modes = builtInAgentModes(_env.cwd, overrides: config.promptOverrides);
    _currentMode = _modes[config.initialMode] ?? _modes['code']!;
    _providerKind = config.providerKind;
    _apiKey = config.apiKey;
    final pluginTools = <AgentTool>[];
    for (final plugin in config.plugins) {
      final context = PluginContext(
        env: _env,
        io: _PluginIO(io),
        config: _pluginConfig(plugin.name),
      );
      plugin.register(context);
      pluginTools.addAll(context.tools);
      _pluginInboxes.addAll(context.externalInboxes);
      _pluginSlashCommands.addAll(context.slashCommands);
    }

    _streamFunction =
        streamFunction ??
        _catalogStreamFunction(config.providerKind, config.apiKey);
    // MCP servers connect lazily in the background; their tools land in
    // the registry via _onMcpChanged (registered after the agent exists).
    _mcp = AgentCliMcpWiring(config: config.mcpConfig, cwd: _env.cwd);
    // Long-term memory: controller owns project + user scope stores,
    // lazily initialized. Null when disabled (no LLM provider for search).
    _memory = MemoryController(
      env: _env,
      projectRoot: _env.cwd,
      userRoot: config.homeDir,
      // `memory:` config section — git-backed memory points projectPath
      // inside the repo; null keeps the .fah/memory default.
      projectStoragePath: config.memoryConfig?.projectPath,
      userStoragePath: config.memoryConfig?.userPath,
      // Semantic search + consolidate() need an LLM: memory → smol → main.
      llmProvider: HarnessLlmProvider(resolve: () => _resolveMemoryLlmSlot()),
    );
    final decoratedEnv = SessionVarsExecutionEnv(_env, _sessionEnvVars);
    // Session-scoped background shell jobs (bash background / steer-yield);
    // settle notifications re-enter the conversation like task completions.
    _shellJobs = ShellJobRegistry(
      env: decoratedEnv,
      onSettled: _onShellJobSettled,
      onStaleJobLog: _onStaleJobLog,
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
      // schedule_message: self-addressed delayed notes — an agent can
      // schedule its own follow-up check; delivery rides the inbox idle-wake.
      scheduleMessageTool(_scheduledMessages),
      // Non-interactive input gets a null ask callback (safe default).
      askTool(callback: io.isInteractive ? _answerAskQuestions : null),
      // request_secret: ask the user for missing API keys securely.
      requestSecretTool(
        callback: io.isInteractive ? _answerSecretRequest : null,
      ),
      if (config.visionConfig != null)
        inspectImageTool(_env, config.visionConfig!),
      if (config.transcribeConfig != null)
        transcribeAudioTool(_env, config.transcribeConfig!),
      // Image generation: resolves the `imageGeneration` slot lazily per
      // call so `/models set imageGeneration ...` is picked up live.
      generateImageTool(
        env: _env,
        modelsConfig: config.modelsConfig,
        mainBaseUrl: () => _agent.state.model.baseUrl,
        mainModelId: () => _agent.state.model.id,
        mainApiKey: () => _apiKey,
        resolveKey: _resolveMediaKey,
      ),
      // Video generation: videoGeneration slot only (no chat fallback).
      generateVideoTool(
        env: _env,
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
      // Messaging fabric: per-agent inboxes under the session root.
      // SwappableMessagingRepository lets _createSession re-point the
      // fabric when storage falls back to another root.
      messaging: _fabricRepository = SwappableMessagingRepository(
        FileMessagingRepository(
          env: _env,
          // Messaging is scoped to the *launch* cwd. Sessions are grouped
          // by cwd; the fabric is initialized once. Each mailbox is
          // namespaced by session id.
          root: _messagesRoot =
              '${config.sessionRoot}/${encodeSessionCwd(_env.cwd)}/messages',
          decodeSessionCwd: decodeSessionCwd,
          homeDir: config.homeDir,
        ),
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
    // Discover agent types from the agent roots (.fah/.agents/.claude/.github/
    // .codex) — fire-and-forget; the registry starts with built-ins and merges
    // discovered types when they arrive. Third-party roots ride the same
    // consent gate as skills.
    final agentRoots = defaultAgentRoots(
      cwd: _env.cwd,
      homeDir: config.homeDir,
    );
    unawaited(
      discoverAgentsFromRoots(
        agentRoots,
        allowedSources: _skillsAllowedSources,
      ),
    );
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
            cwd: _env.cwd,
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
      // The CLI handles empty-response retries itself with a 'continue' nudge
      // so the transcript reflects the retry explicitly.
      maxEmptyRetries: 0,
      // Post-mortem "who held the busy row": the run idle watchdog's fire
      // lands in fa.log with the session id.
      onRunIdleTimeout: (error) =>
          _logDiagnostic('RUN IDLE WATCHDOG fired sid=$_logSid error=$error'),
    );
    // The main agent's inbox in the messaging fabric: messages from
    // children (agent_message to "main") and from other Fa instances
    // sharing the messaging root arrive at turn boundaries.
    _agent.externalSteeringSource = _mainInboxMessages;
    // Non-draining probe for the same inbox: mid-run mail also triggers the
    // tool phase's soft-yield so a long bash/task call does not delay it.
    _agent.externalSteeringProbe = _mainInboxProbe;
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
    // Busy-row honesty: name the executing tool ('Running bash…') instead
    // of leaving a stale 'Compacting context…' label over long tool calls.
    attachToolPhaseLabels(
      _agent,
      (phase) => _tuiController?.setBusyPhase(phase),
    );
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
    // If the startup provider/model/baseUrl triple points to a saved CodeMie
    // SSO custom provider, wire cookie-header auth instead of sending the
    // stored cookie as an Authorization: Bearer token.
    _restoreCodeMieCookieAuthIfNeeded();
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

  /// Mutable wrapper around [_env]. Its cwd is updated when the user
  /// switches to a session that was created in another project folder, so
  /// tools (read/edit/bash) operate in the session's directory without
  /// restarting the process.
  late final CwdOverrideEnv _env;

  /// Terminal IO.
  final CliIO io;

  /// The input prompt written when the agent is idle.
  final String prompt;

  /// Built-in agent modes. Rebuilt when the effective cwd changes so the
  /// system prompt's project context follows the active session.
  late Map<String, AgentMode> _modes;

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

  /// Test seam driving the TUI model-menu builder in line mode: the same
  /// `_buildModelMenu` the TUI's model picker renders.
  @visibleForTesting
  List<MenuItem> buildModelMenuForTest(String filter) =>
      _buildModelMenu(filter);

  /// The deduped `(provider, modelId)` pair list the picker is built
  /// from. Exposed for tests so cross-provider invariants (catalog
  /// fallback chains, dedup with the saved entry's modelId) can be
  /// asserted without driving the TUI two-step picker.
  @visibleForTesting
  List<(String, String)> crossProviderCandidatesForTest([String filter = '']) =>
      _crossProviderCandidates(filter);

  /// Test seam for the TUI's model-menu selection: routes `@<provider>`
  /// (the two-step pick's provider row) and `provider|model` keys the same
  /// way the live picker does.
  @visibleForTesting
  Future<void> tuiSelectModelForTest(String key) => _tuiSelectModel(key);

  /// Test seam for the private `/model` memory write path: records
  /// [modelId] into the active saved entry (no-op without one), the same
  /// thing a real `/model` switch does while a custom provider is active.
  @visibleForTesting
  void recordCustomModelForTest(String modelId) => _recordCustomModel(modelId);

  /// Test seam driving the TUI picker's Edit action in line mode: opens
  /// the prefilled edit wizard for [entry] (or the active provider when
  /// null), the same `_startProviderEditWizard` the picker calls.
  @visibleForTesting
  void startProviderEditWizardForTest(CustomProviderEntry? entry) =>
      _startProviderEditWizard(entry);

  /// The rows of the "Add provider" preset picker — the test asserts every
  /// catalog provider with a typed `/provider <name>` flow is listed
  /// (Copilot shipped missing: the list is hand-maintained).
  @visibleForTesting
  List<MenuItem> addProviderItemsForTest() => _addProviderItems();

  /// The deliberate picker exclusions (provider name → reason) — with
  /// [addProviderItemsForTest] the test asserts the catalog is exactly
  /// presets ∪ exclusions.
  @visibleForTesting
  Map<String, String> addProviderExclusionsForTest() => _addProviderExclusions;

  /// The preset names with a routing handler — the test asserts
  /// presets == handlers (a preset row without a handler is a dead menu
  /// entry: the picker closes and nothing happens — the live Copilot bug).
  @visibleForTesting
  Set<String> addProviderHandlerKeysForTest() =>
      _addProviderHandlers.keys.toSet();

  /// Test seam routing an "Add provider" picker selection in line mode.
  @visibleForTesting
  Future<void> tuiPickAddProviderForTest(String key) =>
      _tuiPickAddProvider(key);

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

  /// The messaging fabric wrapper — re-pointed when session storage falls
  /// back to a different root so the mailboxes follow the sessions.
  late final SwappableMessagingRepository _fabricRepository;

  /// The launch-cwd messaging root (also backs scheduled messages).
  late final String _messagesRoot;

  /// Persisted delayed messages (`schedule_message`): pending records live
  /// under `<messagesRoot>/_scheduled/` and are delivered into the
  /// agent's own inbox when due, where the idle-wake starts a turn.
  late final ScheduledMessageQueue _scheduledMessages = ScheduledMessageQueue(
    env: _env,
    repo: () => _fabricRepository,
    root: () => _messagesRoot,
  );

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

  /// Hard bounds for the compaction-time memory extraction (see
  /// `_runAutoCompact`): cancel the extraction stream after 90s, and
  /// force-skip after 120s even if the cancel didn't land.
  static const _memoryExtractionDeadline = Duration(seconds: 90);
  static const _memoryExtractionHardCap = Duration(seconds: 120);

  /// Memoized settled-part context estimate for the status line
  /// (see `_liveContextTokens` in approval_commands.dart): keyed on the
  /// transcript list identity + length only — never on stream content.
  final SettledContextEstimate _ctxEstimate = SettledContextEstimate();
  late SessionRepo _repo = JsonlSessionRepo(
    fs: _env,
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
  final List<ExternalInbox> _pluginInboxes = [];
  late AgentMode _currentMode;
  List<PromptTemplate> _templates = [];

  /// Discovered agent skills (progressive disclosure into the system
  /// prompt) and project context files, loaded once per CLI run.
  List<Skill> _skills = const [];
  List<ProjectContextFile> _contextFiles = const [];

  /// Consent for third-party (Claude/Copilot/Codex) skill & agent roots.
  /// Mutable: the startup consent dialog and `/skills access` change it;
  /// the host persists it via [AgentCliConfig.onSkillsAccessChanged].
  late SkillsAccess _skillsAccess = config.skillsAccess;

  /// Whether any third-party skill/agent root exists on disk — drives the
  /// one-time consent dialog and the "disabled" hint. Computed by
  /// [_loadAgentContext] while access is not granted.
  bool _thirdPartySkillDirsPresent = false;

  /// Paths the agent touched this session (tool call args) — path-gated
  /// skills (`paths:` frontmatter) enter the prompt once their globs match.
  final Set<String> _touchedPaths = {};

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
      skillsSection: formatSkillsForPrompt(
        _skills,
        touchedPaths: _touchedPaths,
        cwd: _env.cwd,
      ),
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

  /// Whether a run is currently in flight. True from the moment a run is
  /// STARTED (pre-flight compaction runs before the first streamed byte) —
  /// not only while the provider streams.
  bool get isBusy => _runStarting || _agent.state.isStreaming;

  /// Set synchronously when a run starts, cleared when it fully settles
  /// (including post-run compaction): the busy gate for every isBusy reader.
  bool _runStarting = false;

  /// Runs the REPL until `/exit` or the input stream closes.

  /// Transient network retry visibility (the Wi-Fi-switch case): the
  /// retry itself lives in providerStreamFunction; here it gets a voice —
  /// a dim transcript line + an fa.log entry instead of a silent 5s pause.
  void _wireTransientRetryNotice() {
    transientRetryNotice = (attempt, maxAttempts, delay, reason) {
      io.writeln(
        _style.dim(
          '[net] connection lost ($reason) — retrying in '
          '${delay.inSeconds}s (attempt ${attempt + 1}/$maxAttempts)',
        ),
      );
      _logDiagnostic(
        'transient retry sid=$_logSid attempt=${attempt + 1}/$maxAttempts '
        'reason=$reason',
      );
    };
  }

  Future<void> run() async {
    await _loadAgentContext();
    _session = await _initializeSession();
    _syncMailboxPrefix();
    // Boot marker: every wedge post-mortem starts with "which BUILD held
    // the busy row?" — parallel fa processes share this log, so name the
    // version next to the session id before any lifecycle line.
    _logDiagnostic('fa boot sid=$_logSid version=$_version');
    _wireTransientRetryNotice();
    // Live-session presence: this process now owns the session — the Fa
    // app (sharing the sessions root) marks it live and can attach. The
    // heartbeat refreshes on the inbox timer; unregistering happens in
    // the finally below (crash coverage is the staleness window).
    final presence = config.presenceStore;
    final sessionId = _session?.cachedId;
    if (presence != null && sessionId != null) {
      await presence.register(sessionId, pid: config.processId);
    }
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
    // Due scheduled messages (schedule_message): re-arm any pending records
    // from previous runs — restart-survivable reminders.
    unawaited(_scheduledMessages.start());
    final interruptSub = io.interrupts.listen((_) {
      if (isBusy) _agent.abort();
    });
    final taskSub = _taskConfig.jobManager.completions.listen(
      _onTaskJobCompleted,
    );
    // The inbox watcher: incoming inter-agent mail while IDLE wakes the
    // agent into a turn (mid-run mail is delivered by the steering poll).
    // The same tick refreshes the presence heartbeat (every other tick ≈
    // 4s, well inside the 15s staleness window).
    var heartbeatTick = 0;
    final inboxTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_wakeOnInboxMail());
      if (heartbeatTick++ % 2 == 0) {
        if (presence != null && sessionId != null) {
          unawaited(presence.touch(sessionId));
        }
        // The messaging-fabric heartbeat: agent_directory reports this
        // instance as live even when no mail is pending.
        _touchFabricHeartbeat();
      }
    });
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
      // Live-session presence off: the session stops being "running in
      // the CLI" for app viewers.
      if (presence != null && sessionId != null) {
        await presence.unregister(sessionId);
      }
      // A session nobody wrote to leaves no file behind.
      await deleteSessionIfEmpty();
    }
    await printSessionResumeHint();
  }

  /// Loads prompt templates, skills, and project context files, then applies
  /// the prompt composition. Third-party (Claude/Copilot/Codex) roots are
  /// gated behind the user's consent ([AgentCliConfig.skillsAccess]); while
  /// access is not granted their presence is still detected (directory
  /// metadata only) to drive the startup consent dialog / hint.
  Future<void> _loadAgentContext() async {
    _templates = await loadPromptTemplates(_env, config.promptTemplateDirs);
    final roots = defaultSkillRoots(cwd: _env.cwd, homeDir: config.homeDir);
    _skills = await discoverSkills(
      _env,
      projectRoots: roots.projectRoots,
      userRoots: roots.userRoots,
      allowedSources: _skillsAllowedSources,
    );
    _thirdPartySkillDirsPresent = await _detectThirdPartySkillDirs();
    // Line mode / headless: this print is visible as-is. TUI: the terminal
    // is not ours yet — the alternate screen would wipe this line, so
    // `_runTuiRepl` re-prints the hint right after the banner.
    _printThirdPartySkillsDisabledHint();
    _contextFiles = await loadProjectContextFiles(
      _env,
      userFile: config.homeDir == null
          ? null
          : '${config.homeDir}/.fah/AGENTS.md',
    );
    _applyPromptComposition();
    // Durable facts from past sessions join the prompt asynchronously
    // (memory stores initialize lazily; recompose on arrival).
    unawaited(_refreshMemorySection());
  }

  /// The line-mode REPL: banner, restored-session replay, then the
  /// read-dispatch loop.
  Future<void> _runLineRepl() async {
    await _printBanner();
    final resumedLabel = await _resumedSessionLabel();
    if (resumedLabel != null) {
      _replayRestoredHistory(_agent.state.messages, resumedLabel);
    }
    // One-time consent question for third-party skill roots: reads answers
    // straight from the line stream (the dispatch loop is not running yet).
    final lineIterator = StreamIterator<String>(io.lines);
    await _maybePromptSkillsAccess(lineIterator: lineIterator);
    _writeIdlePrompt();
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
    final hint = await sessionResumeHint();
    if (hint != null) io.writeln(_style.dim(hint));
  }

  /// The `fa --session …` resume line, or null when nothing was persisted.
  /// Separate from [printSessionResumeHint] so non-REPL callers (the SIGINT
  /// exit path) can print it to the REAL stdout after the TUI is gone —
  /// routing through [io] there would write into a dead transcript.
  Future<String?> sessionResumeHint() async {
    final session = _session;
    if (session == null || _persistedCount == 0) return null;
    final name = await session.getSessionName();
    final id = name ?? (await session.getMetadata()).id;
    return "resume this session with: fa --session '$id'";
  }

  /// Resolves when the in-flight run settles, bounded by [timeout] so an
  /// exit path (SIGINT) can never wedge on a stuck provider — a partial
  /// transcript is still persisted by the run's own error/abort handling.
  Future<void> waitForIdle({Duration timeout = const Duration(seconds: 5)}) {
    return _settled.timeout(timeout, onTimeout: () {});
  }

  /// Deletes the active session's file when nothing was ever said in it:
  /// opening the CLI and leaving (or only poking slash commands) must not
  /// litter the sessions list with empty files. Best-effort - exit and
  /// session switching never fail on it. A session that owns subagents is
  /// NOT empty: its `subagent_registry` record is real content. A session
  /// that already has persisted records (e.g. a user message saved before a
  /// run that was interrupted) is also kept.
  Future<void> deleteSessionIfEmpty() async {
    if (_agent.state.messages.isNotEmpty) return;
    if (_persistedCount > 0) return;
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
    // Busy-row forensics: every arm/release/drop/watchdog-fire lands in
    // fa.log with its source — a wedged "Working…" names its owner.
    faTuiBusyDiagnostics = _logDiagnostic;
    final controller = _createTuiController();
    _tuiController = controller;
    _setTuiIo(controller);

    // The banner is part of the TUI output history so it stays visible above
    // the input line inside the alternate screen.
    await _printBanner();
    // The first _loadAgentContext() ran before the TUI owned the terminal —
    // its "found but disabled" hint never reached the transcript. Re-print.
    _printThirdPartySkillsDisabledHint();
    await _replayRestoredSession();

    // Warm the model cache in the background so the first /models picker is
    // fast; failures are silent and the cache falls back to the hardcoded list.
    unawaited(_refreshModelCache());

    // One-time consent question for third-party skill roots: a TUI picker
    // over the first frame (Esc = "Not now", asked again next launch).
    unawaited(_maybePromptSkillsAccess());

    // An ambiguous `--session <name>` (same name in several folders or
    // several in one): the scoped choice picker over the first frame —
    // the auto-resolved session stays when dismissed.
    unawaited(_offerStartupSessionChoice());

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
    controller.sendBusy(true, source: 'submit');
    try {
      await _handleLine(line);
      // Runs are fire-and-forget (_startRun only records the future):
      // wait for the run to actually settle so the busy spinner lives
      // for the whole stream instead of flashing for one frame.
      await _settled;
      await _drainTuiQueue(controller);
    } finally {
      _abortRequested = false;
      controller.sendBusy(false, source: 'submit');
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
    skills: _skills,
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
    // Step 2 of the two-step model pick: rows are keyed `provider|model`,
    // the same shape the flat model menu selects.
    'modelProvider': _tuiSelectModel,
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
      // List every session in the shared root, across all workspaces, so a
      // session created in the Fa app or in another `fa` run is reachable.
      sessions = await _repo.list();
    } on Object catch (error) {
      // A failing store must surface as an inline error, never kill the TUI
      // (a Cmd exception in dart_tui terminates the whole program silently).
      io.writeln(_errorLine('failed to list sessions: $error'));
      return;
    }
    if (sessions.isEmpty) {
      io.writeln('no sessions');
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
  /// session. Kept shallow so the CRAP score stays low without a TUI
  /// picker test harness.
  Future<MenuItem> _sessionPickerItem(
    int i,
    SessionMetadata metadata,
    SessionMetadata? current,
  ) async {
    final label = await _sessionPickerLabel(metadata);
    final description = _sessionPickerDescription(metadata, current);
    return MenuItem(
      key: '$i',
      label: '${i + 1}) $label',
      description: description,
    );
  }

  /// Readable label for a session, degrading gracefully when the file is
  /// unreadable.
  Future<String> _sessionPickerLabel(SessionMetadata metadata) async {
    try {
      final session = await _repo.open(metadata);
      return await session.getSessionName() ?? metadata.id;
    } on Object {
      return '${metadata.id} (unreadable)';
    }
  }

  /// Folder + last-update timestamp description for a sessions-picker row,
  /// marking the active session.
  String _sessionPickerDescription(
    SessionMetadata metadata,
    SessionMetadata? current,
  ) {
    final marker = current?.path == metadata.path ? ' (current)' : '';
    final folder = _pathBasename(metadata.cwd);
    final timestamp = (metadata.lastUpdatedAt ?? metadata.createdAt)
        .toLocal()
        .toIso8601String();
    return folder.isEmpty ? '$timestamp$marker' : '$folder · $timestamp$marker';
  }

  /// Last non-empty path segment, with a fallback for the filesystem root.
  String _pathBasename(String path) {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
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
      'yolo': 'auto-approve everything (critical bash still prompts)',
      'unattended':
          'auto-approve everything, never asks — for runs without a user',
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
      final matches = await _sessionNameMatches(name);
      final metadata = _resolveSessionNameMatch(
        matches,
        onAmbiguous: (all) {
          // Interactive prompting is impossible this early (the input pump
          // starts after init): auto-resolve and let the TUI offer the
          // scoped picker after boot; line mode gets the printed hint.
          _startupAmbiguousSessions = all;
          _startupAmbiguousName = name;
        },
      );
      if (metadata != null) {
        if (matches.length > 1) {
          io.writeln(
            _style.dim(
              "note: ${matches.length} sessions named '$name' — opened "
              '${metadata.id} (${metadata.cwd}); pick another with '
              '/sessions or restart with fa --session <id>',
            ),
          );
        }
        return _loadSession(metadata);
      }
      return _createSession(name: name);
    }
    return _createSession();
  }

  Future<Session> _createSession({String? name}) async {
    try {
      final session = await _repo.create(
        JsonlSessionCreateOptions(
          cwd: _env.cwd,
          // `agent: cli` marks the owning process — the Fa app's live badge
          // and attach view key off presence, but the metadata tells
          // sessions apart in listings (the app writes 'fa').
          metadata: {'agent': 'cli', 'model': _agent.state.model.id},
        ),
      );
      if (name != null && name.isNotEmpty) {
        await session.appendSessionName(name);
      }
      return session;
    } on SessionException catch (error) {
      final fallbackRoot = '${config.homeDir ?? _env.cwd}/.fah/sessions';
      if (config.sessionRoot != fallbackRoot) {
        try {
          final fallbackRepo = JsonlSessionRepo(
            fs: _env,
            sessionsRoot: fallbackRoot,
          );
          final session = await fallbackRepo.create(
            JsonlSessionCreateOptions(
              cwd: _env.cwd,
              metadata: {'agent': 'cli', 'model': _agent.state.model.id},
            ),
          );
          _repo = fallbackRepo;
          // Storage moved — the mailboxes move with it. Without this the
          // fabric keeps pointing at the failed root: presence/register
          // throws, and an attached app's messages land where this process
          // never looks (the silent-dead-attach bug).
          _fabricRepository.swap(
            FileMessagingRepository(
              env: _env,
              root: '$fallbackRoot/${encodeSessionCwd(_env.cwd)}/messages',
              decodeSessionCwd: decodeSessionCwd,
              homeDir: config.homeDir,
            ),
          );
          if (name != null && name.isNotEmpty) {
            await session.appendSessionName(name);
          }
          io.writeln(
            _style.yellow(
              'warning: Failed to create session under ${config.sessionRoot} (${error.message}).\n'
              'Falling back to session storage at $fallbackRoot.\n'
              'To fix permissions for shared macOS sessions, run:\n'
              '  sudo chown -R \$(whoami) ~/Library/"Group Containers"/group.dev.fa1.shared\n'
              '  chmod -R u+rwx ~/Library/"Group Containers"/group.dev.fa1.shared',
            ),
          );
          return session;
        } catch (_) {
          // Fall through to rethrow original error.
        }
      }
      rethrow;
    }
  }

  /// Every session whose id IS [name] (exact id short-circuits — ids are
  /// unique) or whose session_info name equals it, across every workspace
  /// (the exit hint prints `fa --session '<id>'` for unnamed sessions, so
  /// ids must resolve too). Several sessions can share a NAME — different
  /// project folders, or renamed twice — so callers get the full list and
  /// disambiguate (see [_resolveSessionNameMatch]).
  Future<List<SessionMetadata>> _sessionNameMatches(String name) async {
    final sessions = await _repo.list();
    final matches = <SessionMetadata>[];
    for (final metadata in sessions) {
      if (metadata.id == name.trim()) return [metadata];
      final session = await _repo.open(metadata);
      final sessionName = await session.getSessionName();
      if (sessionName != null && sessionName.trim() == name.trim()) {
        matches.add(metadata);
      }
    }
    return matches;
  }

  /// Finds a session by display name OR exact id — the first match. Kept
  /// for the rename-conflict check ("the name is taken anywhere").
  Future<SessionMetadata?> _findSessionByName(String name) async {
    final matches = await _sessionNameMatches(name);
    return matches.isEmpty ? null : matches.first;
  }

  /// Disambiguates same-named sessions: the LAUNCH folder's session beats a
  /// namesake from another project (the "fa --session X opens the wrong
  /// folder's session" bug); a clear single local wins silently, anything
  /// else is ambiguous and [onAmbiguous] receives the full match list so
  /// the caller can offer a choice. The fallback pick is the most recently
  /// updated local (or global when the folder has none).
  SessionMetadata? _resolveSessionNameMatch(
    List<SessionMetadata> matches, {
    void Function(List<SessionMetadata> matches)? onAmbiguous,
  }) {
    if (matches.isEmpty) return null;
    if (matches.length == 1) return matches.single;
    final local = [
      for (final m in matches)
        if (m.cwd == _env.cwd) m,
    ];
    if (local.length == 1) return local.single;
    onAmbiguous?.call(matches);
    final pool = local.isNotEmpty ? local : matches;
    pool.sort(
      (a, b) => (b.lastUpdatedAt ?? b.createdAt).compareTo(
        a.lastUpdatedAt ?? a.createdAt,
      ),
    );
    return pool.first;
  }

  /// Same-named matches pending a startup choice: set when `--session X`
  /// resolved ambiguously, consumed by [_runTuiRepl] to offer the sessions
  /// picker scoped to these matches once the TUI owns the screen.
  List<SessionMetadata>? _startupAmbiguousSessions;
  String? _startupAmbiguousName;

  /// Offers the startup ambiguity choice: the sessions picker scoped to
  /// the same-named matches. The current session stays the auto-resolved
  /// one; picking another switches, Esc keeps it.
  Future<void> _offerStartupSessionChoice() async {
    final matches = _startupAmbiguousSessions;
    final name = _startupAmbiguousName;
    _startupAmbiguousSessions = null;
    _startupAmbiguousName = null;
    if (matches == null || name == null) return;
    _lastSessionList = matches;
    _tuiController?.openPicker(
      'sessions',
      "Several sessions named '$name' — which one?",
      await _sessionPickerItems(matches),
    );
  }

  Future<Session> _loadSession(SessionMetadata metadata) async {
    final session = await _repo.open(metadata);
    final messages = await session.buildContextMessages();
    // Loaded usage anchors are generation-time: post-compaction they
    // phantom-report the pre-compaction size (183k on a 27k branch) and
    // fire a no-op compaction on every resume. Re-anchor at chars/4.
    _agent.state.messages = resetLoadedUsageAnchors(messages);
    _persistedCount = messages.length;
    // Adopt the session's original project folder. This matters both when
    // switching mid-run and when the CLI starts with --session: tools like
    // bash/read/edit must operate in the session's directory, not the launch
    // directory.
    if (_env.cwd != metadata.cwd) {
      _env.cwd = metadata.cwd;
      _modes = builtInAgentModes(_env.cwd, overrides: config.promptOverrides);
      _currentMode = _modes[_currentMode.name] ?? _modes['code']!;
      await _loadAgentContext();
    }
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

  /// Runs a single non-interactive prompt (headless mode: `fah "<prompt>"`)
  /// and returns the process exit code: 0 on success, 1 when the run ends
  /// with a provider error, 130 when aborted (Ctrl-C via [CliIO.interrupts]).
  /// Tool errors the agent recovers from still exit 0 — the exit code
  /// reflects the run's terminal state, like claude/pi.
  ///
  /// Unlike [run] there is no banner, no input prompt, no slash-command
  /// handling, and no steering; the session persists exactly like a REPL
  /// turn (including auto-compaction). The host's [CliIO] should be
  /// non-interactive and route [CliIO.writeln] diagnostics to stderr so
  /// [CliIO.write] (the assistant text) is the only stdout content.
  Future<int> runHeadless(String prompt) async {
    _session = await _initializeSession();
    // Warm the endpoint metadata (model list, dial features, reported
    // limits) BEFORE the first turn; failures are silent — the catalog
    // defaults keep applying.
    try {
      await _refreshModelCache();
    } on Object {
      // Swallowed: see _refreshModelCache.
    }
    // The same pre-flight compaction guard as the REPL's [_runPrompt]:
    // a resumed session already over the threshold must compact BEFORE
    // the first request, or it goes out over-window and gets rejected.
    await _maybeAutoCompact();
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
    io.writeln('  ${_env.cwd}');
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
    // A new user message ends the previous turn: per-turn skill tool grants
    // (`allowed-tools`) do not leak into it. The skill path re-grants after
    // this clear (it goes through `/skill:` / the slash alias above).
    _approval.clearTurnGrants();
    _startRun(line);
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
    // Mark the run in flight SYNCHRONOUSLY: pre-flight compaction awaits
    // before the first streamed byte, and isBusy readers (inbox watcher,
    // shell-job settle, steer-vs-start) must not start a parallel run here.
    _runStarting = true;
    // Busy bracket HERE, not in the TUI submit handler: every run trigger
    // (submit, inbox wake, shell-job settle, scheduled message) must spin,
    // and an unbracketed trigger leaves the spinner on after the run
    // settles (the "Working… forever with an idle agent" wedge). The
    // counter is reference-counted, so the submit handler's own bracket
    // nests safely.
    _tuiController?.sendBusy(true, source: 'run');
    // Path-gated skills (`paths:` frontmatter) join the prompt once the
    // agent has touched a matching file; recomposing here is idempotent.
    _applyPromptComposition();
    // A pasted file path becomes an explicit [attached file: …] reference —
    // the model is told there is a file and decides itself whether and how
    // much to read (content is never inlined: paste size is unknown).
    final resolved = resolveInteractiveFileReference(text);
    if (resolved != text) {
      io.writeln(_style.dim('[file] pasted path attached for the agent'));
    }
    final settled = _runPrompt(resolved);
    _settled = settled;
    unawaited(
      settled.whenComplete(() {
        _tuiController?.sendBusy(false, source: 'run');
        _runStarting = false;
        if (!_exited) _writeIdlePrompt();
      }),
    );
  }

  /// Runs one user prompt to completion. On a CodeMie auth-session expiry,
  /// opens the browser SSO flow to refresh the token automatically. Other
  /// provider errors are printed through [_errorLine]. An empty assistant
  /// message (no text, no tool calls) is retried once with 'continue'.
  Future<void> _runPrompt(String text, {bool isAutoContinue = false}) async {
    // Pre-flight context guard: when the LIVE context already exceeds the
    // compaction threshold, compact BEFORE sending the request — a failed
    // post-run compaction (quota-limited smol role, provider outage) used to
    // leave every request carrying an over-window payload (ctx 240% gauge).
    if (!isAutoContinue) await _maybeAutoCompact();
    try {
      await _agent.prompt(text);

      final lastMessage = _agent.state.messages.lastOrNull;
      if (lastMessage is AssistantMessage &&
          lastMessage.stopReason == StopReason.error) {
        if (await _maybeHandleCodeMieError(lastMessage.errorMessage ?? '')) {
          return;
        }
      }

      if (!isAutoContinue &&
          lastMessage is AssistantMessage &&
          lastMessage.stopReason != StopReason.error &&
          lastMessage.stopReason != StopReason.aborted &&
          _assistantMessageIsEmpty(lastMessage)) {
        await _runPrompt('continue', isAutoContinue: true);
        return;
      }

      await _afterRun();
    } catch (error) {
      await _handleRunError(error);
    }
  }

  /// Persists a single message as soon as the agent adds it to the transcript.
  /// Keeps [_persistedCount] aligned so [_afterRun] only writes anything the
  /// listener may have missed (e.g. a crash between the append and the await).
  Future<void> _persistIncremental(AgentEvent event) async {
    if (event is! MessageEndEvent) return;
    final message = event.message;
    // Aborted assistant streams are incomplete; TTSR's discard mode prunes
    // them from memory and they should not survive in the session either.
    if (message is AssistantMessage &&
        message.stopReason == StopReason.aborted) {
      return;
    }
    final session = _session;
    if (session == null) return;
    final messages = _agent.state.messages;
    if (_persistedCount >= messages.length) return;
    await session.appendMessage(message);
    _persistedCount++;
  }

  /// Handles a CodeMie auth-session expiry if [message] matches one. Returns
  /// `true` when the expiry was handled and the turn is finished.
  Future<bool> _maybeHandleCodeMieError(String message) async {
    if (authExpiredProvider(message) != 'codemie') return false;
    await _handleCodeMieAuthExpired(message);
    return true;
  }

  /// Handles provider/runtime errors thrown outside the assistant stream.
  Future<void> _handleRunError(Object error) async {
    final message = '$error';
    if (await _maybeHandleCodeMieError(message)) return;
    io.writeln(_errorLine(message));
  }

  /// Whether the assistant message produced nothing actionable: no non-empty
  /// text content and no tool calls.
  bool _assistantMessageIsEmpty(AssistantMessage message) {
    final hasText = message.content.any(
      (c) => c is TextContent && c.text.trim().isNotEmpty,
    );
    final hasToolCalls = message.content.any((c) => c is ToolCall);
    return !hasText && !hasToolCalls;
  }

  /// Shared handler for a detected CodeMie auth-session expiry: strips the
  /// machine marker, prints a short error, launches the browser SSO flow, and
  /// tells the user to repeat the message.
  Future<void> _handleCodeMieAuthExpired(String rawMessage) async {
    final stripped = stripAuthExpiredMarker(compactProviderError(rawMessage));
    io.writeln(_style.red('error: $stripped'));
    io.writeln(
      _style.yellow(
        'CodeMie session expired — opening browser to re-authorize...',
      ),
    );
    final orgUrl = codeMieOrgUrl(_agent.state.model.baseUrl);
    await _handleCodeMieSsoCommand(orgUrl);
    if (!_exited) {
      io.writeln(
        _style.green('Re-authorized. Repeat your message to continue.'),
      );
    }
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

  /// Called at most once per session when a background-job log with the old
  /// pre-unique-id name (`sh-<n>.log`) is written after this process booted
  /// (see [ShellJobRegistry.onStaleJobLog]): another fa on an OLDER build is
  /// running in this directory and can interleave output into shared files.
  /// Surfaced loudly — this exact skew silently poisoned tool output for a
  /// whole day before anyone found it.
  void _onStaleJobLog(String path) {
    final name = path.split('/').last;
    io.writeln(
      _style.yellow(
        'warning: $name was just written by an older fa build also running '
        'in this directory — its output can interleave with stale job logs. '
        'Restart that fa instance on this binary to fix.',
      ),
    );
    _logDiagnostic('stale old-format job log detected: $path');
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
  /// and is delivered at the next real turn). User-kind messages reset the
  /// streak when delivered: they ARE the user talking, so an attach-driven
  /// session never exhausts the cap.
  var _inboxWakeStreak = 0;
  static const _maxInboxWakeStreak = 10;

  /// Test seam: observe/reset the inbox-wake streak without driving ten
  /// real runs (the cap is exactly [_maxInboxWakeStreak]).
  @visibleForTesting
  int get inboxWakeStreakForTest => _inboxWakeStreak;
  @visibleForTesting
  set inboxWakeStreakForTest(int value) => _inboxWakeStreak = value;

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
    _tuiController?.setBusyPhase('Compacting context…');
    _logDiagnostic('auto-compact start sid=$_logSid tokens=$tokens');
    await _runAutoCompact('[auto-compacted]');
    // Hand the busy row back to the run: a stale 'Compacting context…'
    // over the streamed turn reads as a compaction hang.
    _tuiController?.setBusyPhase('');
  }

  /// `/compact` manual override: same AutoCompactor pipeline as the
  /// auto-trigger, but unconditional — honours the user's explicit ask
  /// even when the threshold isn't crossed.
  Future<void> _runManualCompact() async {
    final session = _session;
    if (session == null) return;
    if (_agent.state.messages.isEmpty) {
      io.writeln('nothing to compact');
      return;
    }
    _tuiController?.setBusyPhase('Compacting context…');
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
        final tui = _tuiController;
        tui?.setBusyPhase('Extracting memory…');
        // Best-effort and BOUNDED: a wedged smol endpoint used to keep the
        // phase label up for the whole role-chain retry ladder (minutes
        // per pass — the "Extracting memory… 1025s" stall). Cancel the
        // extraction stream after the deadline, hard-cap the wait anyway,
        // and restore the compaction phase label either way. A timeout
        // skips extraction for this pass only — never the compaction.
        final source = CancelTokenSource();
        final deadline = Timer(_memoryExtractionDeadline, source.cancel);
        try {
          final hook = compactionMemoryHook(
            memory: _memory,
            stream: smol?.stream ?? _streamFunction,
            model: smol?.model ?? _agent.state.model,
            cancelToken: source.token,
          );
          if (hook != null) {
            await hook(text).timeout(_memoryExtractionHardCap);
          }
        } on TimeoutException {
          _logDiagnostic(
            'memory extraction skipped: exceeded '
            '${_memoryExtractionHardCap.inSeconds}s hard cap',
          );
        } finally {
          deadline.cancel();
          tui?.setBusyPhase('Compacting context…');
        }
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

  /// Short session id for diagnostic log lines: parallel fa processes share
  /// one fa.log, so every lifecycle line names its session (post-mortem
  /// "who held the busy row" starts here).
  String get _logSid {
    final id = _session?.cachedId;
    if (id == null || id.isEmpty) return '-';
    return id.length <= 8 ? id : id.substring(0, 8);
  }

  /// Appends one timestamped [message] to [path], creating the log directory
  /// on first use. Isolated from [_logDiagnostic] so the public entry point
  /// stays small.
  Future<void> _appendDiagnosticLog(String path, String message) async {
    final line = '${DateTime.now().toIso8601String()} $message\n';
    try {
      if (!_diagnosticLogDirEnsured) {
        _diagnosticLogDirEnsured = true;
        await _env.createDir('${config.homeDir}/.fah/logs', recursive: true);
      }
      await _env.appendFile(path, line);
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
    if (command == '/skills') {
      await _skillsSlash(rest);
      return true;
    }
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

  /// `/exit`, `/help`, `/stats`, `/tasks`.
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
      case '/providers':
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
    // Claude/Copilot-style slash alias: `/<skill-name> [args]` invokes the
    // skill directly (user-invocable skills only).
    final alias = _skills
        .where(
          (s) =>
              s.userInvocable &&
              s.name.toLowerCase() == command.substring(1).toLowerCase(),
        )
        .firstOrNull;
    if (alias != null) {
      await _runSkillCommand('${alias.name}${rest.isEmpty ? '' : ' $rest'}');
      return;
    }
    // Unknown slash command: treat it as a filter for the command menu.
    // A string starting with `/` followed by no spaces and containing at
    // least one more `/` is a filesystem path (absolute or `~/...`),
    // never a slash command. When the referenced file EXISTS, the message
    // is sent with the file attached (resolveInteractiveFileReference);
    // a nonexistent path keeps the load hint — it cannot be attached.
    if (trimmed.startsWith('/') && trimmed.length > 1) {
      final looksAbsolutePath =
          RegExp(r'^/[^/\s]*\/').hasMatch(trimmed) || trimmed.startsWith('~/');
      if (looksAbsolutePath) {
        if (resolveInteractiveFileReference(trimmed) != trimmed) {
          _startRun(trimmed);
          return;
        }
        io.writeln(
          'looks like a filesystem path, not a command — '
          'paste the contents (e.g. `cat ${trimmed.split(' ').first}`), '
          'or use `@${trimmed.split(' ').first}` to load it as context.',
        );
        return;
      }
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
