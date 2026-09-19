/// The automatic tool-result spilling wiring — split out of
/// `agent_cli.dart` to keep it under the repo's 2800-line size gate. Same
/// library (a `part of`), so the extension sees the AgentCli's private
/// members (`_agent`, `_coreToolEnv`).
part of 'agent_cli.dart';

extension AgentCliSpillWiring on AgentCli {
  /// Automatic tool-result spilling (issue #678): attached AFTER the
  /// redaction pipeline so the hook chain runs result → redact → size
  /// check → spill → preview. Null/inactive config = no attach,
  /// byte-identical legacy.
  void attachSpillWiring() {
    final spills = config.spills;
    if (spills != null && spills.isActive) {
      attachSpillHooks(
        _agent,
        env: _coreToolEnv,
        sessionId: () => _session?.cachedId,
        config: spills,
      );
      for (final note in spills.notes) {
        io.writeln('[spills] $note');
      }
    }
  }
}
