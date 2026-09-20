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
import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import '../hashline/hashline.dart';

import '../agent/agent.dart';
import '../dap/dap_hub_snapshot.dart';
import 'agent_event_handler.dart';
import 'path_candidates.dart';
import 'browser_bridge_commands.dart';
import '../browser/browser_tools.dart';
import 'headless_prompt.dart';
import 'hep.dart';
import 'key_event.dart';
import 'key_status.dart';
import 'provider_error_text.dart';
import '../agent/agent_loop.dart';
import '../session/windowed_session_storage.dart' show WindowedSessionStorage;
import '../trajectory/event_projection.dart'
    show TrajectoryHiddenRecordPreview, projectHiddenRecordPreviews;
import '../trajectory/trajectory_record.dart' show TrajectoryCompactedRecord;
import '../trajectory/trajectory_blobs.dart';
import '../agent/agent_tool.dart';
import '../agent/auto_compactor.dart';
import '../providers/models_for_endpoint.dart';
import '../agent/tool_registry.dart';
import '../a2a/a2a_config.dart';
import '../a2a/a2a_mail_gateway.dart';
import '../a2a/a2a_manager.dart';
import '../task/task.dart';
import 'agent_tree.dart';
import 'agent_hub_panel.dart';
import 'shell_job_board.dart';
import 'agent_hub_projection.dart';
import 'agent_hub_tui.dart';
import 'waiting_heartbeat.dart';
import 'agent_hub_view.dart';
import '../task/agent_discovery.dart';
import '../task/child_session_io.dart';
import '../task/subagent.dart';
import '../task/subagent_manager.dart';
import '../task/subagent_heartbeat.dart';
import '../task/subagent_tools.dart';
import '../task/delivery_slo.dart';
import '../skills/skills.dart';
import '../skills/skill_renderer.dart';
import '../prompts/prompts.g.dart'
    show cliMessagingSectionPrompt, readSqliteSectionPrompt;
import '../prompts/project_context.dart';
import '../approval/approval.dart';
import '../approval/approval_hook.dart';
import '../cancel_token.dart';
import '../compaction/compaction.dart';
import '../compaction/structured/continuation_notice.dart';
import '../compaction/token_estimation.dart';
import '../context.dart';
import '../cube/cube.dart';
import '../env/cwd_override_env.dart';
import '../env/execution_env.dart';
import '../env/session_vars_execution_env.dart';
import '../exceptions.dart';
import '../js_ext/ext_bootstrap_js.dart';
import '../js_ext/ext_catalog.dart';
import '../js_ext/ext_install.dart';
import '../js_ext/ext_manifest.dart';
import '../js_ext/extension_host.dart';
import '../js_ext/extension_store.dart';
import '../js_ext/jsr_runtime.dart';
import '../js_ext/trust.dart';
import '../lsp/lsp_tool.dart';
import '../mcp/mcp_client.dart';
import '../mcp/mcp_config.dart';
import '../mcp/mcp_manager.dart';
import '../model.dart';
import '../model_roles/model_roles.dart';
import 'tool_phase_labels.dart';
import 'tool_rows.dart';
import '../model_roles/vision_models.dart';
import '../providers/chatgpt_codex_models.dart';
import '../providers/chatgpt_oauth.dart';
import '../providers/codemie_sso.dart';
import '../providers/copilot_device_flow.dart';
import '../providers/copilot_oauth.dart';
import '../providers/dial.dart';
import '../providers/models_endpoint.dart';
import '../providers/openrouter_oauth.dart';
import '../agent/image_registry.dart'
    show ImageRegistryConfig, imageDropNotice, imageRegistryConfig;
import '../providers/provider_common.dart'
    show
        authExpiredProvider,
        effectiveProviderConnectTimeout,
        effectiveProviderStreamIdleTimeout,
        providerConnectTimeout,
        providerStreamIdleTimeout,
        providerTimeoutsOverride,
        stripAuthExpiredMarker,
        textOnlyImageDropNotice;
import '../providers/transient_retry_stream.dart';
import '../prompts/prompt_overrides.dart';
import '../providers/aiin_auth.dart';
import 'aiin_connect_server.dart';
import 'chatgpt_oauth_server.dart';
import 'codemie_sso_server.dart';
import 'openrouter_oauth_server.dart';
import '../secrets/secure_key_store.dart';
import '../session/session_record.dart';
import '../env/session_parse_executor.dart';
import '../session/session_repo.dart';
import '../session_io_retry.dart';
import '../session/attach/file_presence_store.dart';
import '../session/attach/session_presence.dart';
import '../session/attach/session_lease.dart';
import '../session/attach/session_attachment.dart';
import '../session/attach/file_attachment.dart';
import '../config/config_service.dart';
import 'startup.dart';
import 'cli_config.dart';
import 'custom_providers.dart';
import 'folder_model_state.dart';
import 'provider_flow.dart';
import '../session/session_storage.dart';
import '../session/session_tree.dart';
import 'session_tree.dart';
import '../trajectory/trajectory_snapshot.dart';
import 'trajectory_tui.dart';
import '../tools/availability.dart';
import '../tools/availability_gate.dart';
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
import '../power_config.dart';
import '../power_runner.dart';
import '../messaging/agent_fabric.dart';
import '../messaging/agent_message.dart';
import '../messaging/file_messaging_repository.dart';
import '../messaging/messaging_repository.dart';
import '../messaging/schedule_message_tool.dart';
import '../messaging/scheduled_messages.dart';
import '../memory/memory_tools.dart';
import '../plugins/plugin.dart';
import '../redact/redaction_cli.dart';
import '../redact/redaction_hooks.dart';
import '../redact/redaction_pipeline.dart';
import '../spill/spill.dart';
import '../ttsr/ttsr.dart';
import '../types.dart';
import '../usage_summary.dart';
import '../web_search/web_search.dart';
// The interactive dart_tui REPL is VM-only (raw terminal + FFI); web builds
// of the root library get a no-op stub with the same host-facing API.
import 'paste_image.dart';
// Pasteboard reads are VM-only (osascript/xclip/PowerShell); web builds get
// a stub that always reports unavailable.
import 'clipboard_reader_stub.dart'
    if (dart.library.io) 'clipboard_reader.dart';
// Job-registry process probes are VM-only (`ps` via dart:io); web builds
// get a stub that always reports "no process table".
import '../env/process_probe_stub.dart'
    if (dart.library.io) '../env/process_probe_io.dart';

import 'fa_tui_stub.dart' if (dart.library.io) 'fa_tui.dart';
import 'prompt_templates.dart';
import 'ask_menu.dart';
import 'slash_menu.dart';
import 'task_list.dart';
import 'model_picker_table.dart';
import 'text_format.dart';
import 'terminal_setup.dart';
import 'tui_helpers.dart';
import 'tui_prompt.dart';
import 'scripted_test_stream.dart';
import 'tui_replay.dart';
import 'tui_repl.dart';
import 'tui_theme.dart';

export '../model_roles/provider_catalog.dart' show providerStreamFunction;

