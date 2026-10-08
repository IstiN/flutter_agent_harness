/// Live agent-stack wiring through the builder (issue #1079, slice 2 —
/// the CLI converts to this as the first host shell; slice 3 — the
/// fabric/subagent/task complex joins the builder-owned set; slice 4 —
/// host extensions become builder-gated, declared surface).
///
/// [wireAgentCore] consumes a [HostCapabilityProfile] plus the host's
/// typed [AgentCoreServices] and returns a [WiredAgentCore]: the
/// capability-gated environment chain, the core tool list, and the
/// surfaced/hidden plan — from which [WiredAgentCore.buildAgentStack]
/// assembles the [ToolRegistry] and the [Agent] itself. This is the
/// shared layer the thin host shells construct their stack through:
/// the host provides services and callbacks, the builder owns every
/// gating decision (what wires, over which transports, what stays
/// hidden with its reason).
///
/// **Run narrowing** (the profile-narrows invariant, applied per run):
/// before the plan is built, the profile is narrowed against the
/// services the host actually provided — a wired capability whose
/// required services are absent turns `off` with an honest reason, and
/// wired transports whose per-transport services are absent are dropped
/// (a capability narrowed to zero transports turns `off`). The E1 check
/// then stays meaningful: whatever REMAINS wired must have its services,
/// or the build fails loudly naming the gap. Today's CLI semantics are
/// exactly this: a null config section means the capability is off this
/// run — now the absence is a declared state with a reason instead of a
/// silent hand-rolled `if`.
///
/// Pure Dart: no `dart:io`.
library;

import 'dart:async';
import 'dart:typed_data';

import '../agent/agent.dart';
import '../agent/agent_loop.dart' show OverWindowRelief, StreamFunction;
import '../agent/agent_tool.dart';
import '../agent/misuse_breaker.dart';
import '../agent/stuck_tool.dart' show StuckToolConfig;
import '../agent/tool_registry.dart';
import '../a2a/a2a_config.dart' show A2aConfig;
import '../a2a/a2a_mail_gateway.dart' show A2aMailGateway;
import '../a2a/a2a_manager.dart' show A2aManager;
import '../browser/browser_tools.dart';
import '../compaction/compaction_engine.dart' show CompactionEngine;
import '../config/config_service.dart';
import '../cube/config/cube_spec.dart';
import '../cube/config/fs_policy.dart';
import '../cube/network_gate.dart';
import '../cube/runtime/sandboxed_env.dart';
import '../env/execution_env.dart';
import '../env/session_vars_execution_env.dart';
import '../hashline/snapshots.dart';
import '../lsp/lsp_tool.dart';
import '../memory/memory_controller.dart';
import '../model.dart';
import '../memory/memory_tools.dart';
import '../model_roles/model_resolver.dart' show ModelRolesResolver;
import '../messaging/agent_fabric.dart' show buildAgentFabric;
import '../messaging/file_messaging_repository.dart'
    show SwappableMessagingRepository;
import '../messaging/messaging_repository.dart' show MessagingRepository;
import '../messaging/schedule_message_tool.dart';
import '../messaging/scheduled_messages.dart';
import '../mcp/mcp_manager.dart';
import '../model_roles/models_config.dart';
import '../model_roles/provider_key_resolver.dart';
import '../session/session_tree.dart' show Session;
import '../session_io_retry.dart' show SessionIoRetryConfig;
import '../task/child_session_io.dart'
    show jsonlChildMessageReader, jsonlChildSessionOpener;
import '../task/subagent_heartbeat.dart' show SubagentHeartbeat;
import '../task/subagent_manager.dart'
    show
        MailboxWakeLauncher,
        SubagentManager,
        SubagentRegistrySink,
        SubagentRegistrySource,
        childInboxWakePrompt;
import '../task/subagent_tools.dart' show subagentMonitoringTools;
import '../task/task_tool.dart' show TaskToolConfig, taskTool;
import '../telemetry/agent_telemetry.dart';
import '../tools/ask_tool.dart';
import '../tools/builtin_tools.dart';
import '../tools/generate_image.dart';
import '../tools/generate_video.dart';
import '../tools/inspect_image.dart';
import '../tools/obligation_tool.dart';
import '../tools/password_prompt.dart';
import '../tools/request_secret_tool.dart';
import '../tools/shell_jobs.dart';
import '../tools/sqlite/sqlite_reader.dart';
import '../tools/transcribe_audio.dart';
import '../web_search/web_search_tool.dart';
import 'host_capability_profile.dart';
import 'host_extension_api.dart';
import 'host_wiring_builder.dart';

/// The sandbox facility a process-capable host provides: the builder
/// wraps the base env in a [SandboxedExecutionEnv] (passthrough when
/// [spec] is null — the wrapper itself is the capability wiring; the
/// spec is the live cube profile).
final class SandboxServices {
  final CubeSpec? spec;
  final String? homeDir;
  final String? os;
  final CubeFsProbe? pathProbe;
  final void Function(String message)? onWarning;

  const SandboxServices({
    this.spec,
    this.homeDir,
    this.os,
    this.pathProbe,
    this.onWarning,
  });
}

/// The media-generation facility (generate_image / generate_video). The
/// CLI registers both unconditionally over the models config with its
/// live main-credential accessor; hosts without the facility leave this
/// null and the tools never surface.
final class MediaToolServices {
  final ModelsConfig? modelsConfig;
  final MediaKeyResolver? resolveKey;

  /// The live main API key — resolved per call so runtime `/provider`
  /// switches apply to media calls exactly as to chat calls.
  final String Function() mainApiKey;

  const MediaToolServices({
    required this.mainApiKey,
    this.modelsConfig,
    this.resolveKey,
  });
}

