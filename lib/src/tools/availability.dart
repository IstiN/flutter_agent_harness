/// Capability-gated tool availability: the pure decision layer for the
/// per-scope `tools:` configuration (issue #19).
///
/// Three concerns, strictly separated:
///
/// - [ToolsConfig] — one scope's `tools:` section (yaml parse/serialize,
///   JSON envelope for app-store/CLI interchange).
/// - [resolveToolAvailability] — merges the scope stack (shallow→deep:
///   global, project, session, runtime) with the host's per-tool
///   [ToolCapability]s into a [ToolAvailabilityResolution]: what is
///   enabled, where the decision came from, and why anything is off.
/// - [parseToolsSpec] — the `--tools` flag / `FA_TOOLS` env CSV twin.
///
/// Rules encoded here: a missing host capability can never be overridden
/// by config (`builtin` wins); config can only turn present tools off
/// (deeper scope wins per key); unknown ids are collected non-fatally in
/// [ToolAvailabilityResolution.unknownIds] (warnings are the caller's
/// job, not the parser's). Warnings happen at resolution, not parse.
///
/// Pure Dart: no `dart:io`. The gate that applies a resolution to a live
/// [ToolRegistry]/[Agent] lives in `availability_gate.dart`.
library;

import 'package:yaml/yaml.dart';

import '../exceptions.dart';

/// Where a tool decision can come from: the scope stack, ordered from the
/// shallowest (broadest) to the harness's platform default.
///
/// [ToolScope.builtin] is the platform's own decision — the default tool
/// wiring and the hard capability floor. Precedence in
/// [resolveToolAvailability] follows the order of the `scopes` list
/// (shallow→deep), not this enum's declaration order.
enum ToolScope { runtime, session, project, global, builtin }

/// Tool ids the harness knows about, including aggregate families
/// (`mcp`, `bash_job`) and per-host optionals (`dap`, `generate_video`).
/// The `web_search` id is itself a family: it gates BOTH the
/// `web_search` and `web_fetch` tools (no standalone `web_fetch` key).
///
/// Configuration may additionally use `mcp:<server>` keys for per-server
/// MCP granularity; those are not part of this set.
const knownToolIds = <String>{
  'read',
  'write',
  'edit',
  'ls',
  'bash',
  'bash_job',
  'lsp',
  'web_search',
  'sqlite',
  'mcp',
  'memory',
  'schedule_message',
  'ask',
  'request_secret',
  'task',
  'checkpoint',
  'rewind',
  'generate_image',
  'generate_video',
  'inspect_image',
  'transcribe_audio',
  'dap',

  /// The browser family (issue #23) plus `browser_eval` as its own id:
  /// JS evaluation can be disabled alone (the reverse index resolves a
  /// name that IS an availability id to itself, never to the family).
  'browser',
  'browser_eval',
};

/// The scope stack in resolution precedence order, shallow→deep: global,
/// project, session, runtime. Hosts building a
/// [resolveToolAvailability] `scopes:` list map over this instead of
/// hand-writing the quadruple. [ToolScope.builtin] is the implicit
/// capability floor and never a list entry.
const toolScopeStack = <ToolScope>[
  ToolScope.global,
  ToolScope.project,
  ToolScope.session,
  ToolScope.runtime,
];

/// The canonical host-agnostic availability-id → member tool-NAMES table:
/// aggregate families map several registered tool names onto one `tools:`
/// id. Singletons are single-entry sets so every consumer treats the
/// shape uniformly. Host-specific ids — `lsp`, `sqlite`, `mcp` (plus
/// `mcp:<server>`), and `dap` — stay host-wired: dynamic tool-name
/// prefixes (`dap_*`, `mcp__*`) cannot live in a static name table.
const coreToolFamilies = <String, Set<String>>{
  'read': {'read'},
  'write': {'write'},
  'edit': {'edit'},
  'ls': {'ls'},
  'bash': {'bash'},
  'bash_job': {'bash_job'},
  'web_search': {'web_search', 'web_fetch'},
  'memory': {'memory_add', 'memory_search', 'memory_list', 'memory_delete'},
  'schedule_message': {'schedule_message'},
  'ask': {'ask'},
  'request_secret': {'request_secret'},
  'task': {
    'task',
    'task_cancel',
    'task_status',
    'task_observe',
    'task_send',
    'agent_directory',
    'reply',
    'agent_message',
  },
  'checkpoint': {'checkpoint'},
  'rewind': {'rewind'},
  'generate_image': {'generate_image'},
  'generate_video': {'generate_video'},
  'transcribe_audio': {'transcribe_audio'},
  'inspect_image': {'inspect_image'},
  'browser': {
    'browser_navigate',
    'browser_tabs',
    'browser_switch_tab',
    'browser_click',
    'browser_type',
    'browser_press_key',
    'browser_select',
    'browser_read_dom',
    // Membership informational only — the reverse index resolves
    // browser_eval to its own id (below), so `tools: {browser: false}`
    // never hides eval; disable it separately.
    'browser_eval',
    'browser_screenshot',
    'browser_wait_for',
  },
  'browser_eval': {'browser_eval'},
};