part 'provider_flow_helpers.dart';
part 'provider_commands.dart';
part 'agent_cli_compaction.dart';
part 'provider_models.dart';
part 'codemie_provider_commands.dart';
part 'aiin_provider_commands.dart';
part 'provider_keys.dart';
part 'agent_cli_mcp.dart';
part 'agent_cli_config.dart';
part 'settings_flow.dart';
part 'agent_commands.dart';
part 'approval_commands.dart';
part 'skill_commands.dart';
part 'session_commands.dart';
part 'trajectory_commands.dart';
part 'agent_cli_cube.dart';
part 'agent_cli_provider_presets.dart';
part 'agent_cli_inbox.dart';
part 'agent_cli_viewer.dart';
part 'agent_cli_persist.dart';
part 'agent_hub_cli.dart';
part 'agent_cli_steering.dart';
part 'agent_cli_tools.dart';
part 'agent_cli_io.dart';
part 'agent_cli_hep_io.dart';
part 'agent_cli_banner.dart';
part 'agent_cli_waiting.dart';
part 'agent_cli_mcp_print.dart';
part 'agent_cli_commands.dart';
part 'agent_cli_ext.dart';
part 'agent_cli_theme.dart';
part 'agent_cli_composer.dart';
part 'agent_cli_spill.dart';

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
    this.environment = const {},
    DateTime Function()? waitingClock,
    Future<void> Function(Duration)? waitingSleep,
  }) : io = useTui && io.supportsRawMode ? _TuiCliIO(io) : io,
       _style = _Style(enabled: useColor),
       _waitingClock = waitingClock ?? DateTime.now,
       _waitingSleep =
           waitingSleep ?? ((Duration d) => Future<void>.delayed(d)),
       _useTui = useTui && io.supportsRawMode {
    // Sleep prevention (issue #325): null runner (tests, web) → none.
    _powerAssertions = sessionPowerAssertions(config, this.io.writeln);
    _env = CwdOverrideEnv(config.env);
    _modes = builtInAgentModes(_env.cwd, overrides: config.promptOverrides);
    _currentMode = _modes[config.initialMode] ?? _modes['code']!;
    _providerKind = config.providerKind;
    _apiKey = config.apiKey;
    // The theme emitters' color profile: styled iff this session styles
    // at all (TUI or colored line mode); NO_COLOR / TERM=dumb degrade to
    // plain output (issue #279 AC7).
    FaThemeController.instance.profile = detectThemeProfile(
      ansiSupported: useTui || useColor,
      environment: environment,
    );
    // Boot theme: async — user themes load through the FileSystem seam
    // before the persisted name resolves (issue #279 AC4); fire-and-forget
    // keeps the constructor sync.
    unawaited(_applyBootTheme());
    final pluginTools = <AgentTool>[];
    for (final plugin in config.plugins) {
      final context = PluginContext(
        env: _env,
        // this.io — the TUI-wrapped field, NOT the raw constructor
        // parameter: plugin output must route through the TUI transcript
        // (raw writes race the frame renderer and leave stray text on
        // screen).
        io: _PluginIO(this.io),
        config: _pluginConfig(plugin.name),
        pickOption: _pickOption,
        askLine: _askLine,
      );
      plugin.register(context);
      pluginTools.addAll(context.tools);
      _pluginInboxes.addAll(context.externalInboxes);
      _pluginSlashCommands.addAll(context.slashCommands);
      _pluginSlashDescriptions.addAll(context.slashCommandDescriptions);
    }

    _streamFunction =
        streamFunction ??
        scriptedTestStreamFunction() ??
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
      // A `backend: kernel` cube degrading to policy mode (no enforcing
      // backend on this host) is a security-relevant downgrade — say so.
      onWarning: (message) => io.writeln(tuiWarning(message)),
    );
    _webNetworkGate = _initWebNetworkGate(_cubeEnv);
    _cubeSource = config.cubeSource;
    _coreToolEnv = SessionVarsExecutionEnv(_cubeEnv, _sessionEnvVars);
    final decoratedEnv = _coreToolEnv;
    // ONE hashline snapshot store shared by `read` and `edit` (and by the
    // sqlite-variant swap of `read` in agent_cli_tools.dart), so anchors
    // recorded by any variant validate for edits.
    _snapshotStore = HashlineSnapshotStore();
    // Session-scoped background shell jobs (bash background / steer-yield);
    // settle notifications re-enter the conversation like task completions.
    _shellJobs = ShellJobRegistry(
      env: decoratedEnv,
      onSettled: AgentCliShellJobSettle(this)._onShellJobSettled,
      onStart: _onShellJobStarted,
      onStaleJobLog: _onStaleJobLog,
    );
    final coreTools = <AgentTool>[
      ...builtinTools(
        // Session-correlation env vars (FAH_SESSION_ID/FILE/PROVIDER/MODEL)
        // for the bash tool; resolved live, so `/provider` switches and
        // session (re)creation are picked up per exec.
        decoratedEnv,
        snapshots: _snapshotStore,
        webSearch: config.webSearchConfig,
        networkGate: _webNetworkGate,
        model: () => _agent.state.model,
        sqlite: config.sqliteEngine,
        lsp: config.lspConfig,
        mcp: _mcp.manager,
        shellJobs: _shellJobs,
        // Mid-run password asks (issue #367): the TUI opens the masked
        // secret-mode prompt; the value streams to the live process stdin.
        onPasswordPrompt: io.isInteractive ? _answerPasswordPrompt : null,
        config: ConfigService(env: decoratedEnv, homeDir: config.homeDir),
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
      // Browser control (issue #23): registered only when the host
      // attaches a controller; the family then flips with the bridge via
      // the controller's onAvailabilityChanged hook below.
      if (config.browserController != null)
        ...browserTools(
          controller: config.browserController!,
          saveScreenshot: (png) => saveBrowserScreenshot(_env, png),
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
    // Messaging fabric: file inboxes; hub primary composes over (#27).
    final (:fabric, :fileFabric, :messagesRoot) = buildAgentFabric(
      env: _env,
      sessionRoot: config.sessionRoot,
      homeDir: config.homeDir,
      hubFabric: config.hubFabric,
      mainMailbox: () => _subagentManager.mailboxOf('main'),
    );
    _messagesRoot = messagesRoot;
    _fileFabric = fileFabric;
    _fabricRepository = fabric;
    _subagentManager = SubagentManager(
      parentSessionId: '',
      messaging: _fabricRepository,
      selfId: 'main',
      homeDir: config.homeDir,
      wakeProcess: _launchMailboxWake,
      sink: (registry) async {
        final session = _session;
        if (session == null) return;
        await session.appendCustomEntry(
          customType: subagentRegistryRecordType,
          data: registry,
        );
      },
      // Issue #488 AC2: the snapshot is read by RAW file scan (the
      // windowed boot open drops side-leaf custom records out of
      // getEntries — the registry used to come back EMPTY on every
      // restart) and transcript-only children are adopted, so
      // task_send/task_resume address pre-restart children.
      source: () async {
        final session = _session;
        if (session == null) return const [];
        return subagentRegistryRows(
          repo: _repo as JsonlSessionRepo,
          parent: await session.getMetadata(),
        );
      },
    );
    _subagentManager.machineName = config.machineName;
    // Phase 5a: A2A remote agents from the `a2a:` config section. Connects
    // lazily per server (never blocks boot).
    _a2aManager = A2aManager(config.a2aConfig);
    // Issue #27 phase 3: cross-machine `agent_message` rides the A2A
    // boundary gateway (the `a2a:` config's server per machine).
    _subagentManager.a2aGateway = A2aMailGateway(
      manager: _a2aManager,
      machineName: config.machineName,
    );
    // Issue #383: the heartbeat rides the steering channel — the getters
    // consult the config EVERY tick, so a config rewrite applies at the
    // next digest without a restart (E6).
    _subagentHeartbeat = SubagentHeartbeat(
      manager: _subagentManager,
      heartbeatMinutes: () => config.subagents.heartbeatMinutes,
      stallMinutes: () => config.subagents.stallMinutes,
      notify: _deliverHeartbeatDigest,
    );
    _subagentHeartbeat.start();
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
      // Live accessors, resolved per spawn: a runtime `/provider`/`/model`
      // switch (or a token refresh) re-points `_streamFunction`/the agent
      // model, and children spawned afterwards must inherit the LIVE
      // credential — the boot wiring here would send the stale key (401).
      streamFunction: () => _agent.streamFunction,
      model: () => _agent.state.model,
      rolesResolver: config.modelRolesResolver,
      subagentManager: _subagentManager,
      a2aManager: _a2aManager,
      // Issue #439: children compact on the host's engine choice (live
      // settings override, else config, else structured default).
      compactionEngine: config.liveCompactionEngine ?? config.compactionEngine,
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
      // Issue #222: the resume path reopens a child's JSONL session by
      // path so task_resume/task_send continue the child in the SAME file.
      // Issue #427: the task-resume reopen of a child's session file
      // rides the same transient-ENOENT retry, logged to fa.log.
      childSessionOpener: jsonlChildSessionOpener(
        _env,
        ioRetry: SessionIoRetryConfig(logger: _logDiagnostic),
      ),
    );
    final monitoringTools = subagentMonitoringTools(
      manager: _subagentManager,
      jobs: _taskConfig.jobManager,
      // Issue #222: child messaging IS available on this host — observe
      // reads the child's JSONL transcript; send/resume continue the child
      // in its own session via the session-shared executor.
      readMessages: jsonlChildMessageReader(_env),
      resumeChild: _taskConfig.executor.resumeChild,
      // Issue #332: task_cancel must reach inline children (blocking
      // batches, resumes) through the executor's in-flight cancel set —
      // without it the tombstone fallback would fire over LIVE children.
      executor: _taskConfig.executor,
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
      contextWindowCap: config.contextWindowCap,
      wireDump: config.wireDump,
      // Issue #387: the loop's over-window guard hands the transcript to
      // this relief before refusing — one synchronous compaction pass.
      overWindowRelief: (overWindow) => _relieveOverWindow(overWindow),
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
    // Provider queue (issue #418): when set, it REPLACES the main-model
    // resolution — the default role runs through the queue's sticky-cursor
    // failover stream. Auxiliary roles (smol/slow/plan) keep their own
    // chains; /model and /provider stay functional for everything else.
    final queueRuntime = config.providersQueueRuntime;
    if (queueRuntime != null) {
      _agent.streamFunction = queueRuntime.streamFunction.call;
      _agent.state.model = queueRuntime.streamFunction.currentModel;
      _streamFunction = _agent.streamFunction;
      _rolesDriven = true;
    }
    _approval = ApprovalManager(
      mode: config.approvalMode,
      alwaysAllow: config.alwaysAllowTools,
      // Non-interactive input (piped) gets no prompt callback: prompt-policy
      // calls are then denied with a "no approval UI" reason (safe default).
      prompt: io.isInteractive ? _promptForApproval : null,
    );
    attachApproval(_agent, _approval);
    // Layered redaction (issue #24): the host assembles the pipeline from
    // the `redact:` config + this process's secrets; hooks mask tool
    // results before they reach the transcript/session and deny
    // credential-file reads in blockMode. The legacy SecretRedactor exact
    // masking keeps running alongside (attached lazily on runtime tokens).
    if (config.redactionPipeline != null) {
      attachRedactionPipeline(_agent, config.redactionPipeline!);
    }
    attachSpillWiring();
    // Busy-row honesty: name the executing tool ('Running bash…') instead
    // of leaving a stale 'Compacting context…' label over long tool calls.
    attachToolPhaseLabels(_agent, (phase) => _pushBusyPhase(phase));
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
    _compactExpand = CompactExpandController(
      agent: _agent,
      session: () => _session,
    );
    _toolRegistry.register(_compactExpand.tool);
    _agent.state.tools = _toolRegistry.tools;
    // Capability-gated availability (issue #19): the gate hides/restores
    // tools per the tools: scope stack and tombstones disabled calls; the
    // rebuild (async config reads) applies the startup resolution.
    _toolGroupsById = AgentCliTools(this).toolGroups();
    _toolGate = ToolAvailabilityGate(toolsById: _toolGroupsById);
    _agent.toolExecutor = _toolGate.wrapExecutor(_agent.toolExecutor);
    unawaited(AgentCliTools(this).rebuildToolAvailability());
    _agent.subscribe(_onAgentEvent);
    // MCP: late tool (re)registration and prompt updates flow through the
    // manager's change callback; servers connect in the background.
    final mcpManager = _mcp.manager;
    if (mcpManager != null) {
      mcpManager.onChanged = _onMcpChanged;
      mcpManager.start();
    }
    // JS extensions (issue #32): connect in the background like MCP. The
    // microtask keeps hook-attach order correct: approval + redaction are
    // wrapped above, so the JS hooks land OUTERMOST and run last.
    scheduleMicrotask(() => unawaited(initJsExtensions()));
    // Browser bridge liveness: an extension pairing or dropping flips the
    // browser capability floor, so rebuild availability (same path as
    // /tools reload — re-resolves scopes, re-applies, rebuilds the prompt).
    config.browserController?.onAvailabilityChanged = (_) {
      unawaited(AgentCliTools(this).rebuildToolAvailability());
    };
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

  /// The host environment (bin/fah passes `Platform.environment`), read
  /// for NO_COLOR / TERM / COLORTERM theme-profile detection (issue #279).
  final Map<String, String> environment;

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
  /// `_buildModelMenu` the TUI's model picker renders. [width] is the
  /// terminal width the table lays its columns out for (80 = the headless
  /// default).
  @visibleForTesting
  List<MenuItem> buildModelMenuForTest(String filter, {int width = 80}) =>
      _buildModelMenu(filter, width);

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

  /// Test seam firing one heartbeat tick (issue #383) — the same path the
  /// cadence timer drives, without waiting real minutes in tests.
  @visibleForTesting
  void heartbeatTickForTest() => _subagentHeartbeat.tick();

  /// Test seam exposing the subagent registry — the heartbeat tests plant
  /// running children without driving a real spawn.
  @visibleForTesting
  SubagentManager get subagentManagerForTest => _subagentManager;

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

  /// Test seam: the picker-id → handler dispatch map's keys. A picker id
  /// opened by `openPicker` without an entry here is a dead menu entry
  /// (selection routes to `null?.call()` — the picker closes and nothing
  /// happens), so the dispatch test asserts the id set exactly.
  @visibleForTesting
  Set<String> pickerHandlerKeysForTest() => _tuiPickerHandlers.keys.toSet();

  /// Test seam: the settings-hub item keys that have a dispatch target
  /// (a hub row without one closes silently on Enter).
  @visibleForTesting
  Set<String> settingsPickerHandlerKeysForTest() =>
      _settingsPickerHandlers.keys.toSet();

  /// Test seam: opens the sessions picker (building its rows) without a
  /// TUI; the built items land in [sessionPickerItemsForTest].
  @visibleForTesting
  Future<void> openSessionsPickerForTest() => _openSessionsPicker();

  /// The items the most recent sessions picker opened with (see
  /// [openSessionsPickerForTest]).
  @visibleForTesting
  List<MenuItem>? sessionPickerItemsForTest;

  /// Test seam routing a sessions-picker selection in line mode.
  @visibleForTesting
  Future<void> tuiPickSessionForTest(String key) => _tuiPickSession(key);

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

  /// Web-egress gate for the web tools; see [_initWebNetworkGate].
  late final CubeNetworkGate? _webNetworkGate;

  /// Where the active cube came from — a manifest path or a cube name;
  /// `/cube reload` re-resolves it. Set at boot (config) and by
  /// `/cube use`; never cleared by `/cube off` (a reload re-applies it).
  String? _cubeSource;

  /// The last fetched [DapHubSnapshot] — rendered by the settings hub's
  /// DAP / Hub row and the `/settings` summary, refreshed before each
  /// render and at the top of the DAP flow. Null until fetched or when no
  /// hub wiring exists ([AgentCliConfig.dapHubState]).
  DapHubSnapshot? _dapHubSnapshot;

  /// Retained-subagent registry (Phase 3a): tracks every spawned child so
  /// `task_status`/`task_observe`/`task_send` work after completion.

  /// [MailboxWakeLauncher] wiring: spawns a detached headless run of the
  /// target session (`nohup <exe> --session <name> "<prompt>" &`) in the
  /// target's cwd. The headless turn drains the inbox fabric as user
  /// messages; the session JSONL is shared, so a later interactive
  /// `fa --session <name>` resumes that transcript. Returns an error text
  /// or null on success.
  Future<String?> _launchMailboxWake({
    required String cwd,
    required String sessionId,
    String? sessionName,
  }) async {
    final command = mailboxWakeCommand(
      wakeExecutable: config.wakeExecutable,
      sessionId: sessionId,
      sessionName: sessionName,
    );
    final result = await _env.exec(
      command,
      options: ShellExecOptions(cwd: cwd),
    );
    return result.isOk
        ? null
        : 'shell exec failed: ${result.errorOrNull?.message ?? 'unknown error'}';
  }

  late final SubagentManager _subagentManager;

  /// The background-subagent heartbeat (issue #383): periodic status
  /// digests + loud stall flags, delivered through the same steer/wake
  /// path as completion notices.
  late final SubagentHeartbeat _subagentHeartbeat;

  /// The FILE fabric layer — re-pointed when session storage falls back to
  /// a different root so the mailboxes follow the sessions.
  late final SwappableMessagingRepository _fileFabric;

  /// The shared fabric: the file inboxes, or the hub-primary composite
  /// when a hub fabric is injected (issue #27).
  late final MessagingRepository _fabricRepository;

  /// The launch-cwd messaging root (also backs scheduled messages).
  late final String _messagesRoot;

  /// The ownership lease held for the current session (its sidecar path),
  /// or null when driving unleased (no store / unenforced backend).
  String? _heldLeasePath;

  /// The viewer attachment when this instance opened a leased session.
  _ViewerAttachment? _viewer;

  /// The live presence row for the session this instance is DRIVING —
  /// re-registered when [/session] switches (a viewer keeps no row).
  ({SessionPresenceStore store, String sessionId})? _livePresence;

  /// Per-process lease identity (E3): pid recycling across restarts
  /// cannot impersonate a dead owner because this differs.
  late final String _leaseBootId = FileSessionLeaseStore.newBootId();

  /// Persisted delayed messages (`schedule_message`): pending records live
  /// under `<messagesRoot>/_scheduled/` and are delivered into the
  /// agent's own inbox when due, where the idle-wake starts a turn.
  late final ScheduledMessageQueue _scheduledMessages = _newScheduledMessages();

  /// The visible-waiting layer (issue #450): waiter aggregate, TUI waiting
  /// row push, waiting heartbeat, restart honesty, headless semantics.
  late final _WaitingCoordinator _waiting = _WaitingCoordinator(this);

  /// Clock seam for the waiting layer (issue #450 tests): the heartbeat
  /// cadence, the waiting-since elapsed, and the `--wait-for-jobs` loop
  /// read this instead of [DateTime.now] directly.
  final DateTime Function() _waitingClock;

  /// Sleep seam for the `--wait-for-jobs` loop — tests advance the fake
  /// waiting clock through it instead of really sleeping.
  final Future<void> Function(Duration) _waitingSleep;

  /// The session's retained-subagent registry (tests, the app settings
  /// Agents panel, hosts observing children).
  SubagentManager get subagentManager => _subagentManager;

  /// The session's task-tool wiring (job registry, subagent registry,
  /// child-session opener) — tests and hosts verifying the lifecycle
  /// wiring read it instead of reaching into private state.
  TaskToolConfig get taskConfig => _taskConfig;

  late final A2aManager _a2aManager;

  /// Agent types discovered from `.fah/agents/` + `.agents/agents/`.
  List<TaskAgentDefinition> _discoveredAgents = const [];

  late final Agent _agent;
  late final ApprovalManager _approval;
  late final ToolRegistry _toolRegistry;

  /// Capability-gated tool availability (issue #19) — state for the
  /// `agent_cli_tools.dart` extension: the static tool set grouped by
  /// availability id (the `read` group entry swaps in place on sqlite
  /// toggles so the gate always re-registers the current variant), the
  /// enforcing gate (one per CLI — the wrapped executor captures it), the
  /// shared read/edit hashline snapshot store, the tools' execution env,
  /// and the scope caches.
  late final Map<String, List<AgentTool>> _toolGroupsById;
  late final ToolAvailabilityGate _toolGate;
  late final HashlineSnapshotStore _snapshotStore;
  late final SessionVarsExecutionEnv _coreToolEnv;
  final _ToolsWiringState _toolsWiring = _ToolsWiringState();

  /// Long-term memory controller (project + user scope stores). Always
  /// constructed; search is disabled when no LLM provider is injected.
  late final MemoryController _memory;
  late final CheckpointRewindController _checkpoints;

  /// The `compact_expand` controller (issue #148): per-turn expand budget
  /// reset + tool binding to the LIVE session.
  late final CompactExpandController _compactExpand;
  TtsrController? _ttsr;
  final _Style _style;
  final bool _useTui;
  final String _version;

  /// Whether the default role resolved and drives the agent (roles mode).
  /// The banner's key-status line reads env var names from the live model's
  /// provider then; legacy mode reads them from the provider kind.
  var _rolesDriven = false;
  final _usage = UsageAccumulator();

  // Issue #277 agents-hub driver state (see agent_hub_cli.dart). The
  // projection accumulates per-agent running spans; the panel log keeps
  // the deferred (btw) panel history; the subscriptions are lazy so a
  // session that never opens the hub still gets task-block rendering.
  final AgentHubProjection _hubProjection = AgentHubProjection();
  final DeferredPanelLog _hubPanels = DeferredPanelLog();

  /// Issue #429: the per-session background-job board — truthful phases,
  /// per-turn collapse, records for reload. Replaced wholesale on session
  /// resume by rehydration.
  ShellJobBoard _jobBoard = ShellJobBoard();

  /// The registry-persist serialization tail (issue #539) — see
  /// `_persistJobBoard` in the hub driver extension.
  Future<void> _persistChain = Future.value();
  final DateTime _hubMainStartedAt = DateTime.now();
  String? _hubTranscriptId;
  Timer? _hubFollowTimer;
  StreamSubscription<dynamic>? _hubSubagentEventsSub;
  StreamSubscription<dynamic>? _hubTaskStartsSub;

  // Issue #437 steering delivery tracking. A mid-run steer is persisted
  // at accept and queued here until the agent loop merges it at a step
  // boundary (identity match on the queued message) or the leftover
  // settle runs/drops it; the wake paths deliver recovered records.
  final List<PendingSteering> _pendingSteering = [];

  /// Last agent event time — the run heartbeat. A busy run silent past
  /// `config.steeringStaleAfter` looks wedged: steering flips to `dead`.
  DateTime? _lastAgentEventAt;

  /// Recovered steering from the previous session (persisted-but-
  /// unconsumed records), awaiting the idle wake; null once delivered.
  List<({String recordId, String text, DeferredPanel panel})>?
  _recoveredSteering;

  /// Guards the recovery wake against the settle-gap re-entry (mirrors
  /// `_inboxWakeRunning`).
  bool _steeringWakeRunning = false;

  /// Hard bounds for the compaction-time memory extraction (see
  /// `_runAutoCompact`): cancel the extraction stream after 90s, and
  /// force-skip after 120s even if the cancel didn't land.
  static const _memoryExtractionDeadline = Duration(seconds: 90);
  static const _memoryExtractionHardCap = Duration(seconds: 120);

  /// Memoized settled-part context estimate for the status line
  /// (see `_liveContextTokens` in approval_commands.dart): keyed on the
  /// transcript length + last message instance — never on stream content.
  final SettledContextEstimate _ctxEstimate = SettledContextEstimate();

  /// Memo fields for the status line's request overhead (system prompt +
  /// tool schemas, [estimateRequestOverheadTokens] — the method lives in
  /// approval_commands.dart next to its only caller): keyed on the prompt
  /// instance and the tool ELEMENT identities — the [AgentState] getters
  /// copy their lists on every read, so list identity would miss every
  /// frame while the Tool objects themselves stay stable across copies.
  String? _overheadPromptKey;
  List<int>? _overheadToolKey;
  int _overheadTokens = 0;

  late SessionRepo _repo = JsonlSessionRepo(
    fs: _env,
    sessionsRoot: config.sessionRoot,
    // Issue #427: transient-ENOENT retries of session-file IO log one
    // `session_io_retry` line each into the diagnostic log (fa.log).
    ioRetry: SessionIoRetryConfig(logger: _logDiagnostic),
    // Resume diagnostics: session-open timings (read/parse/rebuild, bytes,
    // record counts) as `resume_timing` lines in fa.log — answers "why is
    // resume slow" without a profiler.
    timingLog: _logDiagnostic,
    // Issue #522: the deletion gate reads live heartbeats — a session a
    // running process owns is undeletable from every other surface.
    presenceStore: config.presenceStore,
    processId: config.processId,
    parseExecutor: config.parseExecutor,
  );
  Session? _session;

  /// Issue-385 blob persistence state: one persister per session (dedup
  /// sets live in it); recreated when the session changes.
  TrajectoryBlobPersister? _trajectoryBlobPersister;
  Session? _trajectoryBlobPersisterSession;

  /// HEP v1 writer for backend agent mode (`--output events`, issue #155);
  /// null in the REPL. Set by [runHeadless], read by the compaction pass
  /// to bracket runs with frames.
  HepWriter? _hep;
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
  /// cancel or input shutdown.
  Completer<String?>? _pendingPromptAnswer;
  final Map<String, SlashCommand> _pluginSlashCommands = {};

  /// Session sleep-prevention (#325): held on [run], freed on teardown.
  PowerAssertionController? _powerAssertions;
  final Map<String, String> _pluginSlashDescriptions = {};
  final List<ExternalInbox> _pluginInboxes = [];

  /// JS-extension wiring state (extensions cannot add fields) — the live
  /// host, ext slash commands, and the prompt section. See
  /// agent_cli_ext.dart.
  final AgentCliExtState _ext = AgentCliExtState();
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

  /// Start wall-clock + rendered detail per in-flight tool call (keyed by
  /// toolCallId) — the end row repeats the detail and adds the elapsed zone
  /// (issue #366). Unpaired ends render neither.
  final Map<String, (DateTime, String)> _toolStarts = {};

  /// The MCP wiring (manager + re-registration) — see agent_cli_mcp.dart.
  late AgentCliMcpWiring _mcp;

  /// Re-registers the MCP tool surface and rebuilds the prompt whenever a
  /// server connects, fails, or drops.
  void _onMcpChanged() {
    _mcp.reRegister(_toolRegistry, _agent, _applyPromptComposition);
    // Re-apply the availability decision to the fresh MCP surface (a
    // no-op until the first rebuild produced a resolution).
    final resolution = _toolGate.resolution;
    if (resolution != null) {
      AgentCliTools(this).refilterMcpTools(resolution);
    }
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
      extSection: _ext.promptSection,
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

  /// Whether the current run was pushed to consumers as stalled (issue
  /// #514): the edge flag keeps the banner to ONE print per stall
  /// episode instead of one per watchdog tick.
  bool _runStalledPushed = false;

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

  /// Providers whose cached list is trusted for THIS session: fetched live
  /// here, or loaded from a disk entry younger than 24h. A trusted entry
  /// skips the live refetch; anything else revalidates in the background.
  final Set<String> _modelCacheFresh = {};
  bool _modelCacheDiskLoaded = false;

  /// Context windows reported by the endpoint's `/models` payload (see
  /// [parseModelsResponse] in provider_commands.dart); empty when the
  /// fetcher is replaced (tests) or the endpoint reports none. Drives
  /// automatic window correction so the catalog default (200k) stops lying
  /// for custom endpoints.
  Map<String, int> _modelContextWindows = const {};

  /// Model ids the "endpoint reported no window" note already fired for
  /// (see `_noteUndetectedContextWindow` in provider_models.dart) — once
  /// per id per process, never a per-refresh spam.
  final Set<String> _undetectedWindowNoteIds = <String>{};

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
  Future<void> run() async {
    await _cubeBootRestore();
    await _claimSessionLease();
    // Restart honesty (issue #450): jobs in the manifest were left
    // running by the previous run — count them, then take the file over.
    await _waiting.captureLostJobs();
    await _loadAgentContext();
    // Persisted model cache (stale-while-revalidate): the /model picker
    // serves the last fetched lists instantly at boot; the live refresh
    // revalidates on the first menu open (stale entries) — no boot HTTP.
    await _loadPersistedModelCache();
    _session = await _initializeSession();
    // Ownership lease (#428): claim before anything can drive — a live
    // lease flips this boot into viewer mode (no takeover exists).
    await _claimSessionLease();
    // Sleep prevention (#325/#326): only the EXPLICIT session hold
    // acquires here — the default per-run hold acquires at every run
    // start instead, so an idle agent never pins the machine awake.
    await acquirePowerAssertions();
    // Session scope (tools.yaml next to the session file) is live now.
    unawaited(AgentCliTools(this).rebuildToolAvailability());
    _syncMailboxPrefix();
    // Boot marker: every wedge post-mortem starts with "which BUILD held
    // the busy row?" — parallel fa processes share this log, so name the
    // version next to the session id before any lifecycle line.
    _logDiagnostic('fa boot sid=$_logSid version=$_version');
    _wireTransientRetryNotice();
    _wireDeliverySloNotice();
    _wireImageDropNotice();
    onUnknownFinishReason = (reason) =>
        _logDiagnostic('unknown finish_reason sid=$_logSid reason=$reason');
    _livePresence = await _registerLivePresence();
    // Phase 3a: rehydrate the subagent registry from the resumed session's
    // `subagent_registry` records — agents of this session are visible again
    // (across restarts AND across instances sharing the session repo).
    // AWAITED (issue #332): zombie queued/running rows are settled to
    // terminal BEFORE the first prompt can spawn children — a fire-and-
    // forget load let a same-id first spawn race it (the snapshot copy
    // would clobber the live row). [SubagentManager.rehydrate] also skips
    // ids already registered by this process, so the race stays closed.
    await _subagentManager.rehydrate();
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
    _hubEnsureEventSubs();
    final inboxTimer = _startInboxWatcher();
    try {
      if (_useTui) {
        // The TUI prints the banner itself into its output history (buffered
        // by the controller until the program's event loop is listening).
        await _runTuiRepl();
      } else {
        await _runLineRepl();
      }
    } finally {
      await _teardownAfterRepl(interruptSub, taskSub, inboxTimer);
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
    if (store != null && sessionId != null && _viewer == null) {
      await store.register(sessionId, pid: config.processId);
      return (store: store, sessionId: sessionId);
    }
    return null;
  }

  /// The inbox watcher: incoming inter-agent mail while IDLE wakes the
  /// agent into a turn (mid-run mail is delivered by the steering poll).
  /// The same tick refreshes the presence heartbeat (every other tick ≈
  /// 4s, well inside the 15s staleness window).
  Timer _startInboxWatcher() {
    var heartbeatTick = 0;
    return Timer.periodic(const Duration(seconds: 2), (_) {
      // Viewer mode: follow the lease only — the owner's mail, presence,
      // and orphan reclaims are the OWNER's job, never a viewer's.
      if (_viewer != null) {
        unawaited(_viewerTick());
        return;
      }
      unawaited(_reclaimOrphanFabricMail());
      unawaited(_wakeOnInboxMail());
      // #437: wedge watchdog for mid-run steering + the idle wake for
      // steering recovered from the previous session.
      _checkPendingSteeringHealth();
      _wakeOnRecoveredSteering();
      if (heartbeatTick++ % 2 == 0) {
        // Touches the CURRENT session's row and re-registers after a
        // /session switch (a viewer keeps no row at all).
        unawaited(_touchPresenceForCurrentSession());
        // The messaging-fabric heartbeat: agent_directory reports this
        // instance as live even when no mail is pending.
        _touchFabricHeartbeat();
      } else {
        // Our lease heartbeat (≈4s, inside the 15s window): a false
        // return means the lease was lost — demote to viewer.
        unawaited(_leaseHeartbeat());
      }
    });
  }

  /// Input ended (EOF) or the REPL is shutting down: never leave a tool
  /// call waiting on an answer that cannot arrive.
  Future<void> _teardownAfterRepl(
    StreamSubscription<dynamic> interruptSub,
    StreamSubscription<dynamic> taskSub,
    Timer inboxTimer,
  ) async {
    _cancelPendingAnswers();
    _hubTeardown();
    await releasePowerAssertions();
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
    await _extSessionEndBounded();
    if (_livePresence != null) {
      await _livePresence!.store.unregister(_livePresence!.sessionId);
      _livePresence = null;
    }
    // Lease bookkeeping: release OUR lease (graceful exit, #428); a
    // viewer never touches the owner's lease.
    await _releaseSessionLease();
    // A session nobody wrote to leaves no file behind (never a viewer's
    // call — the owner's file is not ours to delete).
    if (_viewer == null) await deleteSessionIfEmpty();
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
    await _printViewerBannerIfAny();
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

  /// The `fa --session …` resume line, or null when nothing was persisted.
  /// Separate from [printSessionResumeHint] so non-REPL callers (the SIGINT
  /// exit path) can print it to the REAL stdout after the TUI is gone —
  /// routing through [io] there would write into a dead transcript.
  Future<String?> sessionResumeHint() async {
    final session = _session;
    if (session == null || _persistedCount == 0) return null;
    // A windowed marathon resume pages only the tail up to the compaction
    // boundary: a name written at creation stays OUTSIDE the resident
    // window, so getSessionName() reads null and the hint degraded to the
    // raw id (user report after #503 windowing). Probe the file's
    // head+tail windows — the same bounded quick path `--session NAME`
    // resolution uses (#369) — before falling back to the id.
    var name = await session.getSessionName();
    final metadata = await session.getMetadata();
    if (name == null) {
      final repo = _repo;
      if (repo is JsonlSessionRepo) {
        try {
          name = await repo.sessionNameQuick(metadata);
        } on Object {
          name = null; // unreadable file at exit: degrade to the id
        }
      }
    }
    final id = name ?? metadata.id;
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
    if (!_sessionIsEmpty()) return;
    await _deleteEmptySessionFile();
  }

  Future<void> _runTuiRepl() async {
    // Busy-row forensics: every arm/release/drop/watchdog-fire lands in
    // fa.log with its source — a wedged "Working…" names its owner.
    faTuiBusyDiagnostics = _logDiagnostic;
    final controller = _createTuiController();
    _tuiController = controller;
    _setTuiIo(controller);
    // Pending scheduled follow-ups light the indicator row on boot (#115).
    unawaited(_pushScheduledStatus());

    // The banner is part of the TUI output history so it stays visible above
    // the input line inside the alternate screen.
    await _printBanner();
    await _printViewerBannerIfAny();
    // The first _loadAgentContext() ran before the TUI owned the terminal —
    // its "found but disabled" hint never reached the transcript. Re-print.
    _printThirdPartySkillsDisabledHint();
    // Issue #503: the reconciliation notices paint BEFORE the history
    // replay — the replay is the final paint, so the resumed session's
    // tail (the last assistant message) stays on the first glass.
    await _rehydrateJobBoard();

    await _replayRestoredSession();
    // One-time consent question for third-party skill roots: a TUI picker
    // over the first frame (Esc = "Not now", asked again next launch).
    // The visible-waiting row lights up on boot too (issue #450): armed
    // timers from previous runs + the restart-honesty note.
    unawaited(_waiting.push());
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
      syncOutput: config.tuiSyncOutput,
      callbacks: FaTuiCallbacks(
        onSubmit: (line, {images = const []}) =>
            _handleTuiSubmit(controller, line, images),
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
        pathCandidates: pathCandidatesFor,
        onHubAction: (action, key) => _onHubAction(action, key),
        readClipboardImage: () => readPasteboardImage(),
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

  /// Replays the transcript when the TUI opens on a restored session.
  Future<void> _replayRestoredSession() async {
    final resumedLabel = await _resumedSessionLabel();
    if (resumedLabel != null) {
      _replayRestoredHistory(_agent.state.messages, resumedLabel);
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
    pluginSlashDescriptions: _pluginSlashDescriptions,
    extSlashCommands: _ext.slashCommands,
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
    'theme': (key) => _applyThemeChoice(key, persist: true),
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

  /// A sessions-picker selection (issue #198): `flat`/`tree` flips the
  /// view and reopens; `r<index>` resolves through the most recent
  /// picker's row list.
  Future<void> _tuiPickSession(String key) async {
    if (key == 'flat' || key == 'tree') {
      _sessionPickerFlat = key == 'flat';
      return _openSessionsPicker();
    }
    if (!key.startsWith('r')) return;
    final rows = _lastSessionRows;
    final row = rows == null
        ? null
        : listItemAt(rows, int.tryParse(key.substring(1)) ?? -1);
    if (row == null) return;
    final metadata = row.metadata;
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
  /// `saved:<name>` opens a saved provider's edit/delete picker,
  /// `ext:<name>:<id>` runs that extension's provider flow (AC5; namespaced
  /// keys can never shadow the bare core ids), anything else is a catalog
  /// provider name.
  Future<void> _tuiPickProvider(String key) async {
    if (key == 'add') return _openAddProviderPicker();
    if (key.startsWith('saved:')) return _tuiPickSavedProviderEdit(key);
    await _tuiPickExtOrCatalog(key);
  }

  /// An `ext:<name>:<id>` key runs that extension's provider flow (AC5;
  /// namespaced keys can never shadow the bare core ids).
  Future<void> _tuiPickExtOrCatalog(String key) async {
    if (key.startsWith('ext:')) return _startExtProviderFlow(key);
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

  /// The rows shown by the most recent `/sessions` picker (issue #198), so
  /// a picker selection resolves to metadata without a second round trip.
  List<SessionListRow>? _lastSessionRows;

  /// Whether the sessions picker shows the flat single-level list instead
  /// of the tree (toggled from the picker's first item).
  bool _sessionPickerFlat = false;

  Future<void> _openSessionsPicker() async {
    final List<SessionMetadata> sessions;
    try {
      // List every session in the shared root, across all workspaces, so a
      // session created in the Fa app or in another `fa` run is reachable.
      // The current folder's sessions lead the list (issue #83).
      sessions = sortSessionsCurrentFolderFirst(await _repo.list(), _env.cwd);
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
    _lastSessionRows = await _sessionPickerRows(sessions);
    _tuiController?.openPicker(
      'sessions',
      'Sessions',
      // The view toggle rides the first item (issue #198 open question:
      // remembered per run, not persisted).
      sessionPickerItems(_lastSessionRows!, flat: _sessionPickerFlat),
    );
    // For the picker tests: the items the picker opened with.
    sessionPickerItemsForTest = sessionPickerItems(
      _lastSessionRows!,
      flat: _sessionPickerFlat,
    );
  }

  /// Tree-grouped picker rows (children nested under their parent, issue
  /// #198), or the flat single-level rows while toggled.
  Future<List<SessionListRow>> _sessionPickerRows(
    List<SessionMetadata> sessions,
  ) async {
    return buildSessionListRows(
      sessions: sessions,
      flat: _sessionPickerFlat,
      names: await sessionDisplayNames(_repo, sessions),
      currentSessionPath: (await _session?.getMetadata())?.path,
    );
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

  /// Same-named matches pending a startup choice: set when `--session X`
  /// resolved ambiguously, consumed by [_runTuiRepl] to offer the sessions
  /// picker scoped to these matches once the TUI owns the screen.
  List<SessionMetadata>? _startupAmbiguousSessions;
  String? _startupAmbiguousName;

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
  Future<int> runHeadless(
    String prompt, {
    List<ImageContent> images = const [],
    HepWriter? hep,
    bool waitForJobs = false,
  }) async {
    _hep = hep;
    // Cube cache restore, mirroring [run]'s boot (the headless run sees the
    // same cached trees a REPL session would).
    await _cubeBootRestore();
    _session = await _initializeSession();
    // Ownership lease (#428, E7): a headless run NEVER spawns a second
    // writer over a live lease — it refuses with the banner (exit 3) so
    // wake loops reopen interactively instead of fighting the owner.
    // Restart honesty (issue #450): detached jobs from the previous run.
    await _waiting.captureLostJobs();
    final leaseBlocked = await _claimSessionLeaseHeadless();
    if (leaseBlocked != null) {
      io.writeln(viewerBannerText(leaseBlocked, stale: false));
      return 3;
    }
    if (hep != null) {
      hep.writeHeader(
        sessionId: _session!.cachedId ?? (await _session!.getMetadata()).id,
      );
    }
    // Issue #332: rehydrate/settle the subagent registry exactly like the
    // interactive [run] boot. A headless run (a wake run, a restart) used
    // to start from an EMPTY registry, so zombie 'running' rows from the
    // previous process were never settled here AND the headless run's
    // first spawn persisted a snapshot that REPLACED the old rows. Awaited
    // before the prompt: any spawn the run triggers must see the loaded
    // registry instead of racing it.
    await _subagentManager.rehydrate();
    // Session scope (tools.yaml next to the session file) is live now.
    unawaited(AgentCliTools(this).rebuildToolAvailability());
    // Sleep prevention (#325/#326) — headless wraps exactly ONE run, so
    // both holds bracket it the same way: session-held acquires on the
    // session open, per-run on the run start (the prompt below).
    await acquirePowerAssertions();
    runPowerAssertionsStarted();
    // Warm the endpoint metadata (model list, dial features, reported
    // limits) BEFORE the first turn; failures are silent.
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
    final hepSub = hep == null ? null : _agent.subscribe(hep.handleEvent);
    // Terminal-outcome capture (issue #413): the visible transcript is
    // REBUILT by post-run compaction (checkpoint records replace the
    // assistant turns entirely), so the exit code cannot be derived from
    // `state.messages` — the last completed turn's stop reason is taken
    // from the turn events as they fire, before any folding.
    StopReason? terminalStopReason;
    final turnSub = _agent.subscribe((event, _) {
      if (event is TurnEndEvent) {
        terminalStopReason = event.message.stopReason;
      }
    });
    _headlessMode = true;
    try {
      if (images.isEmpty) {
        await _agent.prompt(_redactUserText(prompt));
      } else {
        // --attach (issue #155): the files ride the first user message as
        // image content blocks next to the (redacted) prompt text.
        await _agent.promptMessage(
          UserMessage(
            content: [
              TextContent(text: _redactUserText(prompt)),
              ...images,
            ],
            timestamp: DateTime.now(),
          ),
        );
      }
      // Settle the finished turn exactly like the REPL's [_runPrompt]
      // (issue #413): the over-window guard's one-shot compaction +
      // continuation used to be REPL-only, so a headless run that
      // exhausted the window mid-task abandoned it and exited — the
      // freed window was never used.
      final lastMessage = _agent.state.messages.lastOrNull;
      final finished = await _settleAfterPrompt(
        lastMessage,
        isAutoContinue: false,
      );
      // Awaits any in-flight TTSR retry chain, persists the messages, and
      // auto-compacts — the same end-of-turn sequence as a REPL run. The
      // continuation paths recurse through [_runPrompt], which finalizes
      // with its own [_afterRun]; only a normally-finished turn does.
      if (finished) await _afterRun();
      await _awaitHeadlessBackgroundJobs();
      // Visible waiting (issue #450): stay for the waiters when opted in,
      // otherwise print the honest detach summary before exiting.
      await _waiting.waitForJobsOrSummarize(waitForJobs: waitForJobs);
    } catch (error) {
      io.writeln(
        _keyStatusView.errorLine('$error', _agent.state.model.baseUrl),
      );
      return 1;
    } finally {
      _headlessMode = false;
      _autoFoldCount = 0;
      turnSub();
      await releasePowerAssertions();
      await _cubeCacheSaveQuietly();
      await interruptSub.cancel();
      await taskSub.cancel();
      hepSub?.call();
    }
    // The exit code describes the LAST completed turn's terminal outcome
    // (captured from the turn events above) — not the visible transcript,
    // which post-run compaction rebuilds: the checkpoint fold drops the
    // assistant turns entirely, and the classic trim marker lands after
    // the error stop; both used to mask a failed run as exit 0 (issue
    // #413).
    return switch (terminalStopReason) {
      StopReason.error => 1,
      StopReason.aborted => 130,
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
    red: tuiError,
    secureKeys: config.secureKeys,
    customProviders: config.customProviders,
    envVarIsSet: config.envVarIsSet,
    envVarValue: config.envVarValue,
  );

  Future<void> _handleLine(
    String line, {
    List<TuiImageAttachment> images = const [],
  }) async {
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
        await _dispatchInput(line, trimmed, images);
        return;
      }
      _steerResolved(trimmed, images: images);
      return;
    }
    await _settled;
    await _dispatchInput(line, trimmed, images);
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
  Future<void> _dispatchInput(
    String line,
    String trimmed,
    List<TuiImageAttachment> images,
  ) async {
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
    // Viewer mode (#428): plain input is composer mail to the driving
    // agent — never a second writer, never a takeover.
    if (_viewer != null) {
      await _viewerSend(line);
      return;
    }
    // A new user message ends the previous turn: per-turn skill tool grants
    // (`allowed-tools`) do not leak into it. The skill path re-grants after
    // this clear (it goes through `/skill:` / the slash alias above).
    _approval.clearTurnGrants();
    _startRun(line, images: images);
  }

  void _startRun(String text, {List<TuiImageAttachment> images = const []}) {
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
    // Issue #429: a new agent turn opens a fresh board bucket — jobs from
    // this turn collapse/count together and older buckets age out.
    _jobBoard.newTurn();
    // Issue #514: a fresh run starts unstalled — the previous run's stall
    // episode must never leak into the new bracket.
    _setRunStalled(false);
    // Per-run sleep prevention (#326): the default hold acquires with the
    // run going in flight — fire-and-forget, never a reason to delay the
    // turn.
    runPowerAssertionsStarted();
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
    final settled = _runPrompt(resolved, images: images);
    _settled = settled;
    unawaited(
      settled.whenComplete(() {
        _tuiController?.sendBusy(false, source: 'run');
        _runStarting = false;
        // Per-run sleep prevention (#326): the run has fully settled —
        // drop the assertion so an idle agent lets the machine sleep.
        unawaited(runPowerAssertionsSettled());
        _setRunStalled(false);
        // The fold badge clears at settle whatever the outcome (issue
        // #438 AC3 «until the turn settles»; #653 — error settles too).
        _autoFoldCount = 0;
        _settleLeftoverSteering();
        // Waiting-row refresh (issue #450): the busy→idle edge is where
        // the waiting row takes over from the busy row (E3/E4).
        unawaited(_waiting.push());
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

  /// The continuation prompt for an over-window resume, naming what the
  /// compaction hid — record kinds + turn spans — and how to recover it
  /// via `compact_expand` (issue #438 AC4). Nothing hidden (classic
  /// compaction) keeps the fixed notice.
  Future<String> _overWindowContinuationPrompt() async {
    final session = _session;
    final recoverables = session == null
        ? ''
        : hiddenRecoverablesSummary(await session.getEntries());
    if (recoverables.isEmpty) return _overWindowContinuationNotice;
    return _overWindowContinuationNotice.replaceFirst(
      '</system-notice>',
      '$recoverables\n</system-notice>',
    );
  }

  /// Whether the over-window guard's one-shot auto-continuation was used
  /// for the current user prompt (reset at every non-auto-continue
  /// [_runPrompt] entry).
  bool _overWindowAutoResumed = false;

  /// Auto-compaction folds this run (issue #438 AC3): the status badge
  /// «[auto-compacted · continuing]» shows while the run continues after
  /// a mid-run fold and clears when the turn settles.
  int _autoFoldCount = 0;

  /// Test seam: every busy-row phase pushed, in order (issue #653 — the
  /// fold marker must never ride the busy row; see `_pushBusyPhase` in
  /// agent_cli_compaction.dart, the status row carries the badge).
  @visibleForTesting
  final List<String> busyPhasesForTest = [];

  /// Whether this CLI instance is inside a headless (`fa "prompt"`, `-p`)
  /// run — guards the REPL-only recovery flows (browser SSO re-auth) from
  /// firing where no human can complete them. The settle path itself
  /// (issue #413) stays shared with the REPL.
  bool _headlessMode = false;

  /// Runs one prompt turn: pre-flight ([_beginUserPrompt]) → the agent
  /// stream → outcome settle ([_settleAfterPrompt], `true` = turn finished
  /// normally) → finalize ([_afterRun]); thrown errors land in
  /// [_handleRunError]. Auto-continuations recurse with [isAutoContinue]
  /// set, which skips the pre-flight phases.
  /// Masks secrets in user prompt text before it reaches the agent (and
  /// therefore the session JSONL) — issue #24 AC8. No-op without a
  /// pipeline (hosts without the redact wiring).
  String _redactUserText(String text) {
    final pipeline = config.redactionPipeline;
    if (pipeline == null) return text;
    return redactPrompt(pipeline, text);
  }

  Future<void> _runPrompt(
    String text, {
    bool isAutoContinue = false,
    List<TuiImageAttachment> images = const [],
  }) async {
    await _beginUserPrompt(isAutoContinue: isAutoContinue);
    try {
      if (images.isEmpty) {
        await _agent.prompt(_redactUserText(text));
      } else {
        // Clipboard chips (issue #276): the images ride the user message
        // as ImageContent blocks next to the text — same shape as --attach.
        await _agent.promptMessage(
          UserMessage(
            content: [
              TextContent(text: _redactUserText(text)),
              for (final image in images)
                ImageContent(
                  data: base64Encode(image.bytes),
                  mimeType: image.mimeType,
                ),
            ],
            timestamp: DateTime.now(),
          ),
        );
      }
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
    // Wall-clock catch-up (issue #259): records that came due while the
    // host slept (or while no tick ran) are delivered HERE, at turn start —
    // awaited before the prompt so this turn's first steering poll already
    // sees the fired reminder, instead of waiting for the next timer tick.
    try {
      if (await _scheduledMessages.deliverDue() > 0) {
        unawaited(_pushScheduledStatus());
      }
    } on Object {
      // Best-effort: a broken sweep must never block a turn.
    }
    if (isAutoContinue) return;
    _overWindowAutoResumed = false;
    // A fresh user text clears the over-window badge: the new run starts
    // clean, and only THIS run's folds may badge it (issue #438 E1).
    _autoFoldCount = 0;
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
        tuiWarning(
          'note: could not free the context window — run /compact or '
          'start a fresh session',
        ),
      );
      return false;
    }
    io.writeln(
      tuiWarning('[context overflowed — auto-compacted; continuing the turn]'),
    );
    // Issue #673 AC4: ANY failure inside the continuation machinery (the
    // recoverables scan over the resident set, the notice build, the
    // resumed prompt's pre-flight) surfaces as a NAMED error and leaves
    // the session resumable — never a bare "Null check operator used on a
    // null value" line killing the turn.
    try {
      final prompt = await _overWindowContinuationPrompt();
      await _runPrompt(prompt, isAutoContinue: true);
    } on Object catch (error) {
      _logDiagnostic('over-window continuation failed sid=$_logSid: $error');
      io.writeln(tuiError('error: compaction continuation failed: $error'));
    }
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

  /// Handles a CodeMie auth-session expiry if [message] matches one. Returns
  /// `true` when the expiry was handled and the turn is finished.
  Future<bool> _maybeHandleCodeMieError(String message) async {
    // Headless: the browser SSO re-auth awaits a human that is not there —
    // surface the error instead and let the exit code carry the failure.
    if (_headlessMode) return false;
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
    io.writeln(tuiError('error: $stripped'));
    io.writeln(
      tuiWarning(
        'CodeMie session expired — opening browser to re-authorize...',
      ),
    );
    final orgUrl = codeMieOrgUrl(_agent.state.model.baseUrl);
    await _handleCodeMieSsoCommand(orgUrl);
    if (!_exited) {
      io.writeln(tuiSuccess('Re-authorized. Repeat your message to continue.'));
    }
  }

  /// Delivers a background-subagent heartbeat digest (issue #383) through
  /// the SAME channel as completion notices: busy → the steering queue
  /// (delivered at the next step boundary, the turn is never aborted);
  /// idle → a fresh run (the parent wakes). Text-only — the digest never
  /// spawns or cancels anything.
  void _deliverHeartbeatDigest(String digest) {
    if (_exited) return;
    if (isBusy) {
      _agent.steer(UserMessage.text(digest));
    } else {
      _startRun(digest);
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
      tuiWarning(
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
    _hubCompletePanels();
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
    return CompactionSettings.forWindow(_effectiveContextWindow);
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