/// The subagent/task complex the builder assembles when the profile wires
/// [HostCapability.subagents] (issue #1079, slice 3): the messaging
/// fabric, the [SubagentManager], the heartbeat and the task/monitoring
/// tool surface become builder-owned, capability-gated wiring. The host
/// provides only what is genuinely shell glue: session persistence, the
/// wake launcher, heartbeat delivery, child-session minting. Absent
/// bundle = the capability run-narrows off with a named reason; the
/// complex never half-wires.
final class SubagentServices {
  /// Fabric + manager inputs: the user home (cwd-tag shortening, fabric
  /// root context) and this host's machine name (`name@machine`
  /// addressing, issue #27 phase 2/3).
  final String? homeDir;
  final String? machineName;

  /// The parsed `a2a:` config section (null = no remote agents).
  final A2aConfig? a2a;

  /// Detached wake launcher for asleep mailboxes (the CLI spawns its own
  /// binary with `--session <name>`). Null keeps the "how to start it"
  /// hint path.
  final MailboxWakeLauncher? wakeProcess;

  /// Registry persistence into the parent session + rehydration at boot
  /// (the `subagent_registry` custom records, issue #488 AC2).
  final SubagentRegistrySink? registrySink;
  final SubagentRegistrySource? registrySource;

  /// Heartbeat delivery sink — required: a heartbeat without a delivery
  /// path would silently discard digests. Threshold getters stay live so
  /// a config rewrite applies at the next tick without a restart (E6).
  final void Function(String digest) notifyHeartbeat;
  final int Function()? heartbeatMinutes;
  final int Function()? stallMinutes;

  /// Task children: role resolution (agent types with a `modelRole`) and
  /// the host's compaction choice (live settings override, else config —
  /// issue #439).
  final ModelRolesResolver? rolesResolver;
  final CompactionEngine? compactionEngine;

  /// `agent.misuseBreaker` covers children too (issue #862).
  final bool misuseBreaker;

  /// Real JSONL child sessions, created at child COMPLETION (fast
  /// register keeps the steering race away; the transcript lands when the
  /// child finishes).
  final Future<Session> Function(String parentId, String childId)?
  childSessionFactory;

  /// Transient-ENOENT retry for the child-session reopen (issue #427);
  /// the builder derives the JSONL opener from it.
  final SessionIoRetryConfig? sessionIoRetry;

  const SubagentServices({
    this.homeDir,
    this.machineName,
    this.a2a,
    this.wakeProcess,
    this.registrySink,
    this.registrySource,
    required this.notifyHeartbeat,
    this.heartbeatMinutes,
    this.stallMinutes,
    this.rolesResolver,
    this.compactionEngine,
    this.misuseBreaker = true,
    this.childSessionFactory,
    this.sessionIoRetry,
  });
}

/// The typed platform services a host supplies to [wireAgentCore].
///
/// Nullable fields are the config/run-conditional ones: null means the
/// facility does not exist this run, which run-narrowing declares as an
/// honest `off` — the per-tool null gates inside the assembly then agree
/// with the plan by construction.
final class AgentCoreServices {
  /// The host's base environment (the CLI's `CwdOverrideEnv`). Decorated
  /// by the builder: sandbox (when wired) → session vars (when provided).
  final ExecutionEnv baseEnv;

  /// The live session-var source for [SessionVarsExecutionEnv]. Null on
  /// hosts without session variables.
  final FutureOr<Map<String, String>> Function()? sessionEnvVars;

  final SandboxServices? sandbox;
  final HashlineSnapshotStore? snapshots;
  final WebSearchConfig? webSearch;
  final SqliteEngine? sqlite;
  final LspToolConfig? lsp;
  final McpManager? mcp;

  /// Shell job board factory — receives the FINAL decorated env (the
  /// jobs' processes must run through the same env the tools use).
  final ShellJobRegistry? Function(ExecutionEnv coreEnv)? shellJobsFactory;

  /// Config tool service factory — same final-env shape.
  final ConfigService? Function(ExecutionEnv coreEnv)? configServiceFactory;

  final PasswordPromptCallback? onPasswordPrompt;

  /// Host-side tool families (the CLI's memory/fabric/ask surface). They
  /// move INTO the builder's gated set in later slices; the builder
  /// already places them in the canonical order.
  final MemoryController? memory;
  final void Function()? onMemoryChanged;
  final ScheduledMessageQueue? scheduledMessages;
  final String? Function()? scheduleSenderMailbox;

  /// The `ask` host prompt. Null = headless host: the tool still
  /// registers and fails gracefully in-tool (its documented null mode) —
  /// it is never dropped from the registry.
  final AskCallback? onAsk;

  /// The `request_secret` host prompt. Null = headless host: same
  /// always-registered graceful-failure contract as [onAsk].
  final RequestSecretCallback? onRequestSecret;

  /// The obligations-ledger close callback (`obligation_mark_done`,
  /// issue #1380 lifecycle). Null = the host does not maintain the
  /// ledger: the tool still registers and answers gracefully in-tool —
  /// the same always-registered contract as [onAsk].
  final ObligationClose? obligationsClose;
  final InspectImageConfig? vision;
  final TranscribeAudioConfig? transcribe;
  final MediaToolServices? media;
  final BrowserController? browserController;

  /// The browser screenshot saver. The builder hands it the SAME
  /// decorated env every fs-touching tool rides (base → sandbox →
  /// session vars, review #1230): a screenshot save clamps through the
  /// cube fs policy exactly like `generate_image` writes to the same
  /// tree. One rule — hosts must not close over their raw base env.
  final Future<String> Function(ExecutionEnv coreEnv, Uint8List png)?
  saveBrowserScreenshot;

