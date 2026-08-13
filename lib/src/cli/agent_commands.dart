/// Agent discovery and listing commands split from [AgentCli] to keep
/// agent_cli.dart under the repo's 2800-line size gate.
/// Same library (a `part of`), so the extension sees the class's private members.
part of 'agent_cli.dart';

/// Implementation members of [AgentCli] for agent-type discovery and listing.
extension AgentCliAgentExt on AgentCli {
  /// Fire-and-forget discovery: scans project + user roots for agent .md files.
  Future<void> discoverAgentsFromRoots(
    ({List<String> projectRoots, List<String> userRoots}) roots,
  ) async {
    final result = await discoverTaskAgents(
      config.env,
      projectRoots: roots.projectRoots,
      userRoots: roots.userRoots,
    );
    _discoveredAgents = result.agents;
    for (final note in result.notes) {
      io.writeln('  agent discovery: $note');
    }
  }

  /// `/agents`: lists all available agent types (built-in + discovered).
  void listAgentTypes() {
    final builtins = ['task', 'explore', 'review'];
    io.writeln('agent types:');
    for (final name in builtins) {
      io.writeln('  $name (built-in)');
    }
    for (final agent in _discoveredAgents) {
      io.writeln('  ${agent.name} — ${agent.description}');
    }
    if (_discoveredAgents.isEmpty) {
      io.writeln(
        '  (no discovered types — add .fah/agents/<name>.md to extend)',
      );
    }
  }
}
