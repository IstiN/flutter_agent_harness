// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Owns the capability-gated tool availability wiring for one agent
/// (issue #19): the shared [toolAvailabilityIdOf] name→id resolution, the
/// capability floor
/// derived from the actual wiring, the [ToolAvailabilityGate] over the
/// initial tool set, and the apply/re-apply cycle — the tool list and
/// prompt update without a restart.
///
/// Persistence (the [ToolsAvailabilityStore] write) and change
/// notification stay with the owning [AgentService]; this class only
/// mutates its [config] and re-applies it.
class AgentToolAvailability {
  /// Builds the gate from the INITIAL tool set (the full wiring, before
  /// anything is hidden): tools grouped by id via [toolAvailabilityIdOf] — the
  /// gate's originals — plus the capability floor, then applies
  /// [initialConfig]. Idempotent thereafter.
  ///
  /// [registry] is `null` for services built around a pre-constructed
  /// [Agent] (tests): availability still resolves, but the registry is not
  /// re-synced on toggle (the caller owns it).
  AgentToolAvailability({
    required Agent agent,
    required Iterable<Tool> tools,
    required bool onDevice,
    required this.registry,
    required this.rebuildPrompt,
    ToolsConfig initialConfig = const ToolsConfig(),
  }) : _agent = agent,
       _config = initialConfig {
    final agentTools = tools.whereType<AgentTool>().toList();
    _capabilities = _capabilitiesFor(agentTools, onDevice: onDevice);
    final toolsById = <String, List<AgentTool>>{};
    for (final tool in agentTools) {
      final id = toolAvailabilityIdOf(tool.name);
      if (id != null) toolsById.putIfAbsent(id, () => []).add(tool);
    }
    _gate = ToolAvailabilityGate(toolsById: toolsById);
    // Tombstones calls to disabled tools even when the model names one.
    agent.toolExecutor = _gate.wrapExecutor(agent.toolExecutor);
    _apply();
  }

  /// The live registry the resolution re-applies to; `null` on the
  /// pre-constructed-[Agent] path (tests).
  final ToolRegistry? registry;

  /// Refreshes the provider-facing prompt after a re-apply.
  final void Function() rebuildPrompt;

  final Agent _agent;
  ToolsConfig _config;
  late final ToolAvailabilityGate _gate;
  Map<String, ToolCapability> _capabilities = const {};

  /// The user's per-tool availability choices (the app twin of the CLI
  /// `tools:` section; persisted via `ToolsAvailabilityStore`).
  ToolsConfig get config => _config;

  /// The availability decision per known tool id (capabilities + config).
  Map<String, ResolvedToolAvailability> get availability => _resolve().byId;

  /// Switches one tool's availability and re-applies the resolution to the
  /// live registry. Returns `false` when the resolved intent already
  /// matches [enabled] (no-op). An absent capability stays off (the hard
  /// floor); persistence is the caller's job.
  bool setEnabled(String id, bool enabled) {
    if ((_config.tools[id] ?? true) == enabled) return false;
    _config = ToolsConfig(tools: {..._config.tools, id: enabled});
    _apply();
    return true;
  }

  /// The resolved availability decision for the current config + wiring.
  ToolAvailabilityResolution _resolve() => resolveToolAvailability(
    capabilities: _capabilities,
    scopes: [(ToolScope.runtime, _config)],
  );

  /// Re-applies the availability resolution to the live registry and
  /// recomposes the prompt. No-op without a registry.
  void _apply() {
    final registry = this.registry;
    if (registry == null) return;
    _gate.apply(_resolve(), registry, _agent, rebuildPrompt: rebuildPrompt);
  }
}

/// Why the app cannot wire [id] — structural facts about this host.
String _absentToolReason(String id, {required bool onDevice}) => switch (id) {
  'web_search' ||
  'transcribe_audio' ||
  'generate_image' ||
  'generate_video' when onDevice => 'not available on-device',
  'sqlite' =>
    'requires the FFI SQLite engine — not available in the app sandbox',
  'lsp' => 'language-server process transport is CLI-only',
  'mcp' => 'MCP servers connect through the CLI harness',
  'dap' => 'DAP hub transport is CLI-only',
  'checkpoint' || 'rewind' => 'checkpointing is CLI-only',
  _ => 'not wired by this host',
};

/// Builds the capability floor for every known id from the ACTUAL tool
/// wiring: an id is present iff at least one of its tools was registered.
Map<String, ToolCapability> _capabilitiesFor(
  Iterable<AgentTool> tools, {
  required bool onDevice,
}) {
  final wired = <String>{
    for (final tool in tools) ?toolAvailabilityIdOf(tool.name),
  };
  return {
    for (final id in knownToolIds)
      id: wired.contains(id)
          ? const ToolCapability.available()
          : ToolCapability.absent(_absentToolReason(id, onDevice: onDevice)),
  };
}