  /// The host's declared extensions (issue #1079 slice 4 — the
  /// `HostExtensionApi`): named tool contributions with an explicit
  /// per-profile matrix (E6). The builder gates them: tool-id collisions
  /// rejected at build time with both registrants named (E7), and a
  /// profile-off extension hides with its reason surfaced on
  /// [WiredAgentCore.extensions] (E8). See [HostExtension].
  final List<HostExtension> extensions;

  /// Lifecycle telemetry for in-process hosts (issue #1322 Gap 3). When
  /// present, `buildAgentStack` attaches the sink to the built agent and
  /// wraps the stream function — turn/tool/first-token/provider-status
  /// records flow with zero further host code. Null = silent (today's
  /// behavior). The interface is pure; the fa.log file sink comes from
  /// `package:flutter_agent_harness/io.dart`.
  final AgentTelemetrySink? telemetry;

  /// Host-facing provider-key slot resolution (issue #1322 Gap 2). The
  /// host injects its env/store readers; [resolveKey] then answers which
  /// slot the request path WILL use. Null = the host resolves keys its
  /// own way (and owns the canonical-vs-pinned drift risk).
  final HostKeyResolver? keyResolver;

  /// Fires when the run's model resolved to a PINNED key slot instead of
  /// the canonical one — the same migration hint the CLI prints at boot.
  /// Requires [keyResolver]; called once per [WiredAgentCore.buildAgentStack].
  ///
  /// Scope note: the automatic check resolves STORE-only (it has no
  /// catalog facts), so a host that runs a catalog env var AND a pinned
  /// store twin may see a drift hint for a key the env leg actually wins.
  /// Hosts with catalog facts should call `services.resolveKey(envNames: …,
  /// defaultBaseUrl: …)` themselves and treat the boot-time hint as
  /// store-scope only.
  final void Function(String hint)? onKeySlotDrift;

  /// The hub-transport messaging backend. The builder composes the
  /// fabric's hub primary over it (slice 3: the fabric itself is
  /// builder-owned); null drops the hub transport at run-narrowing, the
  /// file layer keeps working.
  final MessagingRepository? hubFabric;

  /// The host's MAIN inbox resolver for the hub primary's mail merge —
  /// required whenever the hub transport wires (E1-loud otherwise). The
  /// CLI resolves `() => _subagentManager.mailboxOf('main')` lazily, so
  /// the manager may be constructed after the fabric.
  final String? Function()? mainMailbox;

  /// The subagent/task complex (slice 3). Null = the capability narrows
  /// off this run with a named reason; the task/monitoring surface and
  /// the fabric/manager/heartbeat never half-wire.
  final SubagentServices? subagents;

  // Remaining passthrough facilities the builder does not assemble yet
  // but the catalog's E1 contract declares for wired capabilities. Null =
  // honest run-narrowing of the affected capability/transport.
  final Object? extRuntimeFactory;
  final String? sessionRoot;

  const AgentCoreServices({
    required this.baseEnv,
    this.sessionEnvVars,
    this.sandbox,
    this.snapshots,
    this.webSearch,
    this.sqlite,
    this.lsp,
    this.mcp,
    this.shellJobsFactory,
    this.configServiceFactory,
    this.onPasswordPrompt,
    this.memory,
    this.onMemoryChanged,
    this.scheduledMessages,
    this.scheduleSenderMailbox,
    this.onAsk,
    this.onRequestSecret,
    this.obligationsClose,
    this.vision,
    this.transcribe,
    this.media,
    this.browserController,
    this.saveBrowserScreenshot,
    this.extensions = const [],
    this.hubFabric,
    this.mainMailbox,
    this.subagents,
    this.extRuntimeFactory,
    this.sessionRoot,
    this.telemetry,
    this.keyResolver,
    this.onKeySlotDrift,
  });

  /// The effective key-slot name (and drift hints) for [baseUrl] — the
  /// host-facing ask the CLI kept internal (issue #1322 Gap 2). Null when
  /// no [keyResolver] was supplied.
  HostKeyResolution? resolveKey({
    String? provider,
    required String baseUrl,
    String? model,
    List<String> envNames = const [],
    String? defaultBaseUrl,
    String? activeCustomKeyName,
  }) => keyResolver?.resolveKey(
    provider: provider,
    baseUrl: baseUrl,
    model: model,
    envNames: envNames,
    defaultBaseUrl: defaultBaseUrl,
    activeCustomKeyName: activeCustomKeyName,
  );

  /// The catalog service names this bundle provides — the run-narrowing
  /// input. Names match [CapabilitySpec.requiredServices] keys exactly.
  Set<String> get providedServiceNames => {
    if (sandbox != null) ...{'cubeSpec', 'fsProbe'},
    if (shellJobsFactory != null) 'shellJobFactory',
    if (webSearch != null) 'webSearchSecrets',
    if (mcp != null) 'mcpTransportFactory',
    if (sqlite != null) 'sqliteEngine',
    if (lsp != null) 'lspTransportFactory',
    if (vision != null) 'visionConfig',
    if (transcribe != null) 'transcribeConfig',
    if (browserController != null) 'browserBridgeHandle',
    if (hubFabric != null) 'hubFabric',
    if (subagents != null) 'subagentServices',
    if (extRuntimeFactory != null) 'extRuntimeFactory',
    if (sessionRoot != null) 'sessionRoot',
  };
}

/// The per-run parameters [WiredAgentCore.buildAgentStack] needs to
/// construct the [Agent]. Pure data — the host's callbacks arrive as
/// fields, the builder owns the assembly.
final class AgentWiringSpec {
  final Model model;
  final String systemPrompt;
  final int maxEmptyRetries;
  final void Function(Object error)? onRunIdleTimeout;
  final void Function()? onRunWatchdogPaused;
  final int? contextWindowCap;
  final StuckToolConfig? stuckTool;
  final bool wireDump;
  final OverWindowRelief? overWindowRelief;
  final ToolMisuseBreaker? toolMisuseBreaker;