/// Reverse index of [coreToolFamilies]: member tool name → availability
/// id. Lazily built once by Dart's top-level-final semantics.
final _toolIdByName = <String, String>{
  for (final MapEntry(key: id, value: names) in coreToolFamilies.entries)
    for (final name in names)
      // A name that is itself an availability id resolves to its OWN id
      // (the singleton rule; keeps browser_eval off the browser family's
      // key) — the family listing never hijacks it.
      name: name == id || coreToolFamilies.containsKey(name) ? name : id,
};

/// The availability id gating [toolName], or null when the name is
/// outside every host-agnostic family (unknown names, host-specific
/// tools, dynamic MCP tools).
String? toolAvailabilityIdOf(String toolName) => _toolIdByName[toolName];

/// Prefix of the flattened per-server MCP keys (`mcp:<server>`).
const _mcpPrefix = 'mcp:';

/// One scope's `tools:` section: tool id → user intent.
///
/// Keys are flat tool ids from [knownToolIds], plus `mcp:<server>` keys
/// for per-server MCP granularity — the raw yaml shape
/// `tools: {mcp: {my-server: false}}` normalizes to the flat key
/// `mcp:my-server` at parse time. Unknown ids are accepted here; warning
/// about them happens at resolution.
final class ToolsConfig {
  /// Tool id (or `mcp:<server>`) → user intent for that tool.
  final Map<String, bool> tools;

  /// Creates a config from an already-normalized [tools] map.
  const ToolsConfig({this.tools = const {}});

  /// Whether this scope declares no tool intent at all.
  bool get isEmpty => tools.isEmpty;

  /// Merges this (deeper) config over [shallower]: the receiver wins per
  /// key; keys the receiver does not mention fall back to [shallower].
  ToolsConfig mergedOver(ToolsConfig shallower) =>
      ToolsConfig(tools: {...shallower.tools, ...tools});

  /// Parses one scope's `tools:` yaml node.
  ///
  /// `null` yields an empty config. Strict: a non-map node or a
  /// non-boolean value throws [ConfigException] — fallback policy (skip
  /// the section, warn, abort) belongs to the caller. A nested `mcp:` map
  /// flattens to `mcp:<server>` keys; a plain boolean `mcp:` value stays
  /// the aggregate `mcp` id.
  static ToolsConfig fromYaml(Object? node) {
    if (node == null) return const ToolsConfig();
    if (node is! YamlMap) {
      throw ConfigException('tools must be a map, got: ${node.runtimeType}');
    }
    return ToolsConfig(tools: _parseToolsEntries(node));
  }

  /// Serializes a `tools:` block: flat keys sorted, `mcp:<server>` keys
  /// rendered as a nested `mcp:` map. An empty config serializes to `''`.
  String toYaml() {
    if (isEmpty) return '';
    final buffer = StringBuffer('tools:');
    for (final key in _flatKeys.toList()..sort()) {
      buffer.write('\n  $key: ${tools[key]}');
    }
    final servers =
        tools.keys
            .where((key) => key.startsWith(_mcpPrefix))
            .map((key) => key.substring(_mcpPrefix.length))
            .toList()
          ..sort();
    if (servers.isNotEmpty) {
      buffer.write('\n  mcp:');
      for (final server in servers) {
        buffer.write('\n    $server: ${tools['$_mcpPrefix$server']}');
      }
    }
    return buffer.toString();
  }

  /// Keys that are neither aggregate-`mcp` nor `mcp:<server>`.
  Iterable<String> get _flatKeys =>
      tools.keys.where((key) => !key.startsWith(_mcpPrefix));

