/// The automatic tool-result spilling wiring — split out of
/// `agent_cli.dart` to keep it under the repo's 2800-line size gate. Same
/// library (a `part of`), so the extension sees the AgentCli's private
/// members (`_agent`, `_coreToolEnv`).
part of 'agent_cli.dart';

extension AgentCliSpillWiring on AgentCli {
  /// Automatic tool-result spilling (issue #678): attached AFTER the
  /// redaction pipeline so the hook chain runs result → redact → size
  /// check → spill → preview. Null/inactive config = no attach,
  /// byte-identical legacy. gh-1604: the `FAH_SPILL_THRESHOLD` env knob
  /// resolves last — a bench run enables/tunes the cap through the
  /// environment without any config file.
  void attachSpillWiring() {
    final section = config.spills;
    final spills = resolveRunSpillsConfig(section, environment);
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
      if (section == null) {
        io.writeln(
          '[spills] enabled via $spillThresholdEnvVar='
          '${environment[spillThresholdEnvVar]} '
          '(threshold ${spills.threshold} chars)',
        );
      } else if (spills.threshold != section.threshold) {
        // gh-1604 rework: the env RETUNING a configured section is
        // announced too — silence was indistinguishable from the section
        // applying untouched.
        io.writeln(
          '[spills] threshold overridden via $spillThresholdEnvVar: '
          '${section.threshold} → ${spills.threshold}',
        );
      }
    } else if (section != null && section.isActive) {
      // gh-1604 rework: env `0` switching a configured cap OFF for this
      // run is announced as well.
      final envValue = int.tryParse(
        environment[spillThresholdEnvVar]?.trim() ?? '',
      );
      if (envValue != null && envValue <= 0) {
        io.writeln(
          '[spills] disabled via $spillThresholdEnvVar='
          '${environment[spillThresholdEnvVar]} '
          '(configured threshold ${section.threshold} chars)',
        );
      }
    }
    attachUserSpillWiring();
  }

  /// Automatic user-message spilling (issue #1760): installs the intake
  /// guard on the agent so every user message — headless `-p`/positional,
  /// TUI first/mid-session, steering, follow-up, external inbox — is
  /// bounded from the core choke point. Inactive section/env = no install,
  /// byte-identical legacy. Redaction (the same pipeline the CLI already
  /// applies to user text at the entry points) runs inside the guard, so
  /// the bare steering paths that skip the entry redaction still never
  /// write raw secrets to the spill file.
  void attachUserSpillWiring() {
    final section = config.spills;
    final spills = resolveRunSpillsConfig(section, environment);
    if (spills == null || !spills.isUserActive) return;
    final pipeline = config.redactionPipeline;
    _agent.userMessageGuard = UserMessageSpillGuard(
      env: _coreToolEnv,
      config: spills,
      budgetTokens: () =>
          _effectiveContextWindow - _effectiveCompactionSettings.reserveTokens,
      sessionId: () => _session?.cachedId,
      redact: pipeline == null ? null : (text) => redactPrompt(pipeline, text),
    ).guard;
    io.writeln(
      '[spills] user messages over ${spills.userFraction}x the window '
      'budget (floor ${spills.userThreshold} bytes) spill to '
      '.fah/spills/<session>/user-<n>.md',
    );
  }
}