  const AgentWiringSpec({
    required this.model,
    required this.systemPrompt,
    this.maxEmptyRetries = 1,
    this.onRunIdleTimeout,
    this.onRunWatchdogPaused,
    this.contextWindowCap,
    this.stuckTool,
    this.wireDump = false,
    this.overWindowRelief,
    this.toolMisuseBreaker,
  });
}

/// The wired core a host shell builds its agent from: the decorated env
/// chain, the capability-gated tool list (canonical order), the plan, and
/// the service instances the host needs to keep handles on (the CLI's
/// `/cube` family drives [sandboxEnv] live).
final class WiredAgentCore {
  /// The (run-narrowed) plan the wired capabilities come from.
  final HostWiringPlan plan;

  /// The services bundle this core was wired over — `buildAgentStack`
  /// reads the host-seam facilities (telemetry, key resolution) from it.
  final AgentCoreServices services;

  /// baseEnv → sandbox (when wired) → session vars (when provided).
  final ExecutionEnv env;

  /// The sandbox layer, when the profile wires the sandbox capability.
  /// Null on hosts without it (`/cube`-style hosts always have one).
  final SandboxedExecutionEnv? sandboxEnv;

  /// Web-egress gate derived from the live sandbox spec; null without a
  /// sandbox.
  final CubeNetworkGate? networkGate;

  /// The shell job board built over [env], when the host provided a
  /// factory for it.
  final ShellJobRegistry? shellJobs;

  /// The capability-gated core tools, in the canonical registration
  /// order (builtins → memory → schedule → ask → secret → vision →
  /// transcribe → media → browser → host extensions). Set at
  /// construction by [wireAgentCore] — a wired core ALWAYS carries its tools (no
  /// post-hoc assignment that a refactor could orphan). Child-safe: the
  /// task executor strips only `task` itself, so the gated task surface
  /// below never rides in this list.
  final List<AgentTool> tools;

  // ---- the builder-owned task/subagent complex (slice 3) ----
  // Null/empty when HostCapability.subagents is off (profile choice or
  // run-narrowing): no orphan handles, no half-wired surface (AC7).

  /// The messaging fabric over the file/hub transports; null when the
  /// profile declares messagingFabric off.
  final MessagingRepository? fabric;

  /// The swappable file layer (hosts re-point it on storage fallback).
  final SwappableMessagingRepository? fileFabric;

  /// The messaging root the file inboxes live under.
  final String? messagesRoot;

  final SubagentManager? subagentManager;
  final A2aManager? a2aManager;
  final SubagentHeartbeat? subagentHeartbeat;
  final TaskToolConfig? taskConfig;

  /// The gated task/monitoring surface (monitoring tools, then `task`
  /// LAST — the canonical pre-conversion order). Child-UNSAFE: kept out
  /// of [tools] so child tool pools never draw it.
  final List<AgentTool> taskSurface;

  /// The wired extension surface (slice 4): per-extension outcome — the
  /// tools that reached the stack, or the profile's off reason (E8) for
  /// the host's UI.
  final List<WiredHostExtension> extensions;

  Agent? _agent;

  WiredAgentCore._({
    required this.plan,
    required this.services,
    required this.env,
    required this.sandboxEnv,
    required this.networkGate,
    required this.shellJobs,
    required this.tools,
    required this.fabric,
    required this.fileFabric,
    required this.messagesRoot,
    required this.subagentManager,
    required this.a2aManager,
    required this.subagentHeartbeat,
    required this.taskConfig,
    required this.taskSurface,
    required this.extensions,
  });

  /// Assembles the [ToolRegistry] (core tools first, then the gated task
  /// surface, then [additionalTools] — any residual host surface) and the
  /// [Agent] over it. The model-reading tool closures resolve against
  /// the constructed agent, exactly like the host shells' own
  /// `() => _agent.state.model` today.
  WiredAgentStack buildAgentStack({
    required AgentWiringSpec spec,
    required StreamFunction streamFunction,
    List<AgentTool> additionalTools = const [],
    void Function(String note)? onDuplicate,
  }) {
    // ---- issue #1322 host seams ----
    // Key-slot drift (Gap 2): when the host supplied a resolver, the run's
    // model gets the same boot-time canonical-vs-pinned check the CLI
    // prints — one visible warning instead of a silently empty slot.
    final keyResolver = services.keyResolver;
    if (keyResolver != null) {
      final resolution = keyResolver.resolveKey(
        provider: spec.model.provider,
        baseUrl: spec.model.baseUrl,
      );
      final hint = resolution.driftHint;
      if (hint != null) services.onKeySlotDrift?.call(hint);
    }
    // Telemetry (Gap 3): the adapter subscribes the sink to the agent and
    // wraps the provider leg (requestStart / firstToken / HTTP status on
    // error). Null sink → byte-identical to the pre-telemetry wiring.
    var wiredStream = streamFunction;
    AgentTelemetry? telemetryAdapter;
    final sink = services.telemetry;
    if (sink != null) {
      telemetryAdapter = AgentTelemetry(sink);
      wiredStream = telemetryAdapter.wrapStreamFunction(streamFunction);
    }
    final registry = ToolRegistry([
      ...tools,
      ...taskSurface,
      ...additionalTools,
    ], onDuplicate);
    final agent = _agent = Agent(
      model: spec.model,
      systemPrompt: spec.systemPrompt,
      streamFunction: wiredStream,
      toolRegistry: registry,
      maxEmptyRetries: spec.maxEmptyRetries,
      onRunIdleTimeout: spec.onRunIdleTimeout,
      onRunWatchdogPaused: spec.onRunWatchdogPaused,
      contextWindowCap: spec.contextWindowCap,
      stuckTool: spec.stuckTool,
      wireDump: spec.wireDump,
      overWindowRelief: spec.overWindowRelief,
      toolMisuseBreaker: spec.toolMisuseBreaker,
    );
    telemetryAdapter?.attach(agent);
    return WiredAgentStack(registry: registry, agent: agent);
  }
}