  /// JSON envelope for the app store + CLI/app interchange:
  /// `{"tools": {"<id>": bool}}`. Corrupt input throws [ConfigException];
  /// the caller decides the fallback.
  Map<String, dynamic> toJson() => {'tools': Map<String, dynamic>.of(tools)};

  /// Restores a config from [toJson]'s envelope. Strict like [fromYaml].
  static ToolsConfig fromJson(Object? json) {
    if (json == null) return const ToolsConfig();
    if (json is! Map) {
      throw ConfigException(
        'tools envelope must be a map, got: ${json.runtimeType}',
      );
    }
    final toolsNode = json['tools'];
    if (toolsNode == null) return const ToolsConfig();
    if (toolsNode is! Map) {
      throw ConfigException(
        '"tools" must be a map, got: ${toolsNode.runtimeType}',
      );
    }
    return ToolsConfig(tools: _parseToolsEntries(toolsNode));
  }
}

/// Shared entry parser for the yaml node and the JSON envelope (both are
/// plain `Map`s once the outer type gate has passed): flattens the nested
/// `mcp:` map and enforces boolean values.
Map<String, bool> _parseToolsEntries(Map<Object?, Object?> node) {
  final tools = <String, bool>{};
  for (final entry in node.entries) {
    final key = entry.key;
    if (key is! String) {
      throw ConfigException(
        '"tools" keys must be strings, got: ${key.runtimeType}',
      );
    }
    final value = entry.value;
    if (key == 'mcp' && value is Map) {
      for (final serverEntry in value.entries) {
        final server = serverEntry.key;
        if (server is! String) {
          throw ConfigException(
            '"tools.mcp" keys must be strings, got: ${server.runtimeType}',
          );
        }
        if (serverEntry.value is! bool) {
          throw ConfigException('"tools.mcp.$server" must be a boolean');
        }
        tools['$_mcpPrefix$server'] = serverEntry.value as bool;
      }
      continue;
    }
    if (value is! bool) {
      throw ConfigException('"tools.$key" must be a boolean');
    }
    tools[key] = value;
  }
  return tools;
}

/// A tool family's host-side capability: whether the current platform/wiring
/// can actually provide the tool at all.
///
/// Capability is the hard floor: absent tools stay disabled no matter what
/// configuration asks for.
final class ToolCapability {
  /// Whether the host can provide this tool.
  final bool present;

  /// Machine-readable why-not, when [present] is false.
  final String? absentReason;

  /// The host wires this tool up.
  const ToolCapability.available() : present = true, absentReason = null;

  /// The host cannot provide this tool; [reason] explains why.
  const ToolCapability.absent(String reason)
    : present = false,
      absentReason = reason;
}

/// The availability decision for one tool id.
final class ResolvedToolAvailability {
  /// Whether the tool should be registered and offered to the model.
  final bool enabled;

  /// Where the winning decision came from: [ToolScope.builtin] when the
  /// capability decided (or nothing did), otherwise the scope of the
  /// winning config intent.
  final ToolScope scope;

  /// Machine-readable why-disabled: the capability's absent reason, or
  /// `disabled by <scope name>`. `null` when enabled.
  final String? reason;

  /// Whether the host can provide the tool at all.
  final bool capabilityPresent;

  /// Creates a decision.
  const ResolvedToolAvailability({
    required this.enabled,
    required this.scope,
    required this.capabilityPresent,
    this.reason,
  });
}

/// The full resolution of every known tool id against a scope stack.
final class ToolAvailabilityResolution {
  /// Decision per known id — covers every id in [knownToolIds], including
  /// ids the host does not wire (those are absent `not wired by this host`).
  final Map<String, ResolvedToolAvailability> byId;

  /// Config ids outside [knownToolIds] (non-fatal; the caller warns).
  final Set<String> unknownIds;

  /// Per-server MCP availability (keyed without the `mcp:` prefix): the
  /// union of `mcp:<server>` keys across scopes, deepest wins. Servers
  /// absent from every scope default to `true` at the consumer; a merged
  /// `mcp: false` kill-switch forces every declared value to `false`.
  final Map<String, bool> mcpServers;

  /// Creates a resolution.
  const ToolAvailabilityResolution({
    required this.byId,
    this.unknownIds = const {},
    this.mcpServers = const {},
  });
}

