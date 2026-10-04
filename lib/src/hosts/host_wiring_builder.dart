/// The host-wiring catalog, the typed build plan, and the seven built-in
/// profiles (issue #1079, slice 1 — SDK foundation, additive).
///
/// The **catalog** ([hostCapabilityCatalog]) is the union of what the CLI
/// wires today — the ceiling invariant: SDK ⊇ CLI (AC10). Every
/// matrix-pinned row is here cell-exact; the rows the matrix leaves
/// unpinned but the CLI demonstrably wires (verified sweep, 2026-09-29)
/// enter as inventory-driven capabilities with honest today-states.
///
/// The **builder** ([HostWiringBuilder]) consumes a [profile] plus the
/// host's platform services and returns a typed [HostWiringPlan]: which
/// capabilities wire (and over which transports), which stay hidden with
/// their reasons, and which model-facing surface tokens disappear with
/// them (the hide-if-off invariant, AC7). Slice 1 returns the PLAN only —
/// no host migrates, no live Agent stack is constructed (slice 2).
///
/// Pure Dart: no `dart:io`.
library;

import '../exceptions.dart';
import 'host_capability_profile.dart';

/// What surfaces when a capability is wired: the strings that appear in
/// tool schemas, prompt sections and help. When a capability is `off`,
/// NONE of these may appear on any model-facing or user-facing surface
/// (AC7 — asserted by the hiding helper and, in slice 2, by emission).
final class CapabilitySurface {
  /// Tool names / prompt tokens / config keys the capability emits.
  final Set<String> tokens;

  /// Prompt section ids gated by the capability.
  final Set<String> promptSectionIds;

  const CapabilitySurface({
    this.tokens = const {},
    this.promptSectionIds = const {},
  });
}

/// One catalog entry: a wireable capability, its CLI-ceiling evidence, and
/// its surface.
final class CapabilitySpec {
  final HostCapability capability;

  /// Human title (matrix row name).
  final String title;

  /// What wiring this stands for; for matrix rows, the pinned cells live in
  /// the built-in profiles, not here.
  final String note;

  /// Where the CLI wires this today (the ceiling evidence). Empty for
  /// capabilities the CLI floors off (the row exists for other hosts).
  final List<String> cliWiringSites;

  /// Platform-service keys [HostWiringBuilder] requires whenever the
  /// capability is wired (E1: a missing service fails at build, named).
  final Set<String> requiredServices;

  /// Extra service keys required only when the cell's declared transports
  /// include the key's transport — on top of [requiredServices]. This keeps
  /// E1 honest for split cells: a web `sqlite_lsp_dap: transport({sqljs})`
  /// host needs the sql.js-backed engine but no process lsp factory.
  final Map<String, Set<String>> requiredServicesByTransport;

  final CapabilitySurface surface;

  const CapabilitySpec({
    required this.capability,
    required this.title,
    required this.note,
    this.cliWiringSites = const [],
    this.requiredServices = const {},
    this.requiredServicesByTransport = const {},
    this.surface = const CapabilitySurface(),
  });
}