// The canonical core tool list over [services]. Top-level by design:
// [wireAgentCore] computes it BEFORE the core exists and hands it in as a
// constructor parameter — "a wired core always has its tools" holds by
// construction. Media/browser/model closures read the agent lazily
// through [currentAgent] (the agent is built later, in buildAgentStack).
List<AgentTool> _buildCoreTools({
  required HostWiringPlan plan,
  required ExecutionEnv env,
  required CubeNetworkGate? networkGate,
  required ShellJobRegistry? shellJobs,
  required AgentCoreServices services,
  required ConfigService? configService,
  required Agent? Function() currentAgent,
}) {
  final media = services.media;
  final browser = switch (plan.planFor(HostCapability.browserBridge)) {
    WiredCapability() => browserTools(
      controller: services.browserController!,
      // Same decorated env as the vision/transcribe/media tools below
      // (review #1230): one rule — screenshot saves clamp through the
      // cube fs policy too.
      saveScreenshot: (png) => services.saveBrowserScreenshot!(env, png),
    ),
    _ => null,
  };
  return [
    // Core builtins: read/write/edit/list/shell (+ job board, lsp, web
    // search, config, mcp). The nullable params agree with the plan by
    // construction: run-narrowing declared the absent facilities off.
    ...builtinTools(
      env,
      snapshots: services.snapshots ?? HashlineSnapshotStore(),
      webSearch: services.webSearch,
      networkGate: networkGate,
      config: configService,
      model: () => currentAgent()?.state.model,
      sqlite: services.sqlite,
      lsp: services.lsp,
      mcp: services.mcp,
      shellJobs: shellJobs,
      onPasswordPrompt: services.onPasswordPrompt,
    ),
    ...memoryTools(services.memory, onChanged: services.onMemoryChanged),
    ...?services.scheduledMessages == null
        ? null
        : [
            scheduleMessageTool(
              services.scheduledMessages!,
              senderMailbox: services.scheduleSenderMailbox,
            ),
          ],
    // ask / request_secret register UNCONDITIONALLY: a null callback is
    // the tools' documented headless mode (executing throws a StateError
    // the agent loop converts into a graceful "cannot answer questions" /
    // "cannot request secrets" result) — byte-identical to the
    // pre-conversion CLI, which always registered them. Dropping them
    // would surface a bare "Tool ask not found" instead.
    askTool(callback: services.onAsk),
    requestSecretTool(callback: services.onRequestSecret),
    // The obligations close path (issue #1380 lifecycle): same
    // always-registered graceful-null contract as ask/request_secret.
    obligationMarkDoneTool(close: services.obligationsClose),
    // Deliberate env-chain change vs the pre-conversion CLI (review,
    // #1230): vision/transcribe/media used to ride the RAW base env and
    // bypassed the sandbox; they now take the decorated chain
    // (base → sandbox → session vars), so image reads, transcription
    // input and media file writes are clamped by the active cube fs
    // policy — closing a sandbox escape, not a regression. The browser
    // screenshot saver rides the same chain (see the browser assembly
    // above) — one rule for every fs-touching tool.
    ...?services.vision == null
        ? null
        : [inspectImageTool(env, services.vision!)],
    ...?services.transcribe == null
        ? null
        : [transcribeAudioTool(env, services.transcribe!)],
    ...?media == null
        ? null
        : [
            generateImageTool(
              env: env,
              modelsConfig: media.modelsConfig,
              mainBaseUrl: () => currentAgent()!.state.model.baseUrl,
              mainModelId: () => currentAgent()!.state.model.id,
              mainApiKey: media.mainApiKey,
              resolveKey: media.resolveKey,
            ),
            generateVideoTool(
              env: env,
              modelsConfig: media.modelsConfig,
              mainBaseUrl: () => currentAgent()!.state.model.baseUrl,
              mainModelId: () => currentAgent()!.state.model.id,
              mainApiKey: media.mainApiKey,
              resolveKey: media.resolveKey,
            ),
          ],
    ...?browser,
  ];
}

/// The registry + agent a host shell drives after wiring.
final class WiredAgentStack {
  final ToolRegistry registry;
  final Agent agent;

  const WiredAgentStack({required this.registry, required this.agent});
}

/// The assembled task/subagent complex (slice 3): the service instances a
/// host shell keeps handles on, plus the gated tool surface.
final class _WiredTaskSurface {
  final SubagentManager subagentManager;
  final A2aManager a2aManager;
  final SubagentHeartbeat subagentHeartbeat;
  final TaskToolConfig taskConfig;
  final List<AgentTool> tools;

  const _WiredTaskSurface({
    required this.subagentManager,
    required this.a2aManager,
    required this.subagentHeartbeat,
    required this.taskConfig,
    required this.tools,
  });
}

