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
import '../agent/misuse_breaker.dart';
import '../dap/dap_hub_snapshot.dart';
import 'agent_event_handler.dart';
import 'ansi_markdown.dart';
import 'path_candidates.dart';
import 'slash_args.dart';
import 'status_line_git_probe.dart';
import 'tui_status_line.dart'
    show
        StatusLineConfig,
        StatusLineSnapshot,
        TuiStatusLine,
        resolveStatusLineSpec;
import 'browser_bridge_commands.dart';
import '../browser/browser_tools.dart';
import 'headless_prompt.dart';
import 'hep.dart';
import 'stream_json.dart';
import 'key_event.dart';
import 'key_status.dart';
import 'provider_error_text.dart';
import 'sigint_action.dart';
import '../agent/agent_loop.dart';
import '../agent/finalize_gate.dart';
import '../session/windowed_session_storage.dart' show WindowedSessionStorage;
import '../trajectory/event_projection.dart'
    show TrajectoryHiddenRecordPreview, projectHiddenRecordPreviews;
import '../trajectory/trajectory_record.dart' show TrajectoryCompactedRecord;
import '../trajectory/trajectory_blobs.dart';
import '../agent/agent_tool.dart';
import '../agent/auto_compactor.dart';
import '../agent/stuck_tool.dart';
import '../providers/models_for_endpoint.dart';
import '../agent/tool_registry.dart';
import '../utils/list_equals.dart';
import '../a2a/a2a_config.dart';
import '../a2a/a2a_manager.dart';
import '../task/task.dart';
import 'agent_tree.dart';
import 'agent_hub_panel.dart';
import 'shell_job_board.dart';
import 'subagent_board.dart';
import 'agent_hub_projection.dart';
import 'agent_hub_tui.dart';
import 'waiting_heartbeat.dart';
import 'tool_liveness.dart';
import 'reasoning_liveness.dart';
import 'log_fidelity.dart';
import 'agent_hub_view.dart';
import '../task/agent_discovery.dart';
import '../task/child_session_io.dart';
import '../task/subagent.dart';
import '../task/subagent_manager.dart';
import '../task/subagent_scope.dart';
import '../task/subagent_heartbeat.dart';
import '../task/subagent_tools.dart' show cancelSubagentWithoutJob;
import '../task/delivery_slo.dart';
import '../skills/builtin_skills.dart';
import '../skills/skill_availability.dart';
import '../skills/skills.dart';
import '../skills/operative_pins.dart' show operativePinNotice;
import '../skills/skill_renderer.dart';
import '../prompts/prompts.g.dart'
    show
        cliMessagingSectionPrompt,
        readSqliteSectionPrompt,
        cliPiModePrompt,
        finalizeGateContractPrompt;
import '../prompts/project_context.dart';
import '../approval/approval.dart';
import '../wire/wire_serve.dart';
import '../approval/approval_hook.dart';
import '../cancel_token.dart';
import '../compaction/compaction.dart';
import '../compaction/host_wiring.dart';
import '../compaction/structured/continuation_notice.dart';
import '../compaction/token_estimation.dart';
import '../context.dart';
import '../cube/cube.dart';
import '../env/cwd_override_env.dart';
import '../env/execution_env.dart';
import '../env/session_vars_execution_env.dart';
import '../hosts/host_agent_wiring.dart';
import '../hosts/host_capability_profile.dart';
import '../hosts/host_extension_api.dart';
import '../hosts/host_wiring_builder.dart';
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
import '../providers/thinking.dart';
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
        sharedProviderHttpClient,
        stripAuthExpiredMarker,
        textOnlyImageDropNotice;
