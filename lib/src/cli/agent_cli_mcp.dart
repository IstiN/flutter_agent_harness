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

  /// The `## MCP servers` prompt section ('' without servers).
  String promptSection() => manager?.promptSection() ?? '';

  /// The full system prompt: [base] plus any non-empty optional sections.
  String composePrompt(
    String base, {
    required String contextSection,
    required String skillsSection,
  }) {
    final mcpSection = promptSection();
    return [
      base,
      if (contextSection.isNotEmpty) contextSection,
      if (skillsSection.isNotEmpty) skillsSection,
      if (mcpSection.isNotEmpty) mcpSection,
    ].join('\n\n');
  }
}