/// Assembles the messaging fabric when the (run-narrowed) plan wires
/// [HostCapability.messagingFabric]: the file layer over the session
/// root, the hub primary only when the hub transport survived
/// run-narrowing (hub fabric provided). Independent of the subagent
/// complex — the MAIN inbox drain rides it even where subagents stay
/// off. Null when the profile declares the capability off.
///
/// File-less shapes keep their wired hub: a hub-only (mobile) profile
/// gets the hub repository itself as the fabric — the file transport's
/// absence discards only the file layer, never the whole fabric. A
/// transport state can ALSO survive on transports that declare no host
/// service (a2a rides the subagent bundle's gateway, not a repository):
/// hub-less + file-less then composes nothing — null is the honest
/// answer, the a2a mail path rides the subagent complex directly.
({
  MessagingRepository fabric,
  SwappableMessagingRepository? fileFabric,
  String? messagesRoot,
})?
_wireFabric({
  required HostWiringPlan plan,
  required AgentCoreServices services,
}) {
  final fabricPlan = plan.planFor(HostCapability.messagingFabric);
  if (fabricPlan is! WiredCapability) return null;
  final transports = fabricPlan.transports;
  final wantFile = transports.contains('file');
  if (wantFile && services.sessionRoot == null) {
    // E1: run-narrowing guarantees sessionRoot for a wired file
    // transport; a caller bypassing _narrowToServices gets the loud
    // named failure instead of a silent discard.
    throw HostWiringException(
      'Profile "${plan.profile.name}" wires the messagingFabric file '
      'transport but the host provided no sessionRoot (E1: name the '
      'missing service, never a null crash at write time).',
    );
  }
  if (transports.contains('hub') && services.mainMailbox == null) {
    // E1: the hub primary merges mail into a host-named mailbox — a host
    // serving the hub transport must say which one, or say nothing loud.
    throw HostWiringException(
      'Profile "${plan.profile.name}" wires the messagingFabric hub '
      'transport but the host provided no mainMailbox resolver (E1: name '
      'the missing service, never a null crash at mail time).',
    );
  }
  if (!wantFile) {
    // File-less (hub-only/mobile) profile: the wired hub IS the fabric —
    // no file layer to swap and no root to name. Narrowing drops the hub
    // transport when hubFabric is absent, BUT a transport with no
    // declared service (a2a) survives unconditionally — so a file-less
    // state here does NOT prove the hub is present. Hub-less means there
    // is no repository to compose: return null (never a null-deref; the
    // E1 guard above still fires for a hub that DID survive without a
    // mainMailbox resolver).
    final hub = services.hubFabric;
    if (hub == null) return null;
    return (fabric: hub, fileFabric: null, messagesRoot: null);
  }
  return buildAgentFabric(
    env: services.baseEnv,
    sessionRoot: services.sessionRoot!,
    homeDir: services.subagents?.homeDir,
    hubFabric: transports.contains('hub') ? services.hubFabric : null,
    // The hub primary merges mail into the MAIN inbox only — resolved
    // lazily by the host once its manager exists. The fallback is dead
    // code without a hub (the E1 guard above covers hub-wired hosts).
    mainMailbox: services.mainMailbox ?? (() => null),
  );
}

/// Assembles the fabric → manager → heartbeat → task/monitoring complex
/// when the (run-narrowed) plan wires [HostCapability.subagents] and the
/// host provided the [SubagentServices] bundle; null otherwise — the
/// capability stays off, the surface stays absent (AC7).
///
/// The complex rides the host's BASE env (the fabric's file inboxes and
/// the JSONL child-session helpers are infrastructure, not tools — the
/// shell wired them identically pre-conversion; the decorated chain
/// remains the rule for fs-touching TOOLS, review #1230).
_WiredTaskSurface? _wireTaskSurface({
  required HostWiringPlan plan,
  required AgentCoreServices services,
  required MessagingRepository? fabric,
  required List<AgentTool> coreTools,
  required Agent? Function() currentAgent,
}) {
  final bundle = services.subagents;
  if (bundle == null ||
      plan.planFor(HostCapability.subagents) is! WiredCapability) {
    return null;
  }
  final manager = SubagentManager(
    parentSessionId: '',
    messaging: fabric,
    selfId: 'main',
    homeDir: bundle.homeDir,
    wakeProcess: bundle.wakeProcess,
    sink: bundle.registrySink,
    source: bundle.registrySource,
  )..machineName = bundle.machineName;
  // A2A remote agents ride the a2a transport (phase 5a): the gateway
  // merges cross-machine `agent_message` mail into the manager.
  final a2a = A2aManager(bundle.a2a);
  final fabricPlan = plan.planFor(HostCapability.messagingFabric);
  if (fabricPlan is WiredCapability && fabricPlan.transports.contains('a2a')) {
    manager.a2aGateway = A2aMailGateway(
      manager: a2a,
      machineName: bundle.machineName,
    );
  }
  final heartbeat = SubagentHeartbeat(
    manager: manager,
    notify: bundle.notifyHeartbeat,
    heartbeatMinutes: bundle.heartbeatMinutes,
    stallMinutes: bundle.stallMinutes,
  )..start();
  // The `task` tool (omp's background subagents): children draw from the
  // child-safe core tool surface (never `task` itself), completions are
  // injected back into the parent conversation as async-result messages.
  // Live accessors, resolved per spawn: a runtime `/provider`/`/model`
  // switch (or a token refresh) re-points the stream function/the agent
  // model, and children spawned afterwards must inherit the LIVE
  // credential — a boot-frozen wiring would send the stale key (401).
  final taskConfig = TaskToolConfig(
    childTools: coreTools,
    streamFunction: () => currentAgent()!.streamFunction,
    model: () => currentAgent()!.state.model,
    rolesResolver: bundle.rolesResolver,
    subagentManager: manager,
    a2aManager: a2a,
    compactionEngine: bundle.compactionEngine,
    misuseBreaker: bundle.misuseBreaker,
    childSessionFactory: bundle.childSessionFactory,
    // Issue #222: the resume path reopens a child's JSONL session by
    // path so task_resume/task_send continue the child in the SAME file.
    // Issue #427: the reopen rides the same transient-ENOENT retry as
    // every other session open.
    childSessionOpener: jsonlChildSessionOpener(
      services.baseEnv,
      ioRetry: bundle.sessionIoRetry ?? const SessionIoRetryConfig(),
    ),
  );
  // gh-970: a scheduled reminder (or sibling mail) that fires into a
  // finished child's inbox resumes the child in its own session — the
  // child-side analog of the idle inbox wake. The sweep (dedup, status
  // gates) lives on the manager; the resume rides the executor.
  manager.wakeChild = (id) =>
      taskConfig.executor.resumeChild(id, childInboxWakePrompt);
  final tools = [
    // Issue #222: child messaging IS available on this host — observe
    // reads the child's JSONL transcript; send/resume continue the child
    // in its own session via the session-shared executor. Issue #332:
    // task_cancel reaches inline children (blocking batches, resumes)
    // through the executor's in-flight cancel set — without it the
    // tombstone fallback would fire over LIVE children.
    ...subagentMonitoringTools(
      manager: manager,
      jobs: taskConfig.jobManager,
      readMessages: jsonlChildMessageReader(services.baseEnv),
      resumeChild: taskConfig.executor.resumeChild,
      executor: taskConfig.executor,
    ),
    taskTool(config: taskConfig),
  ];
  return _WiredTaskSurface(
    subagentManager: manager,
    a2aManager: a2a,
    subagentHeartbeat: heartbeat,
    taskConfig: taskConfig,
    tools: tools,
  );
}

