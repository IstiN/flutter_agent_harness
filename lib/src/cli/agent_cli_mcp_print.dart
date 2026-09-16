part of 'agent_cli.dart';

// `/mcp` status printing for [AgentCli] — split out of `agent_cli.dart`
// to keep it under the repo's 2800-line size gate (same library, a `part
// of`, so the extension sees the class's private fields with no
// visibility change).

extension AgentCliMcpStatusPrint on AgentCli {
  /// `/mcp`: prints the configured MCP servers and their live connection
  /// status, or a guidance line when none are configured.
  void _printMcpStatus() {
    final manager = _mcp.manager;
    if (manager == null || manager.config.servers.isEmpty) {
      io.writeln(
        'No MCP servers configured. Add servers to the mcp: section of '
        '~/.fah/config.yaml:\n'
        '  mcp:\n'
        '    servers:\n'
        '      example:\n'
        '        command: npx\n'
        '        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]\n'
        '      # or a remote server:\n'
        '      remote:\n'
        '        url: https://example.com/mcp',
      );
      return;
    }
    io.writeln('MCP servers:');
    final states = manager.states;
    for (final entry in manager.config.servers.entries) {
      final name = entry.key;
      final state = states[name];
      final status = switch (state?.status) {
        null => _style.dim('(connecting…)'),
        _ => switch (state!.status) {
          McpServerStatus.connected =>
            '${tuiSuccess('connected')} — ${state.tools.length} tool(s)',
          McpServerStatus.failed =>
            '${tuiError('failed')}: ${state.error ?? 'unknown'}',
          McpServerStatus.connecting => _style.dim('(connecting…)'),
        },
      };
      final server = entry.value;
      final detail = server is McpStdioServerConfig
          ? '${server.command} ${(server.args).join(' ')}'
          : server is McpHttpServerConfig
          ? server.url
          : '';
      io.writeln('  $name — $status  ${_style.dim(detail)}');
    }
  }
}
