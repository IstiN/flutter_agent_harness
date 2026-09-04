/// The gate that applies a [ToolAvailabilityResolution] to a live agent:
/// hiding/restoring tools in the [ToolRegistry], syncing the agent state,
/// and tombstoning execution of disabled tools.
///
/// Sits between the pure decision layer (`availability.dart`) and the
/// running agent loop: the wiring slices resolve availability from config
/// + host capabilities, then [ToolAvailabilityGate.apply] enforces it —
/// and can re-apply a new resolution at any time (idempotent, so config
/// changes re-apply cleanly).
///
/// Dynamic tool families (MCP servers) that register tools after startup
/// report their concrete tool names via [ToolAvailabilityGate.noteHiddenNames];
/// the gate then tombstones and unregisters them exactly like its static
/// tools.
///
/// Pure Dart: no `dart:io`.
library;

import '../agent/agent.dart';
import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../agent/tool_registry.dart';
import 'availability.dart';

/// Enforces a [ToolAvailabilityResolution] against a registry + agent.
///
/// The gate is constructed with the ORIGINAL full tool set grouped by
/// availability id (`'web_search' → [webSearchTool, webFetchTool]`), from
/// which it builds the name→id map used for hiding and tombstoning.
final class ToolAvailabilityGate {
  /// Prefix of dynamic MCP family ids (`mcp:<server>`).
  static const _mcpFamilyPrefix = 'mcp:';

  final Map<String, List<AgentTool>> _toolsById;
  final _namesById = <String, Set<String>>{};
  final _idByName = <String, String>{};
  ToolAvailabilityResolution? _resolution;

  /// Creates a gate over the full tool set grouped by availability id.
  ToolAvailabilityGate({required Map<String, List<AgentTool>> toolsById})
    : _toolsById = toolsById {
    for (final MapEntry(key: id, value: tools) in toolsById.entries) {
      for (final tool in tools) {
        _namesById.putIfAbsent(id, () => <String>{}).add(tool.name);
        _idByName[tool.name] = id;
      }
    }
  }

  /// The last resolution passed to [apply]; `null` before the first apply.
  ToolAvailabilityResolution? get resolution => _resolution;

  /// Names of all currently disabled tools: the static tools of disabled
  /// ids plus dynamically noted ([noteHiddenNames]) names of disabled
  /// families. Empty before the first apply.
  List<String> get hiddenToolNames {
    final resolution = _resolution;
    if (resolution == null) return const [];
    return [
      for (final MapEntry(key: id, value: names) in _namesById.entries)
        if (!_enabled(resolution, id)) ...names,
    ]..sort();
  }

  /// Whether [id] is enabled under [resolution]: the per-id decision when
  /// the resolution has one (`byId` covers only [knownToolIds]), else the
  /// per-server MCP map for `mcp:<server>` families (absent → true).
  bool _enabled(ToolAvailabilityResolution resolution, String id) {
    final resolved = resolution.byId[id];
    if (resolved != null) return resolved.enabled;
    if (id.startsWith(_mcpFamilyPrefix)) {
      final server = id.substring(_mcpFamilyPrefix.length);
      final declared = resolution.mcpServers[server];
      if (declared != null) return declared;
      // Server never declared in any scope: the aggregate mcp decision
      // governs (a mcp:false kill-switch kills undeclared servers too).
      return resolution.byId['mcp']?.enabled ?? true;
    }
    return true;
  }

  /// Records the concrete tool [names] of a dynamic family [id] (an MCP
  /// server that registered late), so hiding and executor tombstoning
  /// cover them like static tools.
  void noteHiddenNames(String id, List<String> names) {
    final family = _namesById.putIfAbsent(id, () => <String>{});
    for (final name in names) {
      family.add(name);
      _idByName[name] = id;
    }
  }

  /// Applies [resolution] to [registry] and [agent]:
  ///
  /// - enabled ids get their not-yet-registered tools registered (the
  ///   contains-check first — [ToolRegistry.register] throws on
  ///   duplicates);
  /// - disabled ids get every known name unregistered;
  /// - then `agent.state.tools` syncs to the registry and
  ///   [rebuildPrompt] refreshes the provider-facing prompt.
  ///
  /// Idempotent: re-applying the same resolution (or a corrected one) is
  /// always safe.
  void apply(
    ToolAvailabilityResolution resolution,
    ToolRegistry registry,
    Agent agent, {
    required void Function() rebuildPrompt,
  }) {
    _resolution = resolution;
    for (final MapEntry(key: id, value: names) in _namesById.entries) {
      if (_enabled(resolution, id)) {
        for (final tool in _toolsById[id] ?? const <AgentTool>[]) {
          if (!registry.contains(tool.name)) registry.register(tool);
        }
      } else {
        for (final name in names) {
          registry.unregister(name);
        }
      }
    }
    agent.state.tools = registry.tools;
    rebuildPrompt();
  }

  /// Wraps [inner] so calls to tools that are disabled in the current
  /// resolution return a plain (non-throwing) tombstone result telling
  /// the model the tool is off; everything else delegates to [inner].
  ToolExecutor wrapExecutor(ToolExecutor inner) {
    return (toolCall, cancelToken, onUpdate) async {
      final resolution = _resolution;
      final id = _idByName[toolCall.name];
      if (id != null && resolution != null && !_enabled(resolution, id)) {
        return ToolExecutionResult.text(
          'Tool `${toolCall.name}` is disabled '
          '(`${_disabledReason(resolution, id)}`) — ask the user to enable '
          'it via /tools or settings.',
        );
      }
      return inner(toolCall, cancelToken, onUpdate);
    };
  }

  /// Machine-readable why-disabled for the tombstone: the per-id reason
  /// when the resolution has one, else the aggregate `mcp` reason (the
  /// kill-switch), else a config-disabled fallback for per-server
  /// disables.
  String _disabledReason(ToolAvailabilityResolution resolution, String id) {
    return resolution.byId[id]?.reason ??
        resolution.byId['mcp']?.reason ??
        'disabled by config';
  }
}
