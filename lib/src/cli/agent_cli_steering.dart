/// Leftover-steering settle members of [AgentCli], split from agent_cli.dart
/// to keep it under the repo's 2800-line size gate. Same library (a `part
/// of`), so the extension sees the class's private members.
part of 'agent_cli.dart';

/// Steering that arrived too late to enter a run: resolution and the loud
/// drop print.
extension on AgentCli {
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
}