/// The capability catalog — the CLI's ceiling (AC10). Wiring sites cite the
/// verified sweep (2026-09-29); line anchors drift, the files are the
/// contract.
final Map<HostCapability, CapabilitySpec>
hostCapabilityCatalog = Map.unmodifiable({
  HostCapability.configSections: CapabilitySpec(
    capability: HostCapability.configSections,
    title:
        'Config sections (roles:/tools:/ttsr:/redact:/providerTimeouts:/agent:)',
    note: 'Parsed once, applied to every host whose profile has the row on.',
    cliWiringSites: [
      'bin/fah.dart (AgentCliConfig)',
      'lib/src/cli/cli_config.dart (fromYaml)',
    ],
    surface: CapabilitySurface(
      tokens: {'roles:', 'ttsr:', 'redact:', 'providerTimeouts:'},
      promptSectionIds: {'config-sections'},
    ),
  ),
  HostCapability.compaction: CapabilitySpec(
    capability: HostCapability.compaction,
    title: 'Compaction wiring',
    note: 'roles.smol judge, overWindowRelief, contextWindowCap (#1077).',
    cliWiringSites: [
      'bin/fah.dart (compactionEngine, contextWindowCap)',
      'lib/src/cli/agent_cli.dart',
    ],
    surface: CapabilitySurface(
      tokens: {'overWindowRelief', 'contextWindowCap'},
      promptSectionIds: {'compaction'},
    ),
  ),
  HostCapability.loadModes: CapabilitySpec(
    capability: HostCapability.loadModes,
    title: 'Load modes + discover_tools',
    note: 'Essential-set demotion and the discover_tools registration.',
    cliWiringSites: [
      'bin/fah.dart (loadMode)',
      'lib/src/cli/agent_cli_tools.dart',
    ],
    surface: CapabilitySurface(tokens: {'discover_tools'}),
  ),
  HostCapability.mcp: CapabilitySpec(
    capability: HostCapability.mcp,
    title: 'MCP servers',
    note:
        'Transports: stdio (spawned) + remote (HTTP). One '
        'transport-parametrized factory: it creates exactly the transports '
        'the cell declares — stdio spawn on process hosts, remote fetch on '
        'web/extension — so a remote-only host never supplies a stdio '
        'spawner.',
    cliWiringSites: [
      'bin/fah.dart (mcpConfig)',
      'lib/src/mcp/io_mcp_transport.dart',
      'lib/src/mcp/mcp_http_transport.dart',
    ],
    requiredServices: {'mcpTransportFactory'},
    surface: CapabilitySurface(
      tokens: {'mcp__', 'mcp:'},
      promptSectionIds: {'mcp'},
    ),
  ),
  HostCapability.messagingFabric: CapabilitySpec(
    capability: HostCapability.messagingFabric,
    title: 'Messaging fabric',
    note: 'Transports: file + hub (FallbackMessagingRepository) + a2a. The '
        'file transport needs no host service; hub rides the hub plugin '
        '(slice-2 run-narrowing drops the hub transport when the plugin is '
        'absent — the file fabric keeps working).',
    cliWiringSites: [
      'lib/src/messaging/agent_fabric.dart (buildAgentFabric)',
      'bin/fah.dart (a2aConfig, hubFabric)',
    ],
    requiredServicesByTransport: {'hub': {'hubFabric'}},
    surface: CapabilitySurface(
      tokens: {'schedule_message', 'agent_message', 'a2a'},
    ),
  ),
  HostCapability.approvalGate: CapabilitySpec(
    capability: HostCapability.approvalGate,
    title: 'Approval gate',
    note: 'Modes + unattended + always-allow sets.',
    cliWiringSites: [
      'bin/fah.dart (approvalMode, alwaysAllowTools)',
      'lib/src/cli/agent_cli.dart (ApprovalManager)',
    ],
    surface: CapabilitySurface(
      tokens: {'approval'},
      promptSectionIds: {'approval'},
    ),
  ),
  HostCapability.skills: CapabilitySpec(
    capability: HostCapability.skills,
    title: 'Skills + project context',
    note: 'Skill discovery roots and the AGENTS.md project context.',
    cliWiringSites: [
      'lib/src/cli/agent_cli.dart (discoverSkills)',
      'bin/fah.dart (skillsAccess)',
    ],
    surface: CapabilitySurface(
      tokens: {'skills'},
      promptSectionIds: {'skills'},
    ),
  ),
  HostCapability.sandboxEnv: CapabilitySpec(
    capability: HostCapability.sandboxEnv,
    title: 'Sandbox env',
    note:
        'Backends: cube (passthrough/policy/kernel) + local on the CLI; '
        'platform / WasiSandbox / MemoryShell are host-side factories.',
    cliWiringSites: [
      'bin/fah.dart (cubeSpec, fsProbe)',
      'lib/src/cli/agent_cli.dart (SandboxedExecutionEnv)',
    ],
    requiredServices: {'cubeSpec', 'fsProbe'},
    surface: CapabilitySurface(tokens: {'cube', 'sandbox'}),
  ),
  HostCapability.backgroundShellJobs: CapabilitySpec(
    capability: HostCapability.backgroundShellJobs,
    title: 'Background shell jobs',
    note: 'The bash_job board over .fah/bash_jobs logs.',
    cliWiringSites: [
      'bin/fah.dart (jobs)',
      'lib/src/cli/agent_cli.dart (ShellJobRegistry)',
    ],
    // Review #1230: with no required services the capability could never
    // be run-narrowed off — a host without a job factory kept it "wired".
    requiredServices: {'shellJobFactory'},
    surface: CapabilitySurface(tokens: {'bash_job'}),
  ),
  HostCapability.sqliteLspDap: CapabilitySpec(
    capability: HostCapability.sqliteLspDap,
    title: 'sqlite / lsp / dap',
    note: 'FFI sqlite reader, process lsp transport, dap_* via the hub plugin. '
        'Per-transport services: the sqlite reader rides the ffi transport, '
        'the lsp tool the process transport — a host without one keeps the '
        'other (the base file tools never depend on this row).',
    cliWiringSites: [
      'bin/fah.dart (sqliteEngine, lspConfig, dapHubState)',
      'bin/fah_hub_plugin.dart (registerTool)',
    ],
    requiredServicesByTransport: {
      'ffi': {'sqliteEngine'},
      'process': {'lspTransportFactory'},
    },
    surface: CapabilitySurface(tokens: {'sqlite', 'lsp', 'dap'}),
  ),
  HostCapability.onDeviceProviders: CapabilitySpec(
    capability: HostCapability.onDeviceProviders,
    title: 'On-device providers (webllm/gemma)',
    note:
        'NOT CLI-wired (matrix ❌ on the VM); wired in the Flutter app '
        '(flutter_app/lib/main.dart).',
    requiredServices: {'onDeviceProviderFactory'},
    surface: CapabilitySurface(tokens: {'webllm', 'gemma'}),
  ),
  HostCapability.jsApps: CapabilitySpec(
    capability: HostCapability.jsApps,
    title: 'JS apps (jsr) + dynamic_message',
    note:
        'The browser-API app surface — matrix-pinned off on the VM. Owns '
        'NO bare "jsr" token: the CLI wires an `fa jsr` widget pass-through '
        '(#1062), claimed by [HostCapability.jsExtensions]. The CLI\'s '
        'process-based QuickJS machinery is [HostCapability.jsExtensions].',
    requiredServices: {'dynamicMessageSink'},
    surface: CapabilitySurface(
      tokens: {'dynamic_message'},
      promptSectionIds: {'js-apps'},
    ),
  ),
  HostCapability.checkpointRewind: CapabilitySpec(
    capability: HostCapability.checkpointRewind,
    title: 'Checkpoint / rewind',
    note: 'CheckpointRewindController + checkpoint/rewind tools.',
    cliWiringSites: ['lib/src/cli/agent_cli.dart (CheckpointRewindController)'],
    surface: CapabilitySurface(tokens: {'checkpoint', 'rewind'}),
  ),
  HostCapability.hostExtensionApi: CapabilitySpec(
    capability: HostCapability.hostExtensionApi,
    title: 'Host extension API',
    note:
        'PluginContext.register — host tools, inboxes, slash commands. '
        'Core behaviors stay SDK-invariant (AC9).',
    cliWiringSites: [
      'bin/fah.dart (plugins, pluginConfig)',
      'lib/src/cli/agent_cli.dart (PluginContext)',
    ],
    surface: CapabilitySurface(
      tokens: {'plugin'},
      promptSectionIds: {'extensions'},
    ),
  ),
  HostCapability.webSearch: CapabilitySpec(
    capability: HostCapability.webSearch,
    title: 'Web search',
    note:
        'Inventory-driven (AC10): web_search/web_fetch over '
        'WebSearchConfig secrets; no matrix row pins it.',
    cliWiringSites: [
      'bin/fah.dart (webSearchConfig)',
      'lib/src/cli/agent_cli_tools.dart',
    ],
    requiredServices: {'webSearchSecrets'},
    surface: CapabilitySurface(tokens: {'web_search', 'web_fetch'}),
  ),
  HostCapability.visionTranscribe: CapabilitySpec(
    capability: HostCapability.visionTranscribe,
    title: 'Vision + transcribe',
    note:
        'Inventory-driven (AC10): inspect_image/transcribe_audio/image '
        'generation over the host vision/transcribe configs. No REQUIRED '
        'services: the CLI registers generate_image/generate_video '
        'unconditionally (config-gated models), and inspect/transcribe '
        'ride per-tool config presence inside the assembly — the row '
        'narrows only when a host profile declares it off.',
    cliWiringSites: [
      'bin/fah.dart (visionConfig, transcribeConfig)',
      'lib/src/cli/agent_cli.dart',
    ],
    surface: CapabilitySurface(
      tokens: {'inspect_image', 'transcribe_audio', 'generate_image'},
    ),
  ),
  HostCapability.subagents: CapabilitySpec(
    capability: HostCapability.subagents,
    title: 'Subagents + task system',
    note:
        'Inventory-driven (AC10): subagents: config, SubagentManager, '
        'task/agent tools, heartbeat.',
    cliWiringSites: [
      'bin/fah.dart (subagents)',
      'lib/src/cli/agent_cli.dart (SubagentManager, taskTool)',
    ],
    requiredServices: {'sessionRoot'},
    surface: CapabilitySurface(tokens: {'task', 'agent_directory', 'subagent'}),
  ),
  HostCapability.browserBridge: CapabilitySpec(
    capability: HostCapability.browserBridge,
    title: 'Browser bridge tools',
    note:
        'Inventory-driven (AC10): the browser_* family over the loopback '
        'bridge — the automation surface the CLI wires today.',
    cliWiringSites: [
      'bin/fah.dart (browserBridgeHandle, browserController)',
      'lib/src/cli/agent_cli.dart (browserTools)',
    ],
    requiredServices: {'browserBridgeHandle'},
    surface: CapabilitySurface(
      tokens: {'browser_navigate', 'browser_click', 'browser_eval'},
    ),
  ),
  HostCapability.jsExtensions: CapabilitySpec(
    capability: HostCapability.jsExtensions,
    title: 'QuickJS JS extensions + jsr widget pass-through',
    note:
        'Inventory-driven (AC10): per-extension isolated QuickJS engines '
        '(process transport) — not the browser-API [HostCapability.jsApps] '
        'row. Owns the `fa jsr` widget pass-through + `/jsr` REPL alias '
        '(#1062): the only legitimate "jsr" surfaces on the CLI.',
    cliWiringSites: [
      'bin/fah.dart (extRuntimeFactory)',
      'lib/src/cli/agent_cli.dart (initJsExtensions)',
    ],
    requiredServices: {'extRuntimeFactory'},
    surface: CapabilitySurface(tokens: {'js_ext', 'jsr.ext', 'fa jsr', '/jsr'}),
  ),
});