/// Resolves the scope stack against the host's capabilities.
///
/// [scopes] lists `(scope, config)` pairs shallow→deep (global, project,
/// session, runtime); the deepest scope mentioning a key wins. Capability
/// absence is the hard floor: such ids stay disabled at [ToolScope.builtin]
/// even when a scope force-enables them. Present capabilities are on by
/// default and only config can turn them off. Unknown ids are collected in
/// [ToolAvailabilityResolution.unknownIds] without failing.
ToolAvailabilityResolution resolveToolAvailability({
  required Map<String, ToolCapability> capabilities,
  required List<(ToolScope, ToolsConfig)> scopes,
}) {
  final (:intent, :intentScope, :unknownIds, :mcpServers) = _collectToolIntents(
    scopes,
  );

  final byId = <String, ResolvedToolAvailability>{
    for (final id in knownToolIds)
      id: _resolveKnownTool(id, capabilities[id], intent, intentScope),
  };

  if (intent['mcp'] == false) {
    for (final server in mcpServers.keys.toList()) {
      mcpServers[server] = false;
    }
  }
  return ToolAvailabilityResolution(
    byId: byId,
    unknownIds: unknownIds,
    mcpServers: mcpServers,
  );
}

/// The collected scope intents: per-tool on/off wishes with the deepest
/// scope that declared them, unknown ids, and MCP server overrides.
typedef _ToolIntents = ({
  Map<String, bool> intent,
  Map<String, ToolScope> intentScope,
  Set<String> unknownIds,
  Map<String, bool> mcpServers,
});

/// Flattens the scope stack (shallow→deep; the deepest mention wins) into
/// per-tool intents, separating MCP server overrides and unknown ids.
_ToolIntents _collectToolIntents(List<(ToolScope, ToolsConfig)> scopes) {
  final intent = <String, bool>{};
  final intentScope = <String, ToolScope>{};
  final unknownIds = <String>{};
  final mcpServers = <String, bool>{};
  for (final (scope, config) in scopes) {
    for (final MapEntry(key: id, value: enabled) in config.tools.entries) {
      if (id.startsWith(_mcpPrefix)) {
        mcpServers[id.substring(_mcpPrefix.length)] = enabled;
      } else if (knownToolIds.contains(id)) {
        intent[id] = enabled;
        intentScope[id] = scope;
      } else {
        unknownIds.add(id);
      }
    }
  }
  return (
    intent: intent,
    intentScope: intentScope,
    unknownIds: unknownIds,
    mcpServers: mcpServers,
  );
}

/// Resolves one known tool id: capability absence is the hard floor,
/// present capabilities default on and only a declared scope turns them
/// off.
ResolvedToolAvailability _resolveKnownTool(
  String id,
  ToolCapability? capability,
  Map<String, bool> intent,
  Map<String, ToolScope> intentScope,
) {
  if (capability == null || !capability.present) {
    return ResolvedToolAvailability(
      enabled: false,
      scope: ToolScope.builtin,
      capabilityPresent: false,
      reason: capability?.absentReason ?? 'not wired by this host',
    );
  }
  final declared = intent.containsKey(id);
  final enabled = !declared || intent[id]!;
  return ResolvedToolAvailability(
    enabled: enabled,
    scope: declared ? intentScope[id]! : ToolScope.builtin,
    capabilityPresent: true,
    reason: enabled ? null : 'disabled by ${intentScope[id]!.name}',
  );
}

/// Parses the `--tools` flag / `FA_TOOLS` env CSV spec:
/// `'web_search=off,dap=off,mcp:my-server=on'`.
///
/// Values accept `on`/`off`/`true`/`false`, case-insensitively; tokens are
/// trimmed. An empty string yields an empty config. A malformed token
/// throws [ConfigException] naming it.
ToolsConfig parseToolsSpec(String csv) {
  final trimmed = csv.trim();
  if (trimmed.isEmpty) return const ToolsConfig();
  final tools = <String, bool>{};
  for (final raw in trimmed.split(',')) {
    final token = raw.trim();
    if (token.isEmpty) continue;
    final separator = token.indexOf('=');
    final id = separator < 0 ? '' : token.substring(0, separator).trim();
    final value = separator < 0
        ? ''
        : token.substring(separator + 1).trim().toLowerCase();
    final enabled = switch (value) {
      'on' || 'true' => true,
      'off' || 'false' => false,
      _ => null,
    };
    if (id.isEmpty || enabled == null) {
      throw ConfigException('invalid tools spec token: "$token"');
    }
    tools[id] = enabled;
  }
  return ToolsConfig(tools: tools);
}
