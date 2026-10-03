/// Declarative per-platform capability profiles (issue #1079, slice 1 —
/// SDK foundation, additive).
///
/// A [HostCapabilityProfile] is the per-platform half of the capability ×
/// platform matrix: for every [HostCapability] it declares ONE state —
///
/// - [CapabilityOnState] (`on`) — wired with the SDK's default transports;
/// - [CapabilityOffState] (`off(reason)`) — not wired; the reason is the
///   user-visible "why not" (it must surface in UI and prompts, never
///   silently);
/// - [CapabilityTransportState] (`transport(choice, reason)`) — wired, but
///   narrowed to specific transports/stores (the matrix's 🔀 cells).
///
/// The **narrowing invariant** (the tool-registry capability floor of
/// `resolveToolAvailability`, generalized to all host wiring): a profile
/// can only NARROW what its platform allows, never force-enable what the
/// platform lacks. Each capability has a [CapabilityFloor] — the platform's
/// ceiling — and every state is validated against it at construction.
/// Violations throw [HostProfileViolation] loudly at build time (AC4), not
/// at runtime.
///
/// Slice 1 ships the record types, the validation, the transport
/// vocabularies and the seven built-in profiles (in `host_wiring_builder.dart`).
/// No host migrates to them yet: hosts keep their hand-rolled wiring until
/// the builder slices land.
///
/// Pure Dart: no `dart:io`.
library;

import '../exceptions.dart';

/// A host-wiring capability: one row of the issue #1079 capability ×
/// platform matrix.
///
/// The set is closed on purpose (E2): adding a value breaks the
/// matrix-completeness contract until every built-in profile declares it —
/// "CLI got X, app didn't" dies at compile+construct time, not in a sweep.
enum HostCapability {
  /// `roles:`/`tools:`/`ttsr:`/`redact:`/`providerTimeouts:`/`agent:`
  /// config sections.
  configSections,

  /// Compaction wiring: roles.smol judge, `overWindowRelief`,
  /// `contextWindowCap`.
  compaction,

  /// Load modes + `discover_tools` demotion.
  loadModes,

  /// MCP servers.
  mcp,

  /// Messaging fabric transports (file / hub / A2A).
  messagingFabric,

  /// Approval gate (modes, unattended, always-allow).
  approvalGate,

  /// Skills + project context.
  skills,

  /// Sandbox env (cube / platform / WasiSandbox / MemoryShell).
  sandboxEnv,

  /// Background shell jobs (the `bash_job` board).
  backgroundShellJobs,

  /// sqlite reader, `lsp`, `dap` tool families.
  sqliteLspDap,

  /// On-device providers (webllm / gemma in-process inference).
  onDeviceProviders,

  /// JS apps (jsr) + `dynamic_message` — the browser-API surface.
  jsApps,

  /// Checkpoint / rewind.
  checkpointRewind,

  /// Host extension API: registering host tools / prompt sections /
  /// bridges through the builder. Core behaviors stay SDK-invariant.
  hostExtensionApi,

  /// `web_search`/`web_fetch` tools over the `WebSearchConfig` secrets.
  /// Beyond the issue matrix — inventory-driven (AC10, bin/fah.dart).
  webSearch,

  /// Vision + transcribe: `inspect_image`/`transcribe_audio`/image
  /// generation over the host `visionConfig`/`transcribeConfig`.
  /// Beyond the issue matrix — inventory-driven (AC10, bin/fah.dart).
  visionTranscribe,

  /// Subagents + task system: `subagents:` config, SubagentManager,
  /// `task*`/`agent_*` tools. Beyond the issue matrix — inventory-driven
  /// (AC10, agent_cli.dart:481-605).
  subagents,

  /// The browser tool family over the loopback bridge handle
  /// (`browser_navigate`, `browser_click`, …). Distinct from [jsApps]:
  /// this is the automation surface the CLI wires today (bin/fah.dart).
  /// Beyond the issue matrix — inventory-driven (AC10).
  browserBridge,

  /// The QuickJS extension host (`extRuntimeFactory`, `initJsExtensions`,
  /// `jsr_runtime`) — the CLI's process-based JS extension mechanism.
  /// Distinct from [jsApps] (the browser-API app surface, matrix-pinned
  /// off on the VM): QuickJS runs without a browser. Beyond the issue
  /// matrix — inventory-driven (AC10, bin/fah.dart).
  jsExtensions;

