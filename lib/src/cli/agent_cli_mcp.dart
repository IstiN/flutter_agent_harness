/// MCP wiring for [AgentCli]: the manager lifecycle, tool re-registration,
/// and the prompt section composition — extracted from `agent_cli.dart` to
/// keep it under the 2800-line gate.
part of 'agent_cli.dart';

/// Owns the MCP connection pool (null when no `mcp:` config was provided),
/// the names of the currently registered MCP tools, and the re-registration
/// flow (mirrors the checkpoint-tools registration pattern: registry first,
/// then the agent's tool list).
final class AgentCliMcpWiring {
  /// Creates the pool from the tool config; [cwd] is the sandbox working
  /// directory stdio servers spawn into.
  AgentCliMcpWiring({required McpToolConfig? config, required String cwd})
    : manager = config == null
          ? null
          : McpManager(
              config: config.config,
              cwd: cwd,
              transportFactory: config.transportFactory,
              httpClient: config.httpClient,
            );

  /// The connection pool (null when no `mcp:` config was provided).
  final McpManager? manager;

  /// Names of the currently registered MCP tools (for re-registration).
  final Set<String> toolNames = {};

  /// Re-registers the MCP tool surface into [registry] (and the agent's tool
  /// list), then [rebuildPrompt] — call whenever a server connects, fails,
  /// or drops (the manager's `onChanged` hook).
  void reRegister(
    ToolRegistry registry,
    Agent agent,
    void Function() rebuildPrompt,
  ) {
    for (final name in toolNames) {
      registry.unregister(name);
    }
    toolNames.clear();
    final tools = manager?.tools ?? const <AgentTool>[];
    registry.registerAll(tools);
    toolNames.addAll(tools.map((tool) => tool.name));
    agent.state.tools = registry.tools;
    rebuildPrompt();
  }

  /// Which configured servers the availability gate allows into the prompt
  /// section (null: every server). Set on every tools-availability rebuild.
  bool Function(String server)? serverFilter;

  /// The `## MCP servers` prompt section ('' without servers).
  String promptSection() =>
      manager?.promptSection(includeServer: serverFilter) ?? '';

  /// The full system prompt: [base] plus any non-empty optional sections.
  String composePrompt(
    String base, {
    required String contextSection,
    required String skillsSection,
    String memorySection = '',
    String messagingSection = '',
  }) {
    final mcpSection = promptSection();
    return [
      base,
      if (contextSection.isNotEmpty) contextSection,
      if (skillsSection.isNotEmpty) skillsSection,
      if (memorySection.isNotEmpty) memorySection,
      if (messagingSection.isNotEmpty) messagingSection,
      if (mcpSection.isNotEmpty) mcpSection,
    ].join('\n\n');
  }
}

/// `/mcp reload`: re-reads the `mcp:` config section and, when the servers
/// changed, swaps in a fresh [AgentCliMcpWiring] on [cli]. Lives in this part
/// file (rather than `agent_cli.dart`) to keep the host under the 2800-line
/// gate. The config is read through the (pure-Dart, web-safe) [ExecutionEnv]
/// rather than `loadCliConfig` (which is `dart:io`-bound) so this compiles
/// for web too.
Future<void> _reloadMcpConfig(AgentCli cli) async {
  final home = cli.config.homeDir;
  if (home == null) {
    cli.io.writeln('Cannot reload MCP config: homeDir not set');
    return;
  }
  final newMcp = await _readMcpConfigFromFile(cli, '$home/.fah/config.yaml');
  final oldWiring = cli._mcp;
  if (newMcp == null && oldWiring.manager == null) {
    cli.io.writeln('No MCP section in config — nothing to reload');
    return;
  }
  if (_mcpConfigUnchanged(newMcp, oldWiring.manager)) {
    cli.io.writeln('MCP config unchanged');
    return;
  }
  await _swapMcpWiring(cli, oldWiring, newMcp);
}

/// Whether the freshly read [newMcp] matches the live manager's config.
/// Compares the serialized sections so ANY server change (url, args, env,
/// tool timeout) counts as a change — not just a shape change.
bool _mcpConfigUnchanged(McpConfig? newMcp, McpManager? oldManager) =>
    oldManager != null &&
    newMcp != null &&
    newMcp.toYaml() == oldManager.config.toYaml();

/// The change branch of [_reloadMcpConfig]: disposes the old manager, swaps
/// in a fresh wiring for [newMcp], and re-registers the tool surface.
Future<void> _swapMcpWiring(
  AgentCli cli,
  AgentCliMcpWiring oldWiring,
  McpConfig? newMcp,
) async {
  await oldWiring.manager?.dispose();
  final wiring = _reloadedMcpWiring(cli, newMcp);
  cli._mcp = wiring;
  // The fresh wiring starts with no registered names, so drop the previous
  // MCP tool surface before registering the (re)loaded manager's tools.
  for (final name in oldWiring.toolNames) {
    cli._toolRegistry.unregister(name);
  }
  wiring.reRegister(cli._toolRegistry, cli._agent, cli._applyPromptComposition);
  cli.io.writeln(
    'MCP config reloaded: ${newMcp?.servers.length ?? 0} server(s)'
    '${wiring.manager != null ? ' (connecting)' : ''}',
  );
}

/// Builds the replacement wiring for [newMcp]. Transport plumbing comes from
/// the config's existing McpToolConfig (the IO/native transport factory is
/// only reachable from lib/io.dart).
AgentCliMcpWiring _reloadedMcpWiring(AgentCli cli, McpConfig? newMcp) {
  final transport = cli.config.mcpConfig;
  return AgentCliMcpWiring(
    config: newMcp == null
        ? null
        : McpToolConfig(
            config: newMcp,
            transportFactory: transport?.transportFactory,
            httpClient: transport?.httpClient,
          ),
    cwd: cli.config.env.cwd,
  );
}

/// Reads and parses the `mcp:` section of [path] via the [ExecutionEnv];
/// null when the file or branch is missing/unreadable, or unparseable.
Future<McpConfig?> _readMcpConfigFromFile(AgentCli cli, String path) async {
  final text = (await cli.config.env.readTextFile(path)).valueOrNull;
  if (text == null || text.trim().isEmpty) return null;
  try {
    final doc = loadYaml(text);
    if (doc is! YamlMap) return null;
    final mcpNode = doc['mcp'];
    if (mcpNode == null) return null;
    return McpConfig.fromYaml(mcpNode);
  } on ConfigException catch (error) {
    cli.io.writeln('invalid ~/.fah/config.yaml: ${error.message}');
    return null;
  } on Object {
    return null; // Corrupt/unparseable: treat as no MCP section.
  }
}
