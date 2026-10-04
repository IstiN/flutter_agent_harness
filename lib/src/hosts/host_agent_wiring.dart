/// Live agent-stack wiring through the builder (issue #1079, slice 2 —
/// the CLI converts to this as the first host shell).
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
import '../browser/browser_tools.dart';
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
import '../messaging/schedule_message_tool.dart';
import '../messaging/scheduled_messages.dart';
import '../mcp/mcp_manager.dart';
import '../model_roles/models_config.dart';
import '../tools/ask_tool.dart';
import '../tools/builtin_tools.dart';
import '../tools/generate_image.dart';
import '../tools/generate_video.dart';
import '../tools/inspect_image.dart';
import '../tools/password_prompt.dart';
import '../tools/request_secret_tool.dart';
import '../tools/shell_jobs.dart';
import '../tools/sqlite/sqlite_reader.dart';
import '../tools/transcribe_audio.dart';
import '../web_search/web_search_tool.dart';
import 'host_capability_profile.dart';
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
  final InspectImageConfig? vision;
  final TranscribeAudioConfig? transcribe;
  final MediaToolServices? media;
  final BrowserController? browserController;
  final Future<String> Function(Uint8List png)? saveBrowserScreenshot;

  /// Host-extension tools (the CLI's plugin surface — the public shape
  /// of what `FahPlugin` registers, issue #1079 HostExtensionApi).
  final List<AgentTool> hostTools;

  // Passthrough facilities the builder does not assemble yet but the
  // catalog's E1 contract declares for wired capabilities. Null =
  // honest run-narrowing of the affected capability/transport.
  final Object? hubFabric;
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
    this.vision,
    this.transcribe,
    this.media,
    this.browserController,
    this.saveBrowserScreenshot,
    this.hostTools = const [],
    this.hubFabric,
    this.extRuntimeFactory,
    this.sessionRoot,
  });

  /// The catalog service names this bundle provides — the run-narrowing
  /// input. Names match [CapabilitySpec.requiredServices] keys exactly.
  Set<String> get providedServiceNames => {
    if (sandbox != null) ...{'cubeSpec', 'fsProbe'},
    if (webSearch != null) 'webSearchSecrets',
    if (mcp != null) 'mcpTransportFactory',
    if (sqlite != null) 'sqliteEngine',
    if (lsp != null) 'lspTransportFactory',
    if (vision != null) 'visionConfig',
    if (transcribe != null) 'transcribeConfig',
    if (browserController != null) 'browserBridgeHandle',
    if (hubFabric != null) 'hubFabric',
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
  /// The plan the wired capabilities come from — run-narrowed.
  final HostWiringPlan plan;

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
  /// transcribe → media → browser → host tools).
  late final List<AgentTool> tools;

  Agent? _agent;

  WiredAgentCore._({
    required this.plan,
    required this.env,
    required this.sandboxEnv,
    required this.networkGate,
    required this.shellJobs,
  });

  /// Assembles the [ToolRegistry] (core tools first, then
  /// [additionalTools] — the host's task/monitoring surface) and the
  /// [Agent] over it. The model-reading tool closures resolve against
  /// the constructed agent, exactly like the host shells' own
  /// `() => _agent.state.model` today.
  WiredAgentStack buildAgentStack({
    required AgentWiringSpec spec,
    required StreamFunction streamFunction,
    List<AgentTool> additionalTools = const [],
    void Function(String note)? onDuplicate,
  }) {
    final registry = ToolRegistry([...tools, ...additionalTools], onDuplicate);
    final agent = _agent = Agent(
      model: spec.model,
      systemPrompt: spec.systemPrompt,
      streamFunction: streamFunction,
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
    return WiredAgentStack(registry: registry, agent: agent);
  }

  /// The canonical core tool list over [services]; media/browser
  /// closures read this core's late-bound agent.
  List<AgentTool> _buildTools({
    required AgentCoreServices services,
    required ConfigService? configService,
  }) {
    final media = services.media;
    final browser = switch (plan.planFor(HostCapability.browserBridge)) {
      WiredCapability() => browserTools(
        controller: services.browserController!,
        saveScreenshot: services.saveBrowserScreenshot!,
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
        model: () => _agent?.state.model,
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
                mainBaseUrl: () => _agent!.state.model.baseUrl,
                mainModelId: () => _agent!.state.model.id,
                mainApiKey: media.mainApiKey,
                resolveKey: media.resolveKey,
              ),
              generateVideoTool(
                env: env,
                modelsConfig: media.modelsConfig,
                mainBaseUrl: () => _agent!.state.model.baseUrl,
                mainModelId: () => _agent!.state.model.id,
                mainApiKey: media.mainApiKey,
                resolveKey: media.resolveKey,
              ),
            ],
      ...?browser,
      ...services.hostTools,
    ];
  }
}

/// The registry + agent a host shell drives after wiring.
final class WiredAgentStack {
  final ToolRegistry registry;
  final Agent agent;

  const WiredAgentStack({required this.registry, required this.agent});
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

  final core = WiredAgentCore._(
    plan: plan,
    env: env,
    sandboxEnv: sandboxEnv,
    networkGate: networkGate,
    shellJobs: shellJobs,
  );
  core.tools = core._buildTools(
    services: services,
    configService: configService,
  );
  return core;
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