  /// Stable catalog id (snake_case, matches the matrix row).
  String get id => switch (this) {
    configSections => 'config_sections',
    compaction => 'compaction',
    loadModes => 'load_modes',
    mcp => 'mcp',
    messagingFabric => 'messaging_fabric',
    approvalGate => 'approval_gate',
    skills => 'skills',
    sandboxEnv => 'sandbox_env',
    backgroundShellJobs => 'background_shell_jobs',
    sqliteLspDap => 'sqlite_lsp_dap',
    onDeviceProviders => 'on_device_providers',
    jsApps => 'js_apps',
    checkpointRewind => 'checkpoint_rewind',
    hostExtensionApi => 'host_extension_api',
    webSearch => 'web_search',
    visionTranscribe => 'vision_transcribe',
    subagents => 'subagents',
    browserBridge => 'browser_bridge',
    jsExtensions => 'js_extensions',
  };
}

/// The SDK's transport vocabulary for one capability.
///
/// [all] — every transport/store the SDK can wire for the capability; a
/// [CapabilityTransportState] may only name transports from this set.
/// [defaults] — what the CLI (the catalog ceiling) wires by default; `on`
/// under a [FloorTransports] floor is legal only when every default
/// transport is inside the floor.
typedef CapabilityTransports = ({Set<String> all, Set<String> defaults});

/// Per-capability transport vocabularies. Capabilities without a transport
/// dimension map to an empty record — their profiles are plain on/off.
const Map<HostCapability, CapabilityTransports> hostCapabilityTransports = {
  HostCapability.configSections: (
    all: {'file', 'origin-storage'},
    defaults: {'file'},
  ),
  HostCapability.compaction: (
    all: {'session-root', 'origin-storage'},
    defaults: {'session-root'},
  ),
  HostCapability.loadModes: (
    all: {'project-scan', 'registered-only'},
    defaults: {'project-scan'},
  ),
  HostCapability.mcp: (all: {'stdio', 'remote'}, defaults: {'stdio', 'remote'}),
  HostCapability.messagingFabric: (
    all: {'file', 'hub', 'a2a'},
    defaults: {'file', 'hub', 'a2a'},
  ),
  HostCapability.approvalGate: (all: {}, defaults: {}),
  HostCapability.skills: (
    all: {'project', 'registered'},
    defaults: {'project'},
  ),
  // Sandbox BACKEND differences (cube/local vs platform/wasi/memory) are
  // descriptive ✅ cells, not 🔀 narrowing choices — `on` means "wired with
  // this platform's own backends"; the backend set stays host-side.
  HostCapability.sandboxEnv: (all: {}, defaults: {}),
  HostCapability.backgroundShellJobs: (
    all: {'process', 'future', 'async'},
    defaults: {'process'},
  ),
  HostCapability.sqliteLspDap: (
    all: {'ffi', 'process', 'sqljs'},
    defaults: {'ffi', 'process'},
  ),
  HostCapability.onDeviceProviders: (
    all: {'in-process'},
    defaults: {'in-process'},
  ),
  HostCapability.jsApps: (
    all: {'browser', 'extension-subset'},
    defaults: {'browser'},
  ),
  HostCapability.checkpointRewind: (
    all: {'file', 'origin-storage'},
    defaults: {'file'},
  ),
  HostCapability.hostExtensionApi: (all: {}, defaults: {}),

  // Inventory-driven capabilities (AC10): on/off only, no transport
  // dimension pinned yet — slice 2+ adds transports when a host raises
  // them with a different store.
  HostCapability.webSearch: (all: {}, defaults: {}),
  HostCapability.visionTranscribe: (all: {}, defaults: {}),
  HostCapability.subagents: (all: {}, defaults: {}),
  HostCapability.browserBridge: (all: {}, defaults: {}),
  HostCapability.jsExtensions: (all: {}, defaults: {}),
};

/// One capability's declared state on a profile.
sealed class CapabilityState {
  const CapabilityState();

  /// Wired with the SDK default transports.
  static const CapabilityOnState on = CapabilityOnState();

  /// Not wired; [reason] surfaces in UI and prompts (never silent).
  static CapabilityOffState off(String reason) => CapabilityOffState(reason);

  /// Wired, narrowed to [transports]; [reason] says why the default
  /// transport set differs (the matrix's 🔀 cells).
  static CapabilityTransportState transport(
    Set<String> transports,
    String reason,
  ) => CapabilityTransportState(transports, reason);

  /// Non-empty reason for `off`/`transport` states; null for `on`.
  String? get reason => switch (this) {
    CapabilityOnState() => null,
    CapabilityOffState(:final reason) => reason,
    CapabilityTransportState(:final reason) => reason,
  };