/// Why a capability is wired or hidden in a build plan.
sealed class CapabilityPlanEntry {
  final HostCapability capability;

  const CapabilityPlanEntry(this.capability);
}

/// The capability wires over [transports] (empty = no transport dimension).
final class WiredCapability extends CapabilityPlanEntry {
  final Set<String> transports;

  const WiredCapability(super.capability, this.transports);
}

/// The capability stays hidden; [reason] is the profile's declared one.
final class HiddenCapability extends CapabilityPlanEntry {
  final String reason;

  const HiddenCapability(super.capability, this.reason);
}

/// Thrown when the builder cannot satisfy the profile with the services the
/// host provided (E1: the missing service is named, never a null crash).
class HostWiringException extends ConfigException {
  const HostWiringException(super.message);
}

/// The typed wiring description a [HostWiringBuilder] returns.
///
/// Slice 1: a description, not a live stack. Slice 2 turns wired entries
/// into the Agent/registry/env wiring on behalf of every host shell.
final class HostWiringPlan {
  final HostCapabilityProfile profile;

  /// Per-capability plan, complete over the catalog.
  final List<CapabilityPlanEntry> entries;

  /// The platform services the builder was constructed with (carried for
  /// the slice-2 wiring step).
  final Map<String, Object> platformServices;