/// Wires the agent core for [profile] over [services]: run-narrows the
/// profile against the provided services, builds the plan (E1 loud on
/// anything still wired without its services), constructs the env chain
/// and the canonical tool list.
WiredAgentCore wireAgentCore({
  required HostCapabilityProfile profile,
  required AgentCoreServices services,
}) {
  final runProfile = _narrowToServices(
    profile: profile,
    present: services.providedServiceNames,
  );
  final plan = HostWiringBuilder(
    profile: runProfile,
    // E1 input: the narrowed profile only leaves wired what the bundle
    // provides, so the names themselves satisfy the service contract.
    platformServices: {
      for (final name in services.providedServiceNames) name: services,
    },
  ).build();

  // ---- env chain ----
  var env = services.baseEnv;
  SandboxedExecutionEnv? sandboxEnv;
  if (plan.planFor(HostCapability.sandboxEnv) is WiredCapability) {
    final sandbox =
        services.sandbox ??
        (throw HostWiringException(
          'Profile "${plan.profile.name}" wires the sandbox capability but '
          'the host provided no SandboxServices (E1: name the missing '
          'service, never null-crash at runtime).',
        ));
    sandboxEnv = SandboxedExecutionEnv(
      env,
      sandbox.spec,
      homeDir: sandbox.homeDir,
      workspaceRoot: env.cwd,
      pathProbe: sandbox.pathProbe,
      os: sandbox.os,
      onWarning: sandbox.onWarning,
    );
    env = sandboxEnv;
  }
  final sessionVars = services.sessionEnvVars;
  if (sessionVars != null) {
    env = SessionVarsExecutionEnv(env, sessionVars);
  }
  final sandbox = sandboxEnv;
  final networkGate = sandbox == null
      ? null
      : CubeNetworkGate(() => sandbox.activeSpec);

  // ---- env-dependent services ----
  final shellJobs = services.shellJobsFactory?.call(env);
  final configService = services.configServiceFactory?.call(env);

  // backgroundShellJobs is PLAN-gated, not factory-gated (review, #1230):
  // "off means absent from tools AND surfaced tokens" — a host that
  // profiles the capability off but still provides a factory must not
  // see the bash_job board.
  final gatedShellJobs =
      plan.planFor(HostCapability.backgroundShellJobs) is WiredCapability
      ? shellJobs
      : null;

  // ---- host extensions (slice 4, HostExtensionApi) ----
  // The surface RIDES the hostExtensionApi capability cell: a profile
  // declaring it off hides every declared extension with the cell's
  // reason — the same hide-with-reason contract as any off capability
  // (E8). Declared-but-unenforced would make the cell decorative (E2:
  // silence is not a declaration). E6 was enforced at construction
  // (every built-in profile declared); below, the builder resolves each
  // extension against the profile the host actually wires (custom
  // profiles included — a missing state is a wire-time E6 violation).
  // The E7 collision check runs after the task complex assembles.
  final extensionCell = plan.planFor(HostCapability.hostExtensionApi);
  final extensionWiring = extensionCell is WiredCapability
      ? _wireExtensions(
          profileName: profile.name,
          extensions: services.extensions,
        )
      : [
          for (final extension in services.extensions)
            WiredHostExtension(
              extension: extension,
              tools: const [],
              hiddenReason: (extensionCell as HiddenCapability).reason,
            ),
        ];

  // Tools first, core second: the list rides the constructor so a wired
  // core can never exist without its tools. The agent closures read the
  // late-bound agent through the (already-assigned by first use) core.
  late final WiredAgentCore core;
  final sdkTools = _buildCoreTools(
    plan: plan,
    env: env,
    networkGate: networkGate,
    shellJobs: gatedShellJobs,
    services: services,
    configService: configService,
    currentAgent: () => core._agent,
  );
  // The wired extension tools splice after the SDK core — the canonical
  // tail position the raw hostTools list occupied (slice 4).
  final tools = [
    ...sdkTools,
    for (final wired in extensionWiring) ...wired.tools,
  ];
  // The task/subagent complex (slice 3) assembles after the core list —
  // children draw it as their tool pool — and reads the late-bound agent
  // through the same closure. The fabric assembles independently: the
  // MAIN inbox drain rides it wherever messagingFabric wires.
  final fabricAssembly = _wireFabric(plan: plan, services: services);
  final taskComplex = _wireTaskSurface(
    plan: plan,
    services: services,
    fabric: fabricAssembly?.fabric,
    coreTools: tools,
    currentAgent: () => core._agent,
  );
  // E7, over every statically assembled surface — AFTER the complex so
  // its gated surface joins the check, BEFORE anything reaches a registry.
  _rejectToolIdCollisions({
    'the SDK core': sdkTools,
    if (taskComplex != null) 'the task surface': taskComplex.tools,
    for (final wired in extensionWiring.where((w) => !w.isHidden))
      'extension "${wired.extension.name}"': wired.tools,
  });
  core = WiredAgentCore._(
    plan: plan,
    services: services,
    env: env,
    sandboxEnv: sandboxEnv,
    networkGate: networkGate,
    shellJobs: gatedShellJobs,
    tools: tools,
    fabric: fabricAssembly?.fabric,
    fileFabric: fabricAssembly?.fileFabric,
    messagesRoot: fabricAssembly?.messagesRoot,
    subagentManager: taskComplex?.subagentManager,
    a2aManager: taskComplex?.a2aManager,
    subagentHeartbeat: taskComplex?.subagentHeartbeat,
    taskConfig: taskComplex?.taskConfig,
    taskSurface: taskComplex?.tools ?? const [],
    extensions: extensionWiring,
  );
  return core;
}