import '../providers/transient_retry_stream.dart';
import '../prompts/prompt_overrides.dart';
import '../providers/aiin_auth.dart';
import '../providers/quota.dart';
import '../providers/quota_codemie.dart';
import '../providers/quota_openrouter.dart';
import '../providers/quota_service.dart';
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
import 'pi_mode.dart';
import 'custom_providers.dart';
import 'folder_model_state.dart';
import 'provider_flow.dart';
import '../session/session_storage.dart';
import '../session/ledger_caps.dart';
import '../session/obligations_ledger.dart';
import '../session/session_tree.dart';
import 'session_tree.dart';
import '../trajectory/trajectory_snapshot.dart';
import 'trajectory_tui.dart';
import '../tools/availability.dart';
import '../tools/availability_gate.dart';
import '../tools/discover_tools_tool.dart';
import '../tools/load_modes.dart';
import '../tools/ask_tool.dart';
import '../tools/request_secret_tool.dart';
import '../tools/builtin_tools.dart';
import '../tools/checkpoint_tool.dart';
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
import '../messaging/agent_message.dart';
import '../messaging/file_messaging_repository.dart';
import '../messaging/inbox_wake_policy.dart';
import '../messaging/messaging_repository.dart';
import '../messaging/scheduled_messages.dart';
import '../messaging/scheduled_receipts.dart';
import '../plugins/plugin.dart';
import '../redact/redaction_cli.dart';
import '../redact/redaction_hooks.dart';
import '../redact/redaction_pipeline.dart';
import '../redact/redaction_types.dart';
import '../spill/spill.dart';
import '../ttsr/ttsr.dart';
import '../types.dart';
import '../usage/usage_chain.dart';
import '../usage/usage_ledger.dart';
import '../usage/usage_ledger_io.dart';
import '../usage/usage_log_line.dart';
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
import 'jsr_cli.dart';
import 'prompt_templates.dart';
import 'ask_menu.dart';
import 'slash_menu.dart';
import 'task_list.dart';
import 'model_picker_table.dart';
import 'tui_key_hints.dart';
import 'text_format.dart';
import 'terminal_setup.dart';
import 'tui_helpers.dart';
import 'tui_prompt.dart';
import 'scripted_test_stream.dart';
import 'tui_replay.dart';
import 'tui_repl.dart';
import 'tui_theme.dart';
import 'tui_chrome.dart';
import 'termios_guard.dart';

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
part 'settings_flow_auto_update.dart';
part 'settings_flow_harness_mode.dart';
part 'settings_flow_model_caps.dart';
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
part 'agent_cli_subagent_board.dart';
part 'agent_cli_mcp_print.dart';
part 'agent_cli_commands.dart';
part 'agent_cli_ext.dart';
part 'agent_cli_jsr.dart';
part 'agent_cli_theme.dart';
part 'agent_cli_composer.dart';
part 'agent_cli_spill.dart';
part 'agent_cli_prompt.dart';
part 'agent_cli_repl_boot.dart';
part 'agent_cli_wire_serve.dart';
part 'agent_cli_diag_log.dart';
part 'agent_cli_lifecycle.dart';
part 'agent_cli_input.dart';
part 'agent_cli_pickers.dart';
part 'agent_cli_run.dart';
part 'agent_cli_usage_ledger.dart';

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
    MarkdownSurface? markdownSurface,
    DateTime Function()? waitingClock,
    Future<void> Function(Duration)? waitingSleep,
    SigintPolicy? sigintPolicy,
  }) : io = useTui && io.supportsRawMode ? _TuiCliIO(io) : io,
       _style = _Style(enabled: useColor),
       _markdownSurface = markdownSurface ?? const MarkdownSurface(),
       _waitingClock = waitingClock ?? DateTime.now,
       _waitingSleep =
           waitingSleep ?? ((Duration d) => Future<void>.delayed(d)),
       _useTui = useTui && io.supportsRawMode,
       sigintPolicy = sigintPolicy ?? SigintPolicy() {
    // Sleep prevention (issue #325): null runner (tests, web) → none.
    _powerAssertions = sessionPowerAssertions(config, this.io.writeln);
    _env = CwdOverrideEnv(config.env);
    _modes = builtInAgentModes(_env.cwd, overrides: config.promptOverrides);
    _currentMode = _modes[config.initialMode] ?? _modes['code']!;
    _providerKind = config.providerKind;
    _apiKey = config.apiKey;
    _liveLoadMode = config.loadMode;
    // The boot-restored saved provider entry (the folder state's name pin,
    // gh-1000): the CLI starts with that entry active — its key slot
    // serves the restored model and its name shows in the status bar.
    _activeCustomName = config.activeCustomName;
    // The theme emitters' color profile: the surface's pinned palette
    // (the host's single resolution, issue #774) wins; otherwise styled
    // iff this session styles at all (TUI or colored line mode), with
    // NO_COLOR / TERM=dumb degrading to plain output (issue #279 AC7).
    FaThemeController.instance.profile =
        _markdownSurface.profile ??
        detectThemeProfile(
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

    // Issue #1079 slice 2: the core stack — env chain, capability-gated
    // core tools, registry, agent — is wired by the shared builder over
    // the CLI profile and this host's typed services. The shell keeps
    // process glue + callbacks only.
    _snapshotStore = HashlineSnapshotStore();
    final wired = wireAgentCore(
      profile: cliProfile,
      services: AgentCoreServices(
        baseEnv: _env,
        sessionEnvVars: _sessionEnvVars,
        sandbox: SandboxServices(
          spec: config.cubeSpec,
          homeDir: config.homeDir,
          os: config.osName,
          pathProbe: config.fsProbe,
          onWarning: (message) => io.writeln(tuiWarning(message)),
        ),
        snapshots: _snapshotStore,
        webSearch: config.webSearchConfig,
        sqlite: config.sqliteEngine,
        lsp: config.lspConfig,
        mcp: _mcp.manager,
        shellJobsFactory: (coreEnv) => ShellJobRegistry(
          env: coreEnv,
          onSettled: AgentCliShellJobSettle(this)._onShellJobSettled,
          onStart: _onShellJobStarted,
          onStaleJobLog: _onStaleJobLog,
          jobLogMaxBytes: config.jobs.maxLogBytes,
          onJobLogWarning: _onJobLogWarning,
          // Issue #1408 AC1: the bench boot relocates the job-log dir via
          // FAH_JOB_LOG_DIR so nothing harness-owned lands in the graded
          // task workspace.
          jobLogDir: config.jobLogDir,
          // Issue #1408 AC2: job logs are secret-redacted at rest with the
          // same pipeline that masks tool results.
          jobLogRedactor: config.redactionPipeline == null
              ? null
              : (String text) => config.redactionPipeline!.redact(text),
        ),
        onPasswordPrompt: io.isInteractive ? _answerPasswordPrompt : null,
        // Issue #1408 AC3 (review 5456649624): the same `redact:` section
        // steers the bash shape interceptor — the boot-resolved pipeline
        // config when redaction is on, a disabled config when it is off
        // (job logs raw ⇒ commands untouched). Registered secrets are
        // exempt from command rewriting so approved values materialize.
        redactionConfig:
            config.redactionPipeline?.config ??
            const RedactionConfig(enabled: false),
        approvedSecretLiterals: () =>
            config.redactionPipeline?.registeredSecrets.toSet() ?? const {},
        configServiceFactory: (coreEnv) =>
            ConfigService(env: coreEnv, homeDir: config.homeDir),
        memory: _memory,
        onMemoryChanged: () => unawaited(_refreshMemorySection()),
        scheduledMessages: _scheduledMessages,
        scheduleSenderMailbox: _childSenderMailbox,
        onAsk: io.isInteractive ? _answerAskQuestions : null,
        onRequestSecret: io.isInteractive ? _answerSecretRequest : null,
        // gh-1412: the request_secret decline path keys its credential-hunt
        // nudge on the LIVE approval mode (a runtime `/approval` switch
        // flips it without a restart).
        isUnattended: () => _approval.mode == ApprovalMode.unattended,
        vision: config.visionConfig,
        transcribe: config.transcribeConfig,
        media: MediaToolServices(
          modelsConfig: config.modelsConfig,
          mainApiKey: () => _apiKey,
          resolveKey: _resolveMediaKey,
        ),
        browserController: config.browserController,
        // Builder hands the decorated env (review #1230) — screenshot
        // saves clamp like every other fs-touching tool.
        saveBrowserScreenshot: saveBrowserScreenshot,
        // The CLI's plugin tools ride the declared extension surface
        // (issue #1079 slice 4): on for this shell's profile, off with a
        // named reason everywhere else — a host adopting another profile
        // declares its own extensions.
        extensions: [
          HostExtension(
            name: 'cli-plugins',
            tools: pluginTools,
            profileStates: {
              for (final profile in builtInProfiles.keys)
                profile: profile == cliProfile.name
                    ? const CapabilityOnState()
                    : const CapabilityOffState(
                        'plugin registration is a CLI-shell surface '
                        '(.fah/packages.yaml / --plugin); declare your own '
                        'extension for this host',
                      ),
            },
          ),
        ],
        obligationsClose: (id, status) => closeObligation(id, status),
        hubFabric: config.hubFabric,
        // Hub mail merges into the MAIN inbox — lazily, so the manager
        // (constructed inside the builder) may not exist yet.
        mainMailbox: () => _subagentManager.mailboxOf('main'),
        subagents: SubagentServices(
          homeDir: config.homeDir,
          machineName: config.machineName,
          a2a: config.a2aConfig,
          wakeProcess: _launchMailboxWake,
          // The registry persists into the parent session as
          // `subagent_registry` custom records, so a resumed session
          // rehydrates its agents. Issue #488 AC2: the snapshot is read
          // by RAW file scan (the windowed boot open drops side-leaf
          // custom records out of getEntries — the registry used to come
          // back EMPTY on every restart) and transcript-only children
          // are adopted, so task_send/task_resume address pre-restart
          // children.
          registrySink: (registry) async {
            final session = _session;
            if (session == null) return;
            await session.appendCustomEntry(
              customType: subagentRegistryRecordType,
              data: registry,
            );
          },
          registrySource: () async {
            final session = _session;
            if (session == null) return const [];
            return subagentRegistryRows(
              repo: _repo as JsonlSessionRepo,
              parent: await session.getMetadata(),
            );
          },
          // Issue #383: the heartbeat rides the steering channel — the
          // getters consult the config EVERY tick, so a config rewrite
          // applies at the next digest without a restart (E6).
          notifyHeartbeat: _deliverHeartbeatDigest,
          heartbeatMinutes: () => config.subagents.heartbeatMinutes,
          stallMinutes: () => config.subagents.stallMinutes,
          rolesResolver: config.modelRolesResolver,
          // Issue #439: children compact on the host's engine choice
          // (live settings override, else config, else default).
          compactionEngine:
              config.liveCompactionEngine ?? config.compactionEngine,
          // Issue #862: the `agent.misuseBreaker` switch covers children.
          misuseBreaker: config.misuseBreaker,
          // Real JSONL child sessions, created at child completion (fast
          // register keeps the steering race away; the transcript lands
          // when the child finishes).
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
          // Issue #427: the task-resume reopen of a child's session file
          // rides the same transient-ENOENT retry, logged to fa.log.
          sessionIoRetry: SessionIoRetryConfig(logger: _logDiagnostic),
        ),
        extRuntimeFactory: config.extRuntimeFactory,
        sessionRoot: config.sessionRoot,
      ),
    );
    _cubeEnv = wired.sandboxEnv!;
    _webNetworkGate = wired.networkGate;
    _coreToolEnv = wired.env;
    _shellJobs = wired.shellJobs!;
    _cubeSource = config.cubeSource;
    // Issue #1079 slice 3: the messaging fabric, subagent manager,
    // heartbeat and the task/monitoring surface are assembled by the
    // shared builder, gated by the messagingFabric/subagents
    // capabilities. The shell keeps only its callbacks — session
    // persistence, the wake launcher, heartbeat delivery, child-session
    // minting (passed as services above).
    _fabricRepository = wired.fabric!;
    _fileFabric = wired.fileFabric!;
    _messagesRoot = wired.messagesRoot!;
    _subagentManager = wired.subagentManager!;
    _a2aManager = wired.a2aManager!;
    _subagentHeartbeat = wired.subagentHeartbeat!;
    _taskConfig = wired.taskConfig!;
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
    // Registry + agent: assembled by the shared builder (issue #1079
    // slices 2+3) — core tools, then the gated task/monitoring surface,
    // exactly the pre-conversion registration order.
    final stack = wired.buildAgentStack(
      onDuplicate: (note) {
        // Issue #862 review: a duplicate registration (e.g. a host passing
        // child-injected tools through the parent surface) must be loud.
        io.writeln(_style.dim('[fah] warning: $note'));
      },
      streamFunction: _streamFunction,
      spec: AgentWiringSpec(
        model: config.model,
        systemPrompt: config.systemPrompt ?? _currentMode.systemPrompt,
        // The CLI handles empty-response retries itself with a 'continue'
        // nudge so the transcript reflects the retry explicitly.
        maxEmptyRetries: 0,
        // Post-mortem "who held the busy row": the run idle watchdog's fire
        // lands in fa.log with the session id.
        onRunIdleTimeout: (error) =>
            _logDiagnostic('RUN IDLE WATCHDOG fired sid=$_logSid error=$error'),
        // Issue #1085 M3: the watchdog PAUSE (mid-run relief compaction) is
        // a visible dim note, not only a fa.log line — a quiet stretch the
        // user can now attribute.
        onRunWatchdogPaused: () => io.writeln(
          _style.dim('watchdog paused — over-window compaction in progress'),
        ),
        contextWindowCap: config.contextWindowCap,
        stuckTool: config.effectiveStuckTool(),
        wireDump: config.wireDump,
        // Issue #387: the loop's over-window guard hands the transcript to
        // this relief before refusing — one synchronous compaction pass.
        overWindowRelief: (overWindow) => _relieveOverWindow(overWindow),
        // Issue #862: tool-misuse circuit breaker (off switch:
        // `agent.misuseBreaker: false`).
        toolMisuseBreaker: config.misuseBreaker ? ToolMisuseBreaker() : null,
      ),
    );
    _toolRegistry = stack.registry;
    _agent = stack.agent;
    // The FinalizeGate (gh-1412): unattended sessions (the bench / headless
    // autopilot mode) emit the task ledger — the loop parses the final
    // answer's `task-ledger` block and the CLI persists it as a hidden
    // `task_ledger` session record. Interactive sessions stay off
    // (byte-identical, no prompt noise).
    _agent.finalizeGate = config.approvalMode == ApprovalMode.unattended;
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
    // Issue #735: tool children share the session tty and can silently
    // re-enable IXON — Ctrl+S then freezes output as XOFF and never
    // reaches the agent as steering. Re-assert the raw-mode input flags
    // after every foreground tool phase; a drift note names the child.
    // OWNERSHIP GATE: only the TUI owns raw mode on the session tty. The
    // interactive line REPL and `fa -p` run cooked — icrnl/ixon are
    // SUPPOSED to be on there, and clearing them kills Enter (no CR→NL
    // in canonical mode) with nothing restoring them (PR review
    // PRRT_kwDOTXdlLc6kMBZH). The gate also covers injected-runner
    // seams: line-mode tests must observe zero probes.
    _termiosGuard = TermiosGuard(
      runner: config.sttyRunner,
      hasTerminal: () => _useTui,
    );
    attachTermiosGuard(_agent, _termiosGuard, onDrift: _noteTermiosDrift);
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
      // gh-1425 AC4: a user turn that auto-closes a checkpoint restores the
      // full detour history live — the budget guard caps it (same window −
      // reserve budget as the boot cap) before the next request.
      onAutoClose: _guardCheckpointRestoreBudget,
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

  /// The active saved custom provider entry's name, or null when the
  /// session runs on a catalog provider or an explicit token. Hosts
  /// persist it with the model triple so a restore can re-pin the same
  /// account (gh-1000).
  String? get activeCustomProviderName => _activeCustomName;

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

  /// Test seam for the TUI provider-picker selection: routes `add`,
  /// `saved:<name>`, `ext:<name>:<id>`, and catalog keys exactly like the
  /// live picker (`_tuiPickProvider`).
  @visibleForTesting
  Future<void> tuiPickProviderForTest(String key) => _tuiPickProvider(key);

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

  /// Test seam: builds the real slash-menu completion items for [prefix]
  /// (commands, templates, skills) without a TUI.
  @visibleForTesting
  List<MenuItem> slashMenuForTest(String prefix) => _buildSlashMenu(prefix);

  /// The items the most recent sessions picker opened with (see
  /// [openSessionsPickerForTest]).
  @visibleForTesting
  List<MenuItem>? sessionPickerItemsForTest;

  /// Test seam routing a sessions-picker selection in line mode.
  @visibleForTesting
  Future<void> tuiPickSessionForTest(String key) => _tuiPickSession(key);

  /// Test seam: swaps the active session so command paths can be driven
  /// over a session shape the real repo never produces (e.g. empty
  /// metadata path — the usage-ledger command guards).
  @visibleForTesting
  set sessionForTest(Session? session) => _session = session;

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

  /// Issue #735: re-asserts the raw-mode tty input flags after every
  /// foreground tool phase (children sharing the tty can re-enable IXON,
  /// which eats Ctrl+S as XOFF and freezes output). Never throws; no-ops
  /// without a terminal. Exposed for the hidden `/termios` command.
  late final TermiosGuard _termiosGuard;

  /// The sandboxed view over [_env]: clamps filesystem and shell operations
  /// to the active cube (`null` = passthrough). `/cube` manages it live.
  late final SandboxedExecutionEnv _cubeEnv;

  /// Web-egress gate for the web tools (issue #682), derived by the host
  /// wiring builder from the live sandbox spec: `/cube use` / `/cube off`
  /// are honored by the next web tool call; null spec (no cube) is
  /// allow-all. Null only when the profile wires no sandbox.
  late final CubeNetworkGate? _webNetworkGate;

  /// Where the active cube came from — a manifest path or a cube name;
  /// `/cube reload` re-resolves it. Set at boot (config) and by
  /// `/cube use`; never cleared by `/cube off` (a reload re-applies it).
  String? _cubeSource;

  /// Whether the remembered source was activated with `--allow-degrade`
  /// via an explicit `/cube use` (SEC-05: policy-degrade opt-in for
  /// kernel specs); `/cube reload` re-applies it to the re-resolved
  /// spec. Only `/cube use` sets it — a settings-hub selection resets
  /// it, so a degrade can never leak into another source.
  bool _cubeUseAllowDegrade = false;

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

  /// The persisted wake receipts for scheduled mail (gh-1180 AC4): every
  /// wake_attempted / turn_started / wake_refused lands here so a
  /// post-mortem can tell "timer never fired" from "wake refused". A
  /// non-nullable `late final` created alongside the queue (review: the
  /// production wake path is load-bearing on this log — it must never be
  /// null because a lazy initializer has not run yet); the
  /// `@visibleForTesting` getter below is the seam, mirroring the app
  /// host's shape.
  late final ScheduledReceiptLog _scheduledReceipts = _newScheduledReceipts();

  /// Persisted delayed messages (`schedule_message`): pending records live
  /// under `<messagesRoot>/_scheduled/` and are delivered into the
  /// agent's own inbox when due, where the idle-wake starts a turn.
  late final ScheduledMessageQueue _scheduledMessages = _newScheduledMessages();

  /// The visible-waiting layer (issue #450): waiter aggregate, TUI waiting
  /// row push, waiting heartbeat, restart honesty, headless semantics.
  late final _WaitingCoordinator _waiting = _WaitingCoordinator(this);

  /// The subagent status board (gh-1415): composes the retained-subagent
  /// handles into [SubagentStatusRecord]s, keeps the [TaskBoardRegion]
  /// lifecycle, and pushes the TUI's live rows (1 Hz ticker while a row is
  /// live). TUI-only — headless/line mode stay untouched.
  late final _SubagentBoardCoordinator _subagentBoard =
      _SubagentBoardCoordinator(this);

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
  late final ExecutionEnv _coreToolEnv;
  final _ToolsWiringState _toolsWiring = _ToolsWiringState();

  /// The LIVE tool-load preset (issue #680): [AgentCliConfig.loadMode] at
  /// boot; the settings hub's load-mode flow re-assigns it and rebuilds
  /// availability, so a mid-session switch recomposes the schema+prompt.
  AgentLoadMode _liveLoadMode = AgentLoadMode.defaultMode;

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

  /// The markdown→terminal policy every non-TUI surface renders assistant
  /// text through at message end (issue #774). Defaults to raw
  /// passthrough; bin/fah resolves TTY/color/width for the real surfaces.
  final MarkdownSurface _markdownSurface;

  /// The workflow-log-fidelity face for this run (gh-1433): TUI /
  /// interactive line / headless log. Resolved once from the constructor
  /// facts — the pure module is the test seam.
  late final LogFidelityFace _logFace = resolveLogFidelityFace(
    useTui: _useTui,
    headlessRun: config.headlessRun,
  );

  /// The workflow-log-fidelity render defaults for this run (gh-1433):
  /// whether thinking deltas render dimmed and live, and whether text
  /// streams live (the buffered-answer path never applies).
  late final LogFidelity _logFidelity = resolveLogFidelity(
    face: _logFace,
    streamThinkingSetting: config.streamThinking,
    noStreamThinking: config.noStreamThinking,
    envFidelity: environment[logFidelityEnvKey],
  );

  /// Whether this run drives the workflow-log face (gh-1433): a headless
  /// run — `fa -p`, CI, bench, parent-CLI capture — has no repaintable
  /// UI, so the log IS the UI. The post-hoc reader gets the full
  /// narrative (thinking, prose, tools) in positional order.
  bool get _logIsUi => _logFace == LogFidelityFace.log;

  /// The streamed answer of the current assistant message on non-TUI
  /// surfaces (issue #774): line mode and headless cannot repaint, so the
  /// message buffers here and renders once, whole, at message end.
  final StringBuffer _assistantText = StringBuffer();

  /// The AC3 post-tool_use narration holds (gh-1433): once the current
  /// message streams a tool-call block, its later text deltas are
  /// post-call narration — each tool-call block opens a segment, deltas
  /// append to the newest one, and a segment flushes after ITS call's
  /// result row. A 2+ tool-call message therefore keeps positional
  /// order (text → tool line → result → narration → result → …)
  /// instead of draining every segment after the first result. Live
  /// faces only; the TUI keeps today's behavior. (State lives on the
  /// class — the render methods are an extension.)
  final List<_PostToolNarrationHold> _postToolHolds =
      <_PostToolNarrationHold>[];

  /// The E1 leading-whitespace hold (gh-1433): whitespace-only deltas
  /// before the first real text hold here so a whitespace-only narration
  /// block never paints a stray blank line into the log. Flushed (and
  /// dropped when still whitespace-only) at the first real delta or at
  /// message end.
  StringBuffer? _whitespaceHold;

  /// Whether the default role resolved and drives the agent (roles mode).
  /// The banner's key-status line reads env var names from the live model's
  /// provider then; legacy mode reads them from the provider kind.
  var _rolesDriven = false;
  final _usage = UsageAccumulator();

  // Issue #277 hub driver state (see agent_hub_cli.dart): the projection
  // accumulates running spans; the panel log keeps deferred (btw) history;
  // lazy subscriptions keep task-block rendering for hub-less sessions.
  final AgentHubProjection _hubProjection = AgentHubProjection();
  final DeferredPanelLog _hubPanels = DeferredPanelLog();

  /// Issue #429: per-session background-job board (truthful phases,
  /// per-turn collapse, reload records) — replaced wholesale on resume.
  ShellJobBoard _jobBoard = ShellJobBoard();

  /// gh-1073: suppresses byte-identical `shell_job_registry` snapshot
  /// appends (reset in `_rehydrateJobBoard` on every session load).
  final LedgerSnapshotDeduper _jobBoardPersistDeduper = LedgerSnapshotDeduper();

  /// The obligations ledger writer (issue #1380 A1) and the session it was
  /// rehydrated from: cumulative in-memory state reloaded from the
  /// session's latest `obligations_ledger` snapshot, swapped lazily when
  /// the session switches (see `_obligationsWriterFor`).
  ObligationsLedgerWriter? _obligationsWriter;
  Session? _obligationsWriterSession;

  /// Registry-persist serialization tail (issue #539; see `_persistJobBoard` in the driver).
  Future<void> _persistChain = Future.value();
  final DateTime _hubMainStartedAt = DateTime.now();
  String? _hubTranscriptId;
  Timer? _hubFollowTimer;
  StreamSubscription<dynamic>? _hubSubagentEventsSub;
  StreamSubscription<dynamic>? _hubTaskStartsSub;

  /// The subagent status board's registry-event subscription (gh-1415);
  /// cancelled in [_teardownAfterRepl] with the ticker's dispose.
  StreamSubscription<dynamic>? _subagentBoardSub;

  /// Hub tree `mail:N` marker counts (async peek → refresh-only re-push
  /// by the driver extension, which cannot hold fields — state here).
  final Map<String, int> _hubMailCounts = <String, int>{};
  bool _hubMailRefreshInFlight = false;

  // Issue #437 steering delivery: a steer persists at accept and queues
  // here until the loop merges it at a step boundary (identity match) or
  // the settle leftover drops it; wake paths deliver recovered records.
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

  /// The session instance the gh-1241 usage segment-start marker was
  /// appended for in THIS process (null = not yet marked). Lazily set at
  /// first drive (see [_runPrompt]) or eagerly by the headless/serve boot:
  /// an idle owner boot must add zero session bytes (issue #428's
  /// "no idle session bytes" invariant), and a `/sessions` switch must not
  /// mark the new session until it is actually driven. Identity-keyed: a
  /// switch replaces `_session` with a fresh instance, so the next drive
  /// re-marks.
  Session? _usageSegmentMarkedFor;

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

  /// The provider-quota service (issue #823): built lazily on first peek —
  /// no IO at rest. See `quotaFor`/`_quotaSlash` in agent_cli_commands.dart.
  ProviderQuotaService? _quotaService;
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

  /// The [_skills] subset that survived the `skills:` toggle scopes
  /// (issue #1151: global `~/.fah/config.yaml` < project
  /// `.fah/config.yaml`) — the invocation, completion, and prompt
  /// surface. `/skills` keeps listing the full [_skills] so a disabled
  /// entry can render its off-state.
  List<Skill> _enabledSkills = const [];

  /// The availability resolution behind [_enabledSkills] (decisions per
  /// skill name + the unknown toggle ids, warned once per reload).
  SkillAvailabilityResolution _skillResolution =
      const SkillAvailabilityResolution(byName: {}, unknownIds: {});

  /// Toggle ids already warned about — one dim line per distinct id, not
  /// one per reload.
  Set<String> _warnedSkillToggleIds = const {};

  /// The live GLOBAL per-skill toggles (issue #1151): seeded from the
  /// loaded config at first resolution, then owned by
  /// `/skills <name> global` (the host persists them through
  /// [AgentCliConfig.onSkillTogglesChanged]).
  Map<String, bool> _globalSkillToggles = const {};
  bool _globalSkillTogglesLoaded = false;

  /// The last successfully parsed project `skills:` toggles — what
  /// "keeping last good" serves when the project section turns broken
  /// (issue #1151 review; mirrors the tools scope cache).
  Map<String, bool>? _lastGoodProjectSkillToggles;
  List<ProjectContextFile> _contextFiles = const [];

  /// Consent for third-party (Claude/Copilot/Codex) skill & agent roots.
  /// Mutable: the startup consent dialog and `/skills access` change it;
  /// the host persists it via [AgentCliConfig.onSkillsAccessChanged].
  late SkillsAccess _skillsAccess = config.skillsAccess;

  /// gh-1440 skills-freshness state (all derived — the session JSONL stays
  /// byte-identical): the stat-level root fingerprint recorded at the last
  /// discovery scan, the wall-clock stamp the prompt's skills section
  /// renders (`scanned at` — NOT per-composition time, so an unchanged
  /// fingerprint renders byte-identical sections), the lowercase skill
  /// names frozen at the boot scan (the `added mid-session` baseline),
  /// the names at the last scan (the dropped-from-disk note baseline), and
  /// the warn-once latch for freshness-check failures plus the
  /// malformed-file paths already warned about.
  SkillRootsFingerprint? _skillRootsFingerprint;
  DateTime? _skillsScannedAt;
  Set<String>? _bootSkillNames;
  Set<String> _lastScanSkillNames = const {};
  bool _skillsFreshnessWarned = false;
  Set<String> _warnedMalformedSkillPaths = const {};

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

  /// The cached `<memory>` prompt section (durable facts from past
  /// sessions). Loaded asynchronously after startup and refreshed on
  /// every `memory_add` — the prompt composition itself stays
  /// synchronous; the composition code lives in agent_cli_prompt.dart.
  var _memorySection = '';

  /// Reference to the active TUI controller so asynchronous model-list updates
  /// can refresh the picker while it is open.
  FaTuiController? _tuiController;

  /// The active TUI controller for the SIGINT handler in `bin/fah.dart`:
  /// press 1 of the double-press contract (issue #830) reaches the model
  /// through it (composer clear + footer hint). Null in line mode.
  FaTuiController? get tuiController => _tuiController;

  /// The process-wide double-press Ctrl+C window (issue #830): the SIGINT
  /// handler and the TUI's ctrl+c KeyMsg path resolve THIS instance, so
  /// the two input paths can never disagree (ACX.5). Injectable (gh-1014):
  /// `bin/fah.dart` passes the policy resolved from the
  /// [kSigintWindowEnvVar] test seam; null builds the contract default.
  final SigintPolicy sigintPolicy;

  /// The SIGINT-parity exit the TUI's ctrl+c press 2 triggers
  /// (issue #830): abort-if-running bounded, session resume hint,
  /// exit 130. `bin/fah.dart` installs the real routine; null leaves the
  /// legacy plain-quit fallback.
  void Function()? onCtrlCExitRequest;

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
    // gh-1241: NO segment marker here — an idle owner boot must add zero
    // session bytes (issue #428 invariant); the marker lands lazily at the
    // first drive ([_runPrompt]) instead.
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
    _wireOperativePinNotice();
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
        _abortRunOrCompaction();
      } else if (_activeCompactionAbort != null) {
        // Compaction-ONLY interrupt (issue #1085 round-2 review): a bare
        // /compact or post-run compaction runs outside the run bracket —
        // Ctrl+C stops the compaction while the SESSION stays alive. No
        // run-abort markers here: the sticky abort belt would otherwise
        // insta-abort the next prompt and kill the REPL.
        _activeCompactionAbort?.cancel('interrupted by user');
      }
    });
    final taskSub = _taskConfig.jobManager.completions.listen(
      _onTaskJobCompleted,
    );
    // Subagent status board (gh-1415): every registry event refreshes the
    // TUI's live rows (spawn → row appears; settle → flash + collapse).
    _subagentBoardSub = _subagentManager.events.listen(
      (_) => _subagentBoard.refresh(),
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

  /// The line-mode REPL: banner, restored-session replay, then the
  /// read-dispatch loop.

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

  /// The rows shown by the most recent `/sessions` picker (issue #198), so
  /// a picker selection resolves to metadata without a second round trip.
  List<SessionListRow>? _lastSessionRows;

  /// Whether the sessions picker shows the flat single-level list instead
  /// of the tree (toggled from the picker's first item).
  bool _sessionPickerFlat = false;

  /// Picker id → the handler the typed slash command would have used.
  late final Map<String, Future<void> Function(String)> _tuiPickerHandlers = {
    'sessions': _tuiPickSession,
    'mode': _switchMode,
    'approval': (key) async => _handleApprovalMode(key),
    'theme': (key) async => _applyThemeChoice(key, persist: true),
    'provider': _tuiPickProvider,
    'addProvider': _tuiPickAddProvider,
    'settings': _tuiPickSetting,
    'agents': pickAgentFromTree,
    'agentAction': pickAgentAction,
    // Step 2 of the two-step model pick: rows are keyed `provider|model`,
    // the same shape the flat model menu selects.
    'modelProvider': _tuiSelectModel,
  };

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
    StreamJsonWriter? streamJson,
  }) async {
    _hep = hep;
    // The [net] retry voice reaches headless too (issue #1121): the bench
    // runs `fa -p`, and retries that stayed silent there made a
    // connect-stall death indistinguishable from a no-retry one in the
    // trial artifacts.
    _wireTransientRetryNotice();
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
    // gh-1241: the owner opens a usage segment (viewer never appends).
    await _markUsageSegmentStart();
    // HEP (issue #155) + stream-json (issue #695) headers: the FIRST
    // stdout line of each structured mode, written the moment the
    // session id exists — before any event can race them.
    await _writeHeadlessEventHeaders(hep: hep, streamJson: streamJson);
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
    // Transient retry voice (issue #1168 review): the interactive boot
    // wires it in [run]; headless - wake runs, `fa -p`, restarts - needs
    // the same `[net]` line, or a multi-second retry pause is silent
    // exactly where nobody watches a TUI.
    _wireTransientRetryNotice();
    // Sleep prevention (#325/#326) — headless wraps exactly ONE run, so
    // both holds bracket it the same way: session-held acquires on the
    // session open, per-run on the run start (the prompt below).
    await acquirePowerAssertions();
    runPowerAssertionsStarted();
    // Warm the endpoint metadata (model list, dial features, reported
    // limits) BEFORE the first turn; failures are silent.
    await _warmModelCacheQuietly();
    // The interrupt listener MUST be registered BEFORE the pre-flight
    // compaction (issue #1085 round-4 review): that window runs with no
    // run bracket, and a listener registered after it made Ctrl+C there
    // uncancellable for the whole 15-30 min pass.
    final interruptSub = io.interrupts.listen((_) {
      // Headless has no run bracket for pre-flight (`_runStarting` stays
      // false): a live run aborts; a bare compaction window (pre-flight,
      // post-run) is cancelled ALONE (issue #1085 round-2 review) — the
      // turn then proceeds and fails loudly over-window if it must,
      // instead of the session dying on a fake abort.
      if (isBusy) {
        _abortRunOrCompaction();
      } else if (_activeCompactionAbort != null) {
        _activeCompactionAbort?.cancel('interrupted by user');
      }
    });
    final taskSub = _taskConfig.jobManager.completions.listen(
      _onTaskJobCompleted,
    );
    final hepSub = hep == null ? null : _agent.subscribe(hep.handleEvent);
    // Stream-json subscription (issue #695): like the HEP writer, the
    // stream writer sees every agent event; its encoder drops the
    // fa-native ones. Unsubscribed in the finally below so a failed run
    // never leaks the listener into the next one.
    final streamJsonSub = streamJson == null
        ? null
        : _agent.subscribe(streamJson.handleEvent);
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
      // The same pre-flight compaction guard as the REPL's [_runPrompt]:
      // a resumed session already over the threshold must compact BEFORE
      // the first request, or it goes out over-window and gets rejected.
      // Inside the guarded section (issue #1085 round-4): a cancel here
      // surfaces through the same loud error line as any run failure —
      // the listener above is already live for it.
      await _maybeAutoCompact();
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
      streamJsonSub?.call();
      // gh-1241: close the usage segment — fold the chain, write
      // usage.json, log the `fa-tokens:` line (a kill mid-segment loses
      // nothing: the fold rebuilds from the chain on the next close).
      // gh-1292: mirror that line onto the diagnostics channel (stderr
      // on this headless leg) — the diag file dies with the runner, and
      // the token reporter greps the captured run log. Stdout stays the
      // pipeable prose stream (issue #774 AC3).
      await _flushUsageLedger(mirrorTokensLineToRunLog: true);
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

  /// Runs one user prompt to completion. On a CodeMie auth-session expiry,
  /// opens the browser SSO flow to refresh the token automatically. Other
  /// provider errors are printed through [KeyStatusRenderer.errorLine]. An empty assistant
  /// message (no text, no tool calls) is retried once with 'continue'.
  /// Whether the over-window guard's one-shot auto-continuation was used
  /// for the current user prompt (reset at every non-auto-continue
  /// [_runPrompt] entry).
  bool _overWindowAutoResumed = false;

  /// The user-wired cancellation for the in-flight compaction, if any
  /// (issue #1085 M3): Ctrl+C during a 15-30 min pre-flight / relief /
  /// post-run compaction must stop the compaction, not wait it out. Set
  /// in [_runAutoCompact], cancelled by [_abortRunOrCompaction].
  CancelTokenSource? _activeCompactionAbort;

  /// Sticky user-abort marker for the compaction windows (issue #1085
  /// round-1): the compaction engines convert a cancelled summarizer
  /// into a failed pass (`ok: false`) instead of throwing, so the
  /// over-window funnel cannot tell "compaction failed" from "the user
  /// just stopped the task" off the return value alone.
  /// [_abortRunOrCompaction] sets this; the funnel checks it before every
  /// attempt and before the exhaustion verdict; [_beginUserPrompt] resets
  /// it with the fresh turn.
  bool _runAbortRequested = false;

  /// Every compaction pass that actually STARTED (issue #1085 round-1):
  /// the over-window funnel's exhaustion verdict names how many passes
  /// ran — zero is possible (compaction disabled or nothing to
  /// summarize) and must not read as "N attempts failed".
  int _compactionPassesStarted = 0;

  /// Empty-reply "continue" nudge budget per LOGICAL turn
  /// (issue #1085 M2b): auto-continued runs get the nudge like any run,
  /// but the nudged run cannot nudge again — a degenerate model that
  /// answers empty settles instead of nudging itself forever.
  int _emptyReplyNudgesLeft = 1;

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

  /// Idle-wake guard: one inbox-triggered run at a time.
  var _inboxWakeRunning = false;

  /// Test seam: observe/reset the inbox-wake streak without driving ten
  /// real runs (the cap is exactly [InboxWakePolicy.defaultMaxInboxWakeStreak]).
  /// The streak lives in [_inboxWakePolicy] — this proxy keeps the old
  /// seam name working for REG tests.
  @visibleForTesting
  int get inboxWakeStreakForTest => _inboxWakePolicy.streak;
  @visibleForTesting
  set inboxWakeStreakForTest(int value) => _inboxWakePolicy.streak = value;

  /// Consecutive inbox-triggered runs without any user input — capped so
  /// two chatty instances cannot ping-pong forever (mail still accumulates
  /// and is delivered at the next real turn). User-kind messages reset the
  /// streak when delivered: they ARE the user talking, so an attach-driven
  /// session never exhausts the cap. gh-1180: scheduled self-mail is
  /// EXEMPT (see [_inboxWakePolicy]). Single-sourced from the policy
  /// (review): one tuned threshold, one declaration.
  static const _maxInboxWakeStreak = InboxWakePolicy.defaultMaxInboxWakeStreak;

  /// The idle inbox-wake lane policy (gh-1180): user-kind mail always
  /// wakes; delivered scheduled self-mail (`schedule_message` reminders)
  /// is exempt from the chatter cap — a deliberate agent-chosen cadence
  /// wakes forever, cadence-floored against a disguised busy-spin; and
  /// foreign agent-to-agent chatter stays capped at
  /// [_maxInboxWakeStreak] consecutive wakes without user input.
  final InboxWakePolicy _inboxWakePolicy = InboxWakePolicy(
    maxStreak: _maxInboxWakeStreak,
  );

  /// Test seam for the persisted wake-receipt trail (gh-1180 AC4): reads
  /// the non-nullable [_scheduledReceipts] the production wake path
  /// writes through. Mirrors the app host's `scheduledReceiptsForTest`.
  @visibleForTesting
  ScheduledReceiptLog get scheduledReceiptsForTest => _scheduledReceipts;

  /// Compaction settings for the live model: the config override when the
  /// user pinned one, else pi's fixed defaults SCALED to the model window
  /// (`CompactionSettings.forWindow`) — the same rule the Flutter app
  /// applies. The fixed 20k-keep defaults are right for 128k windows but
  /// structurally prevent compaction on small models: with keep 20000 on
  /// an 8k-window model the compactor always "keeps" the whole transcript
  /// (nothing is older than the kept region), so an over-window guard can
  /// never be satisfied by compacting.
  ///
  /// Resolved through the shared host wiring (gh-1077): the CLI path and
  /// the app path must agree on window/reserve semantics, and the parity
  /// test pins that agreement — the window here is
  /// [effectiveContextWindow] under the owner cap, no overhead subtracted
  /// (the CLI carries no fixed request overhead).
  CompactionSettings get _effectiveCompactionSettings {
    final override = config.compactionSettings;
    if (override != null) return override;
    return resolveCompactionHostWiring(
      mainModel: _agent.state.model,
      contextWindowCap: config.contextWindowCap,
    ).settings;
  }

  /// Whether a guided flow is between prompts.
  var _providerFlowActive = false;

  /// Answers buffered while no flow prompt was pending.
  final _promptLineBuffer = <String>[];

  /// Runtime secrets granted via `request_secret`.
  final Map<String, String> _runtimeSecrets = {};

  var _diagnosticLogDirEnsured = false;

  String? _activeCustomName;
  Completer<String?>? _wizardPickerAnswer;
}

/// One AC3 post-tool narration segment (gh-1433): the text deltas that
/// streamed after ONE tool-call block of the current message. [toolCallId]
/// is stamped by the block's `ToolCallEndEvent` — the same id the
/// execution events carry — so the segment flushes after that call's
/// result row (positional even for parallel/multi-call messages).
final class _PostToolNarrationHold {
  /// The held narration deltas, in stream order.
  final StringBuffer text = StringBuffer();

  /// The tool call this segment follows; null until the call's
  /// `ToolCallEndEvent` stamps it (or never, on a degenerate stream).
  String? toolCallId;
}