  HostWiringPlan({
    required this.profile,
    required List<CapabilityPlanEntry> entries,
    required this.platformServices,
  }) : entries = List.unmodifiable(entries);

  Iterable<WiredCapability> get wired => entries.whereType<WiredCapability>();

  Iterable<HiddenCapability> get hidden =>
      entries.whereType<HiddenCapability>();

  /// Every model/user-facing token the plan emits: wired capabilities'
  /// surface tokens plus per-transport qualified tokens (`mcp:stdio`).
  /// Off capabilities contribute NOTHING — the AC7 hiding contract.
  Set<String> get surfacedTokens => {
    for (final entry in wired)
      ...hostCapabilityCatalog[entry.capability]!.surface.tokens,
    for (final entry in wired)
      if (entry.transports.isNotEmpty)
        for (final t in entry.transports) '${entry.capability.id}:$t',
  };

  /// Prompt sections the plan emits (wired capabilities only).
  Set<String> get promptSections => {
    for (final entry in wired)
      ...hostCapabilityCatalog[entry.capability]!.surface.promptSectionIds,
  };

  CapabilityPlanEntry planFor(HostCapability capability) =>
      entries.firstWhere((e) => e.capability == capability);
}

/// Builds the typed wiring plan for a profile + platform services.
///
/// Slice 1 skeleton: validates that every wired capability's required
/// platform services are present (E1), then describes the wiring. It does
/// NOT construct an Agent stack — that is slice 2, and nothing existing
/// migrates until then.
final class HostWiringBuilder {
  final HostCapabilityProfile profile;