  @override
  String toString() => switch (this) {
    CapabilityOnState() => 'on',
    CapabilityOffState(:final reason) => 'off("$reason")',
    CapabilityTransportState(:final transports, :final reason) =>
      'transport(${transports.toList()..sort()}, "$reason")',
  };
}

/// `on`: the capability is wired with the SDK's default transports.
final class CapabilityOnState extends CapabilityState {
  const CapabilityOnState();
}

/// `off(reason)`: the capability is not wired on this platform.
final class CapabilityOffState extends CapabilityState {
  /// Why it is off — rendered wherever the capability would have surfaced.
  @override
  final String reason;

  const CapabilityOffState(this.reason);
}

/// `transport(choice, reason)`: wired, narrowed to [transports].
final class CapabilityTransportState extends CapabilityState {
  /// The transports/stores this profile wires (subset of the capability's
  /// [hostCapabilityTransports] `all` vocabulary).
  final Set<String> transports;

  /// Why the default transport set is narrowed on this platform.
  @override
  final String reason;

  const CapabilityTransportState(this.transports, this.reason);
}

/// A platform's capability ceiling: the most a profile may declare.
///
/// Floors make the narrowing invariant enforceable — a profile state is
/// checked against its floor at construction, so force-enabling a floored
/// capability throws [HostProfileViolation] instead of wiring something the
/// platform cannot deliver.
sealed class CapabilityFloor {
  const CapabilityFloor();

  /// Derives the default floor for a state when no explicit floor is given:
  /// the state's own envelope (the profile is its own ceiling).
  static CapabilityFloor fromState(CapabilityState state) => switch (state) {
    CapabilityOnState() => const FloorOn(),
    CapabilityOffState(:final reason) => FloorOff(reason),
    CapabilityTransportState(:final transports) => FloorTransports(transports),
  };
}

/// Everything is allowed on this platform.
final class FloorOn extends CapabilityFloor {
  const FloorOn();
}

/// Only [transports] exist on this platform: `off` always allowed,
/// `transport(T)` allowed iff `T ⊆ transports`, `on` allowed iff the
/// capability's default transports are all inside the floor.
final class FloorTransports extends CapabilityFloor {
  final Set<String> transports;

  const FloorTransports(this.transports);
}

/// The platform lacks the capability entirely: only `off` is declarable.
final class FloorOff extends CapabilityFloor {
  final String reason;

  const FloorOff(this.reason);
}

/// Thrown when a profile construction violates the matrix contract:
/// an undeclared capability, an empty/blank reason, an unknown transport,
/// or a state that force-enables beyond its platform floor (AC4).
class HostProfileViolation extends ConfigException {
  const HostProfileViolation(super.message);
}

/// A validated capability × state record for one host platform.
///
/// Construct via [HostCapabilityProfile.new] (full validation, custom hosts)
/// or [narrowed] (derive a variant from a built-in). Every [HostCapability]
/// MUST have a state (E2: no silent capability), and every state MUST fit
/// the platform floor — violations throw [HostProfileViolation] at
/// construction, naming the capability, the state and the floor.
final class HostCapabilityProfile {
  final String name;

  /// State per capability — complete over [HostCapability.values].
  final Map<HostCapability, CapabilityState> states;

  /// Platform ceiling per capability — complete; floors absent from the
  /// constructor call derive from the state itself (a profile is its own
  /// ceiling unless the platform says otherwise).
  final Map<HostCapability, CapabilityFloor> floors;

  HostCapabilityProfile._(this.name, this.states, this.floors);

  /// Builds and validates a profile.
  ///
  /// [states] must declare EVERY [HostCapability]; [floors] may be partial —
  /// missing floors derive from the corresponding state.
  factory HostCapabilityProfile({
    required String name,
    required Map<HostCapability, CapabilityState> states,
    Map<HostCapability, CapabilityFloor> floors = const {},
  }) {
    _requireComplete(name, states);
    final resolvedFloors = {
      for (final c in HostCapability.values)
        c: floors[c] ?? CapabilityFloor.fromState(states[c]!),
    };
    _validate(name: name, states: states, floors: resolvedFloors);
    return HostCapabilityProfile._(
      name,
      Map.unmodifiable(states),
      Map.unmodifiable(resolvedFloors),
    );
  }