/// Resolves each declared extension against the profile the host wires
/// (slice 4): `on` → its tools wire; `off` → hidden with the reason (E8);
/// a custom profile without a state → wire-time E6 violation. The base
/// profile name drives the lookup — run-narrowing renames the profile
/// (`cli.run`) but an extension's matrix is declared per base profile.
List<WiredHostExtension> _wireExtensions({
  required String profileName,
  required List<HostExtension> extensions,
}) => [
  for (final extension in extensions)
    switch (extension.stateFor(profileName)) {
      null => throw HostWiringException(
        'HostExtension "${extension.name}" declares no state for profile '
        '"$profileName" — declare every profile the host can wire (E6: '
        'built-ins at construction, customs before wiring).',
      ),
      final CapabilityOffState off => WiredHostExtension(
        extension: extension,
        tools: const [],
        hiddenReason: off.reason,
      ),
      _ => WiredHostExtension(
        extension: extension,
        tools: List.unmodifiable(extension.tools),
      ),
    },
];

/// E7, builder edition: tool-id collisions across the statically
/// assembled surfaces are rejected at build time with both registrants
/// named. The [ToolRegistry]'s own replace-and-note leniency stays for
/// the child-pool contract (issue #862) and the per-run
/// `buildAgentStack(additionalTools:)` surface — the STATIC host/SDK
/// wiring gets the loud check instead, because an extension id colliding
/// with a core tool would silently override SDK behavior.
void _rejectToolIdCollisions(Map<String, List<AgentTool>> groups) {
  final owner = <String, String>{};
  void claim(String registrant, Iterable<AgentTool> tools) {
    for (final tool in tools) {
      final previous = owner[tool.name];
      if (previous != null) {
        throw HostWiringException(
          'Tool-id collision at build time (E7): "${tool.name}" is '
          'registered by both $previous and $registrant — the builder '
          'never silently replaces a tool; rename one of the two.',
        );
      }
      owner[tool.name] = registrant;
    }
  }

  for (final MapEntry(key: registrant, value: tools) in groups.entries) {
    claim(registrant, tools);
  }
}

/// Run-narrows [profile] against the service names the host provided:
/// wired capabilities with absent required services turn `off(reason)`;
/// wired transports with absent per-transport services are dropped (to
/// zero = `off`). Unwired capabilities and fully-served states pass
/// through untouched.
HostCapabilityProfile _narrowToServices({
  required HostCapabilityProfile profile,
  required Set<String> present,
}) {
  String missingServices(Set<String> services) =>
      (services.difference(present).toList()..sort()).join(', ');
  final overrides = <HostCapability, CapabilityState>{};
  for (final capability in HostCapability.values) {
    final state = profile.stateFor(capability);
    if (state is CapabilityOffState) continue;
    final spec = hostCapabilityCatalog[capability]!;
    final wiredTransports = switch (state) {
      CapabilityOnState() => hostCapabilityTransports[capability]!.defaults,
      CapabilityTransportState(:final transports) => transports,
      CapabilityOffState() => const <String>{},
    };
    final missingBase = spec.requiredServices.difference(present);
    if (missingBase.isNotEmpty) {
      overrides[capability] = CapabilityOffState(
        'not wired this run: platform service(s) '
        '${missingServices(spec.requiredServices)} not provided (config '
        'section absent, or the host lacks the facility)',
      );
      continue;
    }
    final kept = {
      for (final transport in wiredTransports)
        if (spec.requiredServicesByTransport[transport]
                ?.difference(present)
                .isEmpty ??
            true)
          transport,
    };
    if (kept.length == wiredTransports.length) continue;
    final dropped = wiredTransports.difference(kept).toList()..sort();
    if (kept.isEmpty) {
      overrides[capability] = CapabilityOffState(
        'not wired this run: transport(s) $dropped dropped — their platform '
        'services were not provided',
      );
    } else {
      overrides[capability] = CapabilityTransportState(
        kept,
        'transport(s) $dropped dropped this run: their platform services '
        'were not provided; the remaining transports still wire',
      );
    }
  }
  if (overrides.isEmpty) return profile;
  return profile.narrowed(overrides, name: '${profile.name}.run');
}