  /// Host-provided platform services, keyed by
  /// [CapabilitySpec.requiredServices] names (transport factories, stores,
  /// probes).
  final Map<String, Object> platformServices;

  HostWiringBuilder({required this.profile, this.platformServices = const {}});

  HostWiringPlan build() {
    final entries = <CapabilityPlanEntry>[];
    final missing = <String, Set<String>>{};
    for (final capability in HostCapability.values) {
      final state = profile.stateFor(capability);
      final spec = hostCapabilityCatalog[capability]!;
      switch (state) {
        case CapabilityOffState(:final reason):
          entries.add(HiddenCapability(capability, reason));
        case CapabilityOnState():
          _requireServices(
            missing,
            capability,
            spec,
            hostCapabilityTransports[capability]!.defaults,
          );
          entries.add(
            WiredCapability(
              capability,
              hostCapabilityTransports[capability]!.defaults,
            ),
          );
        case CapabilityTransportState(:final transports):
          _requireServices(missing, capability, spec, transports);
          entries.add(WiredCapability(capability, transports));
      }
    }
    if (missing.isNotEmpty) {
      throw HostWiringException(
        'Profile "${profile.name}" cannot build: missing platform services '
        '${missing.entries.map((e) => '${e.key}: ${e.value.toList()..sort()}').join('; ')} '
        '(E1: name the missing service, never null-crash at runtime).',
      );
    }
    return HostWiringPlan(
      profile: profile,
      entries: entries,
      platformServices: platformServices,
    );
  }

  void _requireServices(
    Map<String, Set<String>> missing,
    HostCapability capability,
    CapabilitySpec spec,
    Set<String> wiredTransports,
  ) {
    // Baseline services plus the per-transport extras the wired cell
    // actually declares — never the transports it cannot use.
    final needed = <String>{
      ...spec.requiredServices,
      for (final entry in spec.requiredServicesByTransport.entries)
        if (wiredTransports.contains(entry.key)) ...entry.value,
    };
    final absent = needed.difference(platformServices.keys.toSet());
    if (absent.isNotEmpty) missing[capability.id] = absent;
  }
}