  /// Derives a variant with [overrides] applied on top of this profile.
  ///
  /// The floor table stays FIXED (it is the platform's ceiling, not this
  /// profile's): an override that force-enables beyond the floor throws
  /// [HostProfileViolation] — AC4's loud failure at construction.
  HostCapabilityProfile narrowed(
    Map<HostCapability, CapabilityState> overrides, {
    String? name,
  }) {
    final label = name ?? '${this.name}.narrowed';
    final merged = Map.of(states)..addAll(overrides);
    _validate(name: label, states: merged, floors: floors);
    return HostCapabilityProfile._(label, Map.unmodifiable(merged), floors);
  }

  /// The declared state for [capability] (present for every capability by
  /// construction).
  CapabilityState stateFor(HostCapability capability) => states[capability]!;

  /// Whether the capability is wired in any form (`on` or transport).
  bool isWired(HostCapability capability) => switch (states[capability]!) {
    CapabilityOnState() => true,
    CapabilityTransportState() => true,
    CapabilityOffState() => false,
  };

  /// Validates a complete state table against a complete floor table.
  static void _validate({
    required String name,
    required Map<HostCapability, CapabilityState> states,
    required Map<HostCapability, CapabilityFloor> floors,
  }) {
    for (final capability in HostCapability.values) {
      final state = states[capability]!;
      final floor = floors[capability]!;
      _validateState(name, capability, state, floor);
    }
  }

  /// E2 guard: every capability needs a transport-vocabulary entry — a new
  /// enum value without one dies as a named violation, not a null crash.
  static CapabilityTransports _vocabularyOf(HostCapability capability) {
    final vocabulary = hostCapabilityTransports[capability];
    if (vocabulary == null) {
      throw HostProfileViolation(
        'Capability ${capability.id} has no hostCapabilityTransports entry — '
        'declare its vocabulary (empty record for on/off-only) when adding '
        'the enum value.',
      );
    }
    return vocabulary;
  }

  /// `on` under [FloorTransports]: legal only when every default transport
  /// is inside the floor.
  static String? _onVsFloorTransports(
    HostCapability capability,
    FloorTransports floor,
  ) {
    final defaults = _vocabularyOf(capability).defaults;
    return defaults.difference(floor.transports).isEmpty
        ? null
        : '"on" needs every default transport '
              '(${defaults.toList()..sort()}) but the floor allows only '
              '${floor.transports.toList()..sort()}';
  }

  /// E2 guard: every capability in the matrix needs an explicit state.
  static void _requireComplete(
    String name,
    Map<HostCapability, CapabilityState> states,
  ) {
    final missing = HostCapability.values.where((c) => !states.containsKey(c));
    if (missing.isNotEmpty) {
      throw HostProfileViolation(
        'Profile "$name" does not declare: '
        '${missing.map((c) => c.id).join(', ')}. Every capability in the '
        'matrix needs an explicit state (E2: silence is not a declaration).',
      );
    }
  }

  static void _validateState(
    String name,
    HostCapability capability,
    CapabilityState state,
    CapabilityFloor floor,
  ) {
    // Reasons are the user-visible "why not / why different" — AC3 requires
    // them on every off/transport cell.
    final reason = state.reason;
    if (reason != null && reason.trim().isEmpty) {
      throw HostProfileViolation(
        'Profile "$name", capability ${capability.id}: off/transport states '
        'need a non-empty reason.',
      );
    }
    // E2 guard: a new enum value without a vocabulary entry dies here, as a
    // named violation — never as a raw null-check crash downstream.
    final vocabulary = _vocabularyOf(capability);
    if (state is CapabilityTransportState) {
      final unknown = state.transports.difference(vocabulary.all);
      if (state.transports.isEmpty || unknown.isNotEmpty) {
        throw HostProfileViolation(
          'Profile "$name", capability ${capability.id}: unknown transports '
          '${unknown.isEmpty ? state.transports : unknown} — valid: '
          '${vocabulary.all.toList()..sort()}.',
        );
      }
    }
    final violation = switch (floor) {
      FloorOn() => null,
      FloorOff() => switch (state) {
        CapabilityOffState() => null,
        _ =>
          'platform floor is off (${floor.reason}); a profile can narrow, '
              'never force-enable',
      },
      FloorTransports() => switch (state) {
        CapabilityOffState() => null,
        CapabilityTransportState(:final transports) =>
          transports.difference(floor.transports).isEmpty
              ? null
              : 'floor allows only ${floor.transports.toList()..sort()}',
        CapabilityOnState() => _onVsFloorTransports(capability, floor),
      },
    };
    if (violation != null) {
      throw HostProfileViolation(
        'Profile "$name" cannot declare ${capability.id} = $state: '
        '$violation.',
      );
    }
  }
}
