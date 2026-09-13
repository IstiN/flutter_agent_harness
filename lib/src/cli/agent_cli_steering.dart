/// Steering members of [AgentCli], split from agent_cli.dart to keep it
/// under the repo's 2800-line size gate. Same library (a `part of`), so the
/// extension sees the class's private members.
part of 'agent_cli.dart';

/// Steering that arrived too late to enter a run: resolution and the loud
/// drop print.
extension on AgentCli {
  /// Steers [trimmed] into the running agent with the file-reference
  /// resolution applied (a pasted path becomes an explicit
  /// `[attached file: …]` marker — a bare path steered as plain text made
  /// the model miss the attachment entirely).
  void _steerResolved(String trimmed) {
    final resolved = resolveInteractiveFileReference(trimmed);
    if (resolved != trimmed) {
      io.writeln(_style.dim('[file] attached to steered message'));
    }
    if (isBusy) {
      // Mid-run user steering joins the deferred-panel history (AC3).
      _hubAddPanel(
        kind: DeferredPanelKind.steering,
        from: 'you',
        body: resolved,
      );
    }
    _agent.steer(UserMessage.text(resolved));
  }

  /// The steering still queued after a run settled, or null when there
  /// is nothing left to settle (or the session already exited).
  LeftoverSteering? _leftoverSteeringOutcome() {
    if (_exited || !_agent.hasSteering) return null;
    return resolveLeftoverSteering(
      drain: _agent.drainSteeringQueue,
      abortRequested: _abortRequested,
    );
  }

  /// Prints exactly what was discarded — a silent drop is
  /// indistinguishable from a lost message.
  void _printDroppedSteering(List<String> texts) {
    io.writeln(_style.dim('dropped steering message(s) after interrupt:'));
    for (final text in texts) {
      final elided = text.length <= 80 ? text : '${text.substring(0, 80)}…';
      io.writeln(_style.dim('  • ${elided.replaceAll('\n', ' ')}'));
    }
  }

  /// Runs or loudly drops the steering messages still queued after a run
  /// settled (they missed every drain point: raced past the last poll, or
  /// the run was interrupted). Running keeps "typed but never answered"
  /// from happening; dropping prints exactly what was discarded — a silent
  /// drop is indistinguishable from a lost message.
  void _settleLeftoverSteering() {
    final outcome = _leftoverSteeringOutcome();
    if (outcome == null) return;
    if (outcome.run) {
      io.writeln(
        _style.dim(
          'steering arrived after the last checkpoint — running '
          '${outcome.texts.length} message(s) now',
        ),
      );
      _startRun(outcome.texts.join('\n'));
      return;
    }
    _printDroppedSteering(outcome.texts);
  }
}