// ---------------------------------------------------------------------------
// Built-in profiles — the matrix pinned cell-exact (issue #1079). The five
// inventory-driven rows (webSearch..jsExtensions) are on for the CLI and
// off elsewhere with the honest today-reason; slice 2+ raises hosts by
// changing the declaration (and floor) explicitly, never by narrowing.
// ---------------------------------------------------------------------------

/// `_inventoryRow`: the shared off-state for inventory-driven rows on
/// hosts that have not wired them yet.
CapabilityOffState _inventoryRow(String host) => CapabilityOffState(
  'not wired in the $host host yet; the CLI is the only host wiring it '
  'today (inventory sweep 2026-09-29); raising this host is an explicit '
  'slice-2+ declaration',
);

final HostCapabilityProfile cliProfile = HostCapabilityProfile(
  name: 'cli',
  states: {
    HostCapability.configSections: CapabilityState.on,
    HostCapability.compaction: CapabilityState.on,
    HostCapability.loadModes: CapabilityState.on,
    HostCapability.mcp: CapabilityState.on,
    HostCapability.messagingFabric: CapabilityState.on,
    HostCapability.approvalGate: CapabilityState.on,
    HostCapability.skills: CapabilityState.on,
    HostCapability.sandboxEnv: CapabilityState.on,
    HostCapability.backgroundShellJobs: CapabilityState.on,
    HostCapability.sqliteLspDap: CapabilityState.on,
    HostCapability.onDeviceProviders: CapabilityOffState(
      'no in-process inference runtime on the VM host; the CLI targets '
      'server providers (matrix ❌)',
    ),
    HostCapability.jsApps: CapabilityOffState(
      'no browser APIs on the Dart VM; jsr apps and dynamic_message need a '
      'JS host (matrix ❌) — never rendered in CLI prompts/help',
    ),
    HostCapability.checkpointRewind: CapabilityState.on,
    HostCapability.hostExtensionApi: CapabilityState.on,
    HostCapability.webSearch: CapabilityState.on,
    HostCapability.visionTranscribe: CapabilityState.on,
    HostCapability.subagents: CapabilityState.on,
    HostCapability.browserBridge: CapabilityState.on,
    HostCapability.jsExtensions: CapabilityState.on,
  },
  // Hard VM floors beyond the derived ones: the VM cannot grow a browser
  // API or an in-process inference runtime by narrowing.
  floors: {
    HostCapability.onDeviceProviders: const FloorOff(
      'the Dart VM host wires no in-process inference runtime',
    ),
    HostCapability.jsApps: const FloorOff(
      'browser APIs do not exist on the Dart VM',
    ),
  },
);

final HostCapabilityProfile macosProfile = HostCapabilityProfile(
  name: 'macos',
  states: {
    HostCapability.configSections: CapabilityState.on,
    HostCapability.compaction: CapabilityState.on,
    HostCapability.loadModes: CapabilityState.on,
    HostCapability.mcp: CapabilityTransportState(
      {'remote'},
      'stdio servers need an unsandboxed host process; the app defaults to '
      'remote MCP (matrix: remote + stdio unsandboxed)',
    ),
    HostCapability.messagingFabric: CapabilityTransportState({
      'file',
      'hub',
    }, 'the file fabric lives in the App Group container; no A2A gateway'),
    HostCapability.approvalGate: CapabilityState.on,
    HostCapability.skills: CapabilityState.on,
    HostCapability.sandboxEnv: CapabilityState.on,
    HostCapability.backgroundShellJobs: CapabilityState.on,
    HostCapability.sqliteLspDap: CapabilityTransportState(
      {'ffi', 'process'},
      'app-bundle wiring: sqlite loads via FFI and lsp/dap servers spawn as '
      'child processes of the app',
    ),
    // Single-transport vocabulary, so `transport({'in-process'})` and `on`
    // wire identically; the cell records the matrix's 🔀 (non-default on
    // desktop), not a narrower capability set.
    HostCapability.onDeviceProviders: CapabilityTransportState(
      {'in-process'},
      'in-process inference is available; the desktop default stays server '
      'providers',
    ),
    HostCapability.jsApps: CapabilityState.on,
    HostCapability.checkpointRewind: CapabilityState.on,
    HostCapability.hostExtensionApi: CapabilityState.on,
    HostCapability.webSearch: _inventoryRow('macOS app'),
    HostCapability.visionTranscribe: _inventoryRow('macOS app'),
    HostCapability.subagents: _inventoryRow('macOS app'),
    HostCapability.browserBridge: _inventoryRow('macOS app'),
    HostCapability.jsExtensions: _inventoryRow('macOS app'),
  },
  // macOS CAN spawn stdio servers (unsandboxed) — the floor keeps both
  // transports so a host may narrow UP to stdio explicitly.
  floors: {
    HostCapability.mcp: const FloorTransports({'stdio', 'remote'}),
  },
);

