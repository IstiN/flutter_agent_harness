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

import 'ansi_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import '../agent/agent.dart';
import 'agent_event_handler.dart';
import 'headless_prompt.dart';
import 'key_event.dart';
import 'key_status.dart';
import 'provider_error_text.dart';
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
import '../cube/cube.dart';
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
import 'cli_config.dart';
import 'custom_providers.dart';
import 'folder_model_state.dart';
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
part 'agent_cli_cube.dart';
part 'agent_cli_provider_presets.dart';
part 'agent_cli_inbox.dart';
part 'agent_cli_io.dart';
part 'agent_cli_banner.dart';
part 'agent_cli_commands.dart';

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
      // Runtime config freshness: every memory op re-reads the `memory:`
      // section (project .fah/config.yaml wins over the user one — the
      // same merge as boot), so deciding to save memory in the project
      // takes effect without a restart.
      configSource: () async => _liveMemoryConfig(),
      onConfigChanged: () => unawaited(_refreshMemorySection()),
      // Semantic search + consolidate() need an LLM: memory → smol → main.
      llmProvider: HarnessLlmProvider(resolve: () => _resolveMemoryLlmSlot()),
    );

    // fa_cube sandbox: fs ops route through the fs guard and shell ops
    // through the policy engine while a spec is active; a null spec boots
    // the env in passthrough mode (`/cube use` swaps one in later). Sits
    // INSIDE session vars so session vars merge after the cube clamp.
    _cubeEnv = SandboxedExecutionEnv(
      _env,
      config.cubeSpec,
      homeDir: config.homeDir,
      workspaceRoot: _env.cwd,
      os: config.osName,
    );
    _cubeSource = config.cubeSource;
    final decoratedEnv = SessionVarsExecutionEnv(_cubeEnv, _sessionEnvVars);
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
  Future<void> removeProvider(CustomProviderEntry entry) async {
    final registry = config.customProviders;
    if (registry == null) return;
    registry.entries.removeWhere((e) => e.name == entry.name);
    if (_activeCustomName == entry.name) _activeCustomName = null;
    io.writeln('deleted provider ${entry.name}');
    await config.onProviderChanged?.call(_providerKind, _apiKey);
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
  void recordCustomModelForTest(String modelId) {
    unawaited(_recordCustomModel(modelId));
  }

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

  /// The sandboxed view over [_env]: clamps filesystem and shell operations
  /// to the active cube (`null` = passthrough). `/cube` manages it live.
  late final SandboxedExecutionEnv _cubeEnv;

  /// Where the active cube came from — a manifest path or a cube name;
  /// `/cube reload` re-resolves it. Set at boot (config) and by
  /// `/cube use`; never cleared by `/cube off` (a reload re-applies it).
  String? _cubeSource;

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
  /// The runtime `memory:` section (project `.fah/config.yaml` wins over
  /// the user-level one — the same merge as boot). Re-read on every
  /// memory operation by the controller's configSource; a broken file
  /// keeps the last good config (the controller swallows source errors).
  MemoryConfig? _liveMemoryConfig() {
    final project = loadProjectMemoryConfig(_env.cwd);
    if (project != null) return project;
    final home = config.homeDir;
    return home == null ? null : loadCliConfig(home).memory;
  }

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
    await _cubeBootRestore();
    await _loadAgentContext();
    _session = await _initializeSession();
    _syncMailboxPrefix();
    // Boot marker: every wedge post-mortem starts with "which BUILD held
    // the busy row?" — parallel fa processes share this log, so name the
    // version next to the session id before any lifecycle line.
    _logDiagnostic('fa boot sid=$_logSid version=$_version');
    _wireTransientRetryNotice();
    final presence = await _registerLivePresence();
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
      if (isBusy) {
        // Line-mode abort marker: the settle path uses it to DROP the
        // leftover steering loudly instead of re-running it (the TUI sets
        // the same flag in its onInterrupt and resets it in its submit
        // finally).
        _abortRequested = true;
        _agent.abort();
      }
    });
    final taskSub = _taskConfig.jobManager.completions.listen(
      _onTaskJobCompleted,
    );
    final inboxTimer = _startInboxWatcher(presence);
    try {
      if (_useTui) {
        // The TUI prints the banner itself into its output history (buffered
        // by the controller until the program's event loop is listening).
        await _runTuiRepl();
      } else {
        await _runLineRepl();
      }
    } finally {
      await _teardownAfterRepl(interruptSub, taskSub, inboxTimer, presence);
    }
    await printSessionResumeHint();
  }

  /// Cube cache restore before the first turn — best-effort (one warning
  /// line on failure, never a blocker).
  Future<void> _cubeBootRestore() async {
    final bootSpec = _cubeEnv.activeSpec;
    if (bootSpec != null) await _cubeRestoreQuietly(bootSpec);
  }

  /// Live-session presence: this process now owns the session — the Fa
  /// app (sharing the sessions root) marks it live and can attach. The
  /// heartbeat refreshes on the inbox timer; unregistering happens in
  /// [_teardownAfterRepl] (crash coverage is the staleness window).
  Future<({SessionPresenceStore store, String sessionId})?>
  _registerLivePresence() async {
    final store = config.presenceStore;
    final sessionId = _session?.cachedId;
    if (store != null && sessionId != null) {
      await store.register(sessionId, pid: config.processId);
      return (store: store, sessionId: sessionId);
    }
    return null;
  }

  /// The inbox watcher: incoming inter-agent mail while IDLE wakes the
  /// agent into a turn (mid-run mail is delivered by the steering poll).
  /// The same tick refreshes the presence heartbeat (every other tick ≈
  /// 4s, well inside the 15s staleness window).
  Timer _startInboxWatcher(
    ({SessionPresenceStore store, String sessionId})? presence,
  ) {
    var heartbeatTick = 0;
    return Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_wakeOnInboxMail());
      if (heartbeatTick++ % 2 == 0) {
        if (presence != null) {
          unawaited(presence.store.touch(presence.sessionId));
        }
        // The messaging-fabric heartbeat: agent_directory reports this
        // instance as live even when no mail is pending.
        _touchFabricHeartbeat();
      }
    });
  }

  /// Input ended (EOF) or the REPL is shutting down: never leave a tool
  /// call waiting on an answer that cannot arrive.
  Future<void> _teardownAfterRepl(
    StreamSubscription<dynamic> interruptSub,
    StreamSubscription<dynamic> taskSub,
    Timer inboxTimer,
    ({SessionPresenceStore store, String sessionId})? presence,
  ) async {
    _cancelPendingAnswers();
    final exitSpec = _cubeEnv.activeSpec;
    if (exitSpec != null) {
      try {
        await CubeCacheManager(_cubeEnv, exitSpec).save();
      } on Object catch (error) {
        io.writeln('cube: cache save failed: $error');
      }
    }
    await interruptSub.cancel();
    await taskSub.cancel();
    inboxTimer.cancel();
    await _settled;
    // Live-session presence off: the session stops being "running in
    // the CLI" for app viewers.
    if (presence != null) {
      await presence.store.unregister(presence.sessionId);
    }
    // A session nobody wrote to leaves no file behind.
    await deleteSessionIfEmpty();
  }

  /// Warm the endpoint metadata (model list, dial features, reported
  /// limits) BEFORE the first turn; failures are silent — the catalog
  /// defaults keep applying.
  Future<void> _warmModelCacheQuietly() async {
    try {
      await _refreshModelCache();
    } on Object {
      // Swallowed: see _refreshModelCache.
    }
  }

  /// Cube cache save mirroring [run]'s exit path (best-effort).
  Future<void> _cubeCacheSaveQuietly() async {
    final exitSpec = _cubeEnv.activeSpec;
    if (exitSpec != null) {
      try {
        await CubeCacheManager(_cubeEnv, exitSpec).save();
      } on Object catch (error) {
        io.writeln('cube: cache save failed: $error');
      }
    }
  }

  /// Background jobs (kimi's print-mode): don't exit while agents are in
  /// flight. Settled jobs inject async-result messages through the
  /// listener (re-wake runs), so loop until every job is terminal and
  /// those reaction runs settle too (capped like kimi's drain limit).
  Future<void> _awaitHeadlessBackgroundJobs() async {
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
    // Warm the model cache here too (the TUI path does): the endpoint-
    // reported context window lands on the active model only through this
    // refresh, and line-mode `/model <id>` switches read the same map.
    unawaited(_refreshModelCache());
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
      // A fresh user line clears the abort marker: the settle path already
      // dropped (or ran) the interrupted run's leftover steering.
      _abortRequested = false;
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
      _steerResolved(message);
    }
  }

  /// Whether [trimmed] names an existing file with its first token
  /// (`/abs/path`, `~/…`, `./…`, `../…` + more path segments): such a
  /// line is an attachment message, never a slash command.
  bool _isAttachableFileInput(String trimmed) {
    final pathLike =
        _leadingPathLike.hasMatch(trimmed) ||
        trimmed.startsWith('~/') ||
        trimmed.startsWith('./') ||
        trimmed.startsWith('../');
    if (!pathLike) return false;
    return resolveInteractiveFileReference(trimmed) != trimmed;
  }

  /// Steers [trimmed] into the running agent with the file-reference
  /// resolution applied (a pasted path becomes an explicit
  /// `[attached file: …]` marker — a bare path steered as plain text made
  /// the model miss the attachment entirely).
  void _steerResolved(String trimmed) {
    final resolved = resolveInteractiveFileReference(trimmed);
    if (resolved != trimmed) {
      io.writeln(_style.dim('[file] attached to steered message'));
    }
    _agent.steer(UserMessage.text(resolved));
  }

  /// Runs or loudly drops the steering messages still queued after a run
  /// settled (they missed every drain point: raced past the last poll, or
  /// the run was interrupted). Running keeps "typed but never answered"
  /// from happening; dropping prints exactly what was discarded — a silent
  /// drop is indistinguishable from a lost message.
  void _settleLeftoverSteering() {
    if (_exited || !_agent.hasSteering) return;
    final outcome = resolveLeftoverSteering(
      drain: _agent.drainSteeringQueue,
      abortRequested: _abortRequested,
    );
    if (outcome == null) return;
    if (outcome.run) {
      io.writeln(
        _style.dim(
          'steering arrived after the last checkpoint — running '
          '${outcome.texts.length} message(s) now',
        ),
      );
      _startRun(outcome.texts.join('\n'));
      return;
    }
    io.writeln(_style.dim('dropped steering message(s) after interrupt:'));
    for (final text in outcome.texts) {
      final elided = text.length <= 80 ? text : '${text.substring(0, 80)}…';
      io.writeln(_style.dim('  • ${elided.replaceAll('\n', ' ')}'));
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
    onDropped: (dropped) {
      io.writeln('queued message(s) dropped:');
      for (final text in dropped) {
        final elided = text.length <= 80 ? text : '${text.substring(0, 80)}…';
        io.writeln('  • ${elided.replaceAll('\n', ' ')}');
      }
    },
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
      io.writeln(
        _keyStatusView.errorLine(
          'failed to open session ${metadata.id}: $error',
          _agent.state.model.baseUrl,
        ),
      );
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
      io.writeln(
        _keyStatusView.errorLine(
          'failed to list sessions: $error',
          _agent.state.model.baseUrl,
        ),
      );
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
    // The session may live in a DIFFERENT folder than the launch cwd: the
    // boot applied the launch folder's model memory, so a session opened
    // across folders landed on the wrong provider (user report: a z.ai
    // session reopened as copilot). Re-apply the session folder's saved
    // triple.
    await _applySessionFolderModelState(session);
    return session;
  }

  /// Re-applies the model/provider triple saved for the CURRENT folder
  /// ([loadFolderModelState]) — the runtime twin of the boot restore in
  /// bin/fah.dart. Best-effort: a stale or broken state file keeps the
  /// current model.
  Future<void> _applySessionFolderModelState(Session session) async {
    if (!config.folderModelStateApplies) return;
    final state = await loadFolderModelState(
      _env,
      sessionsRoot: config.sessionRoot,
      cwd: _env.cwd,
    );
    if (state == null) return;
    final current = _agent.state.model;
    if (current.id == state.modelId && current.baseUrl == state.baseUrl) {
      return; // already on this triple (the boot applied this folder)
    }
    final Model built;
    try {
      built = buildCliDefaultModel(
        state.providerKind,
        modelId: state.modelId,
        baseUrl: state.baseUrl,
      );
    } on ConfigException {
      io.writeln(
        _style.dim(
          'note: saved folder model state is stale '
          '(${state.providerKind}) — keeping ${current.id}',
        ),
      );
      return;
    }
    final spec = catalogProvider(built.provider)!;
    final key = _providerKeyFor(spec, built.baseUrl) ?? '';
    _providerKind = state.providerKind;
    _apiKey = key;
    _explicitToken = false;
    _streamFunction = _catalogStreamFunction(state.providerKind, key);
    _agent.streamFunction = _streamFunction;
    _agent.state.model = built;
    // The cached model list belongs to the previous provider/endpoint.
    _modelCache = const [];
    _modelContextWindows = const {};
    _modelMaxTokens = const {};
    _lastModelList = null;
    unawaited(_refreshModelCache());
    await session.appendModelChange(
      provider: built.provider,
      modelId: built.id,
    );
    io.writeln(
      _style.dim('restored ${built.id} (${built.provider}) from this folder'),
    );
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
    // Cube cache restore, mirroring [run]'s boot (the headless run sees the
    // same cached trees a REPL session would).
    await _cubeBootRestore();
    _session = await _initializeSession();
    await _warmModelCacheQuietly();
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
      await _awaitHeadlessBackgroundJobs();
    } catch (error) {
      io.writeln(
        _keyStatusView.errorLine('$error', _agent.state.model.baseUrl),
      );
      return 1;
    } finally {
      await _cubeCacheSaveQuietly();
      await interruptSub.cancel();
      await taskSub.cancel();
    }
    return switch (_agent.state.messages.lastOrNull) {
      AssistantMessage(stopReason: StopReason.error) => 1,
      AssistantMessage(stopReason: StopReason.aborted) => 130,
      _ => 0,
    };
  }

  /// Key-status and error-line rendering over the live config values; built
  /// per render so `/provider` switches and the active-entry marker stay
  /// current.
  KeyStatusRenderer get _keyStatusView => KeyStatusRenderer(
    rolesDriven: _rolesDriven,
    providerKind: _providerKind,
    explicitToken: _explicitToken,
    activeCustomName: _activeCustomName,
    red: _style.red,
    secureKeys: config.secureKeys,
    customProviders: config.customProviders,
    envVarIsSet: config.envVarIsSet,
    envVarValue: config.envVarValue,
  );

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
      // While a run streams, plain input steers the agent (pi semantics) —
      // but slash and bang commands still execute: /settings, /approval or
      // a quick !shell check must not wait out the stream (user report:
      // settings were unreachable mid-run; the line was steered as chat
      // text instead). Run-starting commands are refused by _startRun's
      // busy guard below.
      if (trimmed.startsWith('/') || trimmed.startsWith('!')) {
        // EXCEPT a leading file path: a message that begins with an
        // existing file is chat with an attachment, not a command. It used
        // to reach the command dispatcher, fall through to _startRun, and
        // die on the busy guard — silently dropped (user report:
        // "messages that start with a file go straight into the session
        // or vanish"). Steer it with the attachment marker instead.
        if (!trimmed.startsWith('!') && _isAttachableFileInput(trimmed)) {
          _steerResolved(trimmed);
          return;
        }
        await _dispatchInput(line, trimmed);
        return;
      }
      _steerResolved(trimmed);
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
    // One streaming run at a time: a run-starting command typed mid-stream
    // (/skill:, a command alias) lands here while isBusy — refuse it with
    // a visible note instead of interleaving a second run into the same
    // session.
    if (isBusy) {
      io.writeln(
        _style.dim(
          'a run is already streaming — wait for it to settle (or Ctrl+C '
          'to stop it), then retry',
        ),
      );
      return;
    }
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
        _settleLeftoverSteering();
        if (!_exited) _writeIdlePrompt();
      }),
    );
  }

  /// Runs one user prompt to completion. On a CodeMie auth-session expiry,
  /// opens the browser SSO flow to refresh the token automatically. Other
  /// provider errors are printed through [KeyStatusRenderer.errorLine]. An empty assistant
  /// message (no text, no tool calls) is retried once with 'continue'.
  /// Delivered to the model when the over-window guard stopped a run and
  /// the post-run compaction freed the window: names what happened and
  /// how to avoid re-filling the context.
  static const String _overWindowContinuationNotice =
      '<system-notice>\n'
      'The previous run was stopped by the context-window guard: the '
      'outgoing request exceeded the model window and was NOT sent. The '
      'transcript was auto-compacted just now (most of it is preserved as '
      'a summary; the session file keeps the full history). Continue the '
      'interrupted task from where it stopped. Avoid re-reading whatever '
      'filled the window (huge tool outputs, whole files) — use targeted '
      'reads (offset/limit or :A-B selectors) instead.\n'
      '</system-notice>';

  /// Whether the over-window guard's one-shot auto-continuation was used
  /// for the current user prompt (reset at every non-auto-continue
  /// [_runPrompt] entry).
  bool _overWindowAutoResumed = false;

  /// Runs one prompt turn: pre-flight ([_beginUserPrompt]) → the agent
  /// stream → outcome settle ([_settleAfterPrompt], `true` = turn finished
  /// normally) → finalize ([_afterRun]); thrown errors land in
  /// [_handleRunError]. Auto-continuations recurse with [isAutoContinue]
  /// set, which skips the pre-flight phases.
  Future<void> _runPrompt(String text, {bool isAutoContinue = false}) async {
    await _beginUserPrompt(isAutoContinue: isAutoContinue);
    try {
      await _agent.prompt(text);
      final lastMessage = _agent.state.messages.lastOrNull;
      final finished = await _settleAfterPrompt(
        lastMessage,
        isAutoContinue: isAutoContinue,
      );
      if (finished) await _afterRun();
    } catch (error) {
      await _handleRunError(error);
    }
  }

  /// [_runPrompt] pre-flight, real user prompts only: fresh over-window
  /// resume budget (see [_overWindowAutoResumed]) plus pre-flight
  /// compaction of an already-over-window transcript.
  Future<void> _beginUserPrompt({required bool isAutoContinue}) async {
    if (isAutoContinue) return;
    _overWindowAutoResumed = false;
    // Pre-flight context guard: when the LIVE context already exceeds the
    // compaction threshold, compact BEFORE sending the request — a failed
    // post-run compaction (quota-limited smol role, provider outage) used to
    // leave every request carrying an over-window payload (ctx 240% gauge).
    await _maybeAutoCompact();
  }

  /// Settles a finished agent stream: error-stop handling and the
  /// auto-continuations. Returns `true` when the turn completed and the
  /// caller should finalize with [_afterRun].
  Future<bool> _settleAfterPrompt(
    Message? lastMessage, {
    required bool isAutoContinue,
  }) async {
    if (lastMessage is AssistantMessage &&
        lastMessage.stopReason == StopReason.error) {
      if (await _maybeHandleCodeMieError(lastMessage.errorMessage ?? '')) {
        return false;
      }
      // The loop's over-window guard refused to send: compact and continue.
      if (await _maybeOverWindowContinue(
        lastMessage,
        isAutoContinue: isAutoContinue,
      )) {
        return false;
      }
    }

    // An assistant turn that produced nothing actionable (no text, no tool
    // calls) reads as a hang; nudge the model once with "continue".
    if (_shouldContinueAfterEmptyReply(lastMessage, isAutoContinue)) {
      await _runPrompt('continue', isAutoContinue: true);
      return false;
    }
    return true;
  }

  /// One-shot over-window auto-continuation: on a context-window-exhausted
  /// stop, persist, auto-compact and — when the window was actually freed —
  /// resume the interrupted task on its own (ending the run there left
  /// live agents idle mid-task, a harness hang). `true` = turn consumed.
  Future<bool> _maybeOverWindowContinue(
    AssistantMessage lastMessage, {
    required bool isAutoContinue,
  }) async {
    if (isAutoContinue ||
        _overWindowAutoResumed ||
        !isContextWindowExhaustedError(lastMessage.errorMessage)) {
      return false;
    }
    _overWindowAutoResumed = true;
    await _ttsr?.settled;
    await _persistMessages();
    if (!await _maybeAutoCompact()) {
      // Compaction freed nothing droppable: keep the resume budget for the
      // next user prompt and tell the user the way out (the guard message
      // itself rendered as a calm note already).
      _overWindowAutoResumed = false;
      io.writeln(
        _style.yellow(
          'note: could not free the context window — run /compact or '
          'start a fresh session',
        ),
      );
      return false;
    }
    io.writeln(
      _style.yellow(
        '[context overflowed — auto-compacted; continuing the turn]',
      ),
    );
    await _runPrompt(_overWindowContinuationNotice, isAutoContinue: true);
    return true;
  }

  /// Whether an empty assistant reply should get the one-shot "continue"
  /// nudge: real prompt, clean stop, nothing actionable.
  bool _shouldContinueAfterEmptyReply(
    Message? lastMessage,
    bool isAutoContinue,
  ) {
    return !isAutoContinue &&
        lastMessage is AssistantMessage &&
        lastMessage.stopReason != StopReason.error &&
        lastMessage.stopReason != StopReason.aborted &&
        _assistantMessageIsEmpty(lastMessage);
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
    io.writeln(_keyStatusView.errorLine(message, _agent.state.model.baseUrl));
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

  /// Compaction settings for the live model: the config override when the
  /// user pinned one, else pi's fixed defaults SCALED to the model window
  /// (`CompactionSettings.forWindow`) — the same rule the Flutter app
  /// applies. The fixed 20k-keep defaults are right for 128k windows but
  /// structurally prevent compaction on small models: with keep 20000 on
  /// an 8k-window model the compactor always "keeps" the whole transcript
  /// (nothing is older than the kept region), so an over-window guard can
  /// never be satisfied by compacting.
  CompactionSettings get _effectiveCompactionSettings {
    final override = config.compactionSettings;
    if (override != null) return override;
    return CompactionSettings.forWindow(_agent.state.model.contextWindow);
  }

  /// Runs the auto-compaction when the live transcript crosses the
  /// threshold. Returns whether a compaction pass actually ran and
  /// succeeded — the over-window guard's auto-continuation keys off this
  /// to resume only when the window was really freed.
  Future<bool> _maybeAutoCompact() async {
    final session = _session;
    if (session == null) return false;
    if (_agent.state.messages.isEmpty) return false;
    final tokens = estimateContextTokens(_agent.state.messages).tokens;
    if (!shouldCompact(
      tokens,
      _agent.state.model.contextWindow,
      _effectiveCompactionSettings,
    )) {
      return false;
    }
    _tuiController?.setBusyPhase('Compacting context…');
    _logDiagnostic('auto-compact start sid=$_logSid tokens=$tokens');
    await _runAutoCompact('[auto-compacted]');
    // Hand the busy row back to the run: a stale 'Compacting context…'
    // over the streamed turn reads as a compaction hang.
    _tuiController?.setBusyPhase('');
    // [_runAutoCompact] reports '[auto-compacted]' only on success; treat
    // the transcript size as the source of truth for the caller.
    final after = estimateContextTokens(_agent.state.messages).tokens;
    return after < tokens;
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
      settings: _effectiveCompactionSettings,
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
