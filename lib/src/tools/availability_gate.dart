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

  /// Discoverable ids (issue #680) mounted this session by the
  /// `discover_tools` meta tool. Session-scoped by design (no GC —
  /// the card's non-goal); re-applying a resolution never clears it.
  final _mounted = <String>{};
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

  /// Whether the `discover_tools` discovery surface is live for the
  /// current boot ([discoveryEnabledByLoadMode]: omp only — pi keeps
  /// pi-mono's exact benchmark shape with discovery off, issue #679).
  /// The wiring sets it with the load mode (so a mid-session /settings
  /// switch updates it): the discoverable tombstone may point at
  /// `discover_tools` only while the tool is actually registered —
  /// otherwise it points at the load-mode switch instead of dead-ending
  /// on a tool the mode never shipped (issue #680 review).
  bool discoveryEnabled = false;

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

  /// Whether [id] is schema-visible under [resolution] given the
  /// session's mounts: enabled, and — when the resolution marks it
  /// discoverable (load mode, issue #680) — mounted.
  bool _visible(ToolAvailabilityResolution resolution, String id) =>
      _enabled(resolution, id) &&
      !(resolution.discoverableIds.contains(id) && !_mounted.contains(id));

  /// Names of the tools currently discoverable-and-unmounted, sorted:
  /// the `discover_tools` listing source (issue #680).
  List<String> get discoverableToolNames {
    final resolution = _resolution;
    if (resolution == null) return const [];
    return [
      for (final id in resolution.discoverableIds)
        if (!_mounted.contains(id)) ...?_namesById[id],
    ]..sort();
  }

  /// One-line doc per discoverable-and-unmounted tool name, from the
  /// original tool instances' description first line (issue #680).
  Map<String, String> discoverableDocs() {
    final resolution = _resolution;
    if (resolution == null) return const {};
    final docs = <String, String>{};
    for (final id in resolution.discoverableIds) {
      if (_mounted.contains(id)) continue;
      for (final tool in _toolsById[id] ?? const <AgentTool>[]) {
        final description = tool.description;
        docs[tool.name] = description.contains('\n')
            ? description.substring(0, description.indexOf('\n')).trim()
            : description.trim();
      }
    }
    return docs;
  }

  /// Mounts discoverable [ids] (unknown or already-mounted ids are
  /// ignored) and re-applies the current resolution so the tools enter
  /// the schema and the provider-facing prompt rebuilds (issue #680).
  /// Returns the ids that actually mounted.
  Set<String> mount(
    Iterable<String> ids,
    ToolRegistry registry,
    Agent agent, {
    required void Function() rebuildPrompt,
  }) {
    final resolution = _resolution;
    if (resolution == null) return const {};
    final mountedNow = <String>{};
    for (final id in ids) {
      if (resolution.discoverableIds.contains(id) && _mounted.add(id)) {
        mountedNow.add(id);
      }
    }
    if (mountedNow.isNotEmpty) {
      apply(resolution, registry, agent, rebuildPrompt: rebuildPrompt);
    }
    return mountedNow;
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

  /// Records the concrete [tools] of a dynamic family [id] (an MCP
  /// server's live surface): the names for hiding/tombstoning exactly
  /// like [noteHiddenNames], PLUS the instances — so a load-mode mount
  /// (issue #680) re-registers them into the schema from [apply] and
  /// [discoverableDocs] can document them.
  void noteFamilyTools(String id, List<AgentTool> tools) {
    noteHiddenNames(id, [for (final tool in tools) tool.name]);
    // Replace, not append: the fresh list is the server's authoritative
    // surface (names of dropped tools stay noted for tombstoning, but
    // only live instances may ever be registered).
    _toolsById[id] = [...tools];
  }

  /// The availability id of the tool [name] — static tools and noted
  /// dynamic family members (`mcp:<server>`) alike, or null when
  /// unmapped. The name→id half of what [mount] needs (issue #680): the
  /// model mounts by NAME, the gate mounts ids.
  String? availabilityIdOf(String name) => _idByName[name];

  /// Whether the dynamic family [id] (an MCP server) is schema-visible
  /// under the live resolution (issue #680): enabled, and — when the load
  /// mode demoted it to discoverable — mounted. The MCP re-filter asks
  /// this before putting a server's tools into the registry: allowed to
  /// connect is not the same as loaded into the schema.
  bool familyVisible(String id) {
    final resolution = _resolution;
    if (resolution == null) return true;
    return _visible(resolution, id);
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
      if (_visible(resolution, id)) {
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
      if (id != null &&
          resolution != null &&
          resolution.discoverableIds.contains(id) &&
          !_mounted.contains(id)) {
        // Discoverable tombstone (issue #680): names the discovery path
        // instead of the plain off-reason — the tool exists, it is just
        // not loaded in this mode. The pointer follows the live mode:
        // `discover_tools` only while that surface is registered (omp);
        // modes without it (pi, discovery off) point at the /settings
        // load-mode switch and the docs instead of a dead-end tool name.
        return ToolExecutionResult.text(
          discoveryEnabled
              ? 'Tool `${toolCall.name}` is discoverable and not loaded — '
                    'call `discover_tools` to list available tools, then '
                    'mount it by name.'
              : 'Tool `${toolCall.name}` is discoverable and not loaded '
                    'in this mode — this mode ships no `discover_tools` '
                    'surface; ask the user to switch the load mode via '
                    '/settings (agent.mode) — see docs/tool-availability.md '
                    '§Load modes.',
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