HostCapabilityProfile _mobileProfile(
  String name,
  String host,
  String jobsTransport,
) => HostCapabilityProfile(
  name: name,
  states: {
    HostCapability.configSections: CapabilityState.on,
    HostCapability.compaction: CapabilityState.on,
    HostCapability.loadModes: CapabilityState.on,
    HostCapability.mcp: CapabilityTransportState({
      'remote',
    }, '$host cannot spawn stdio servers; remote MCP only'),
    HostCapability.messagingFabric: CapabilityTransportState({
      'hub',
    }, 'no shared filesystem; hub-only messaging'),
    HostCapability.approvalGate: CapabilityState.on,
    HostCapability.skills: CapabilityState.on,
    HostCapability.sandboxEnv: CapabilityState.on,
    HostCapability.backgroundShellJobs: CapabilityTransportState(
      {jobsTransport},
      'no raw process board; background shell runs as $jobsTransport '
      'jobs',
    ),
    HostCapability.sqliteLspDap: CapabilityOffState(
      'no FFI and no child-process spawning in the $host sandbox',
    ),
    HostCapability.onDeviceProviders: CapabilityState.on,
    HostCapability.jsApps: CapabilityState.on,
    HostCapability.checkpointRewind: CapabilityTransportState({
      'origin-storage',
    }, 'checkpoints persist in app storage, not the session root'),
    HostCapability.hostExtensionApi: CapabilityState.on,
    HostCapability.webSearch: _inventoryRow(host),
    HostCapability.visionTranscribe: _inventoryRow(host),
    HostCapability.subagents: _inventoryRow(host),
    HostCapability.browserBridge: _inventoryRow(host),
    HostCapability.jsExtensions: _inventoryRow(host),
  },
);

final HostCapabilityProfile iosProfile = _mobileProfile('ios', 'iOS', 'future');

final HostCapabilityProfile androidProfile = _mobileProfile(
  'android',
  'Android',
  'async',
);

final HostCapabilityProfile webProfile = HostCapabilityProfile(
  name: 'web',
  states: {
    HostCapability.configSections: CapabilityTransportState({
      'origin-storage',
    }, 'no filesystem; config lives in web origin storage'),
    HostCapability.compaction: CapabilityState.on,
    HostCapability.loadModes: CapabilityState.on,
    HostCapability.mcp: CapabilityTransportState({
      'remote',
    }, 'browsers cannot spawn stdio servers; remote MCP only'),
    HostCapability.messagingFabric: CapabilityTransportState({
      'hub',
    }, 'no shared filesystem; hub-only messaging'),
    HostCapability.approvalGate: CapabilityState.on,
    HostCapability.skills: CapabilityState.on,
    HostCapability.sandboxEnv: CapabilityState.on,
    HostCapability.backgroundShellJobs: CapabilityTransportState({
      'async',
    }, 'no process spawning; background jobs run on the platform event loop'),
    HostCapability.sqliteLspDap: CapabilityTransportState({
      'sqljs',
    }, 'sqlite runs via sql.js WASM; no lsp/dap process spawn'),
    HostCapability.onDeviceProviders: CapabilityState.on,
    HostCapability.jsApps: CapabilityState.on,
    HostCapability.checkpointRewind: CapabilityTransportState({
      'origin-storage',
    }, 'checkpoints persist in origin storage, not the session root'),
    HostCapability.hostExtensionApi: CapabilityState.on,
    HostCapability.webSearch: _inventoryRow('web app'),
    HostCapability.visionTranscribe: _inventoryRow('web app'),
    HostCapability.subagents: _inventoryRow('web app'),
    HostCapability.browserBridge: _inventoryRow('web app'),
    HostCapability.jsExtensions: _inventoryRow('web app'),
  },
);

HostCapabilityProfile _sandboxedWebProfile(String name, String host) =>
    HostCapabilityProfile(
      name: name,
      states: {
        HostCapability.configSections: CapabilityTransportState({
          'origin-storage',
        }, '$host sandbox; config persisted in the host store'),
        HostCapability.compaction: name == 'extension'
            ? CapabilityOffState(
                'the extension panel window is too small for compaction to '
                'pay off (matrix: "small window?")',
              )
            : CapabilityTransportState(
                {'origin-storage'},
                'compaction wired, but transcripts persist in the Office '
                'store, not the session root',
              ),
        HostCapability.loadModes: CapabilityTransportState({
          'registered-only',
        }, 'no project tree; load modes apply to host-registered tools only'),
        HostCapability.mcp: CapabilityTransportState({
          'remote',
        }, 'the $host sandbox cannot spawn stdio servers; remote MCP only'),
        HostCapability.messagingFabric: CapabilityTransportState(
          {'hub'},
          name == 'extension'
              ? 'hub/DM delivery only inside the manifest sandbox'
              : 'the add-in bridge routes hub messaging only',
        ),
        HostCapability.approvalGate: CapabilityState.on,
        HostCapability.skills: CapabilityTransportState({
          'registered',
        }, 'no project tree; host-registered skills only'),
        HostCapability.sandboxEnv: CapabilityOffState(
          'the $host sandbox provides no sandbox backend; the shell surface '
          'stays hidden',
        ),
        HostCapability.backgroundShellJobs: CapabilityOffState(
          'the $host sandbox has no shell',
        ),
        HostCapability.sqliteLspDap: CapabilityOffState(
          'the $host sandbox has no FFI and no process spawning',
        ),
        HostCapability.onDeviceProviders: name == 'extension'
            ? CapabilityTransportState({
                'in-process',
              }, 'in-process inference inside the extension offscreen page')
            : CapabilityOffState(
                'the Office add-in runtime has no headroom for in-process '
                'inference (matrix ❌)',
              ),
        HostCapability.jsApps: name == 'extension'
            ? CapabilityTransportState({
                'extension-subset',
              }, 'JSR/dynamic_message subset inside the extension runtime')
            // Outlook: ✅ with the matrix's "office tools" note.
            : CapabilityState.on,
        HostCapability.checkpointRewind: CapabilityOffState(
          'no persistent session store in the $host sandbox',
        ),
        HostCapability.hostExtensionApi: CapabilityState.on,
        HostCapability.webSearch: _inventoryRow(host),
        HostCapability.visionTranscribe: _inventoryRow(host),
        HostCapability.subagents: _inventoryRow(host),
        HostCapability.browserBridge: _inventoryRow(host),
        HostCapability.jsExtensions: _inventoryRow(host),
      },
    );

final HostCapabilityProfile extensionProfile = _sandboxedWebProfile(
  'extension',
  'extension',
);

final HostCapabilityProfile outlookProfile = _sandboxedWebProfile(
  'outlook',
  'Office add-in',
);

/// The seven built-in profiles by host name.
final Map<String, HostCapabilityProfile> builtInProfiles = Map.unmodifiable({
  cliProfile.name: cliProfile,
  macosProfile.name: macosProfile,
  iosProfile.name: iosProfile,
  androidProfile.name: androidProfile,
  webProfile.name: webProfile,
  extensionProfile.name: extensionProfile,
  outlookProfile.name: outlookProfile,
});
