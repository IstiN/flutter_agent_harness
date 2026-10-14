// gh-1603 headless exit-code policy, split into a `part of` so it sees the
// library-private AgentCli surface (same layout as `agent_cli_hep_io.dart`)
// and [AgentCli.runHeadless] stays under the CRAP ratchet (12.0 pinned in
// crap4dart.yaml).
part of 'agent_cli.dart';

/// Terminal verdict of a settled headless run — the gh-1603 exit-code
/// policy helpers behind [AgentCli.runHeadless].
extension AgentCliHeadlessExit on AgentCli {
  /// Whether the settled run ended on an EMPTY assistant completion
  /// (gh-1603): an UNFINISHED session — no final answer was produced — even
  /// though no error/abort terminal was raised. Error/aborted stops keep
  /// their own exit codes ([_headlessExitCode]).
  ///
  /// Reads the visible transcript's last message, so the probe is only
  /// valid BEFORE [_afterRun]: post-run compaction folds assistant turns
  /// out of the visible transcript (issue #413). [runHeadless] calls this
  /// right after the settle, before any fold.
  bool _settledOnEmptyCompletion() {
    final settledMessage = _agent.state.messages.lastOrNull;
    return settledMessage is AssistantMessage &&
        settledMessage.stopReason != StopReason.error &&
        settledMessage.stopReason != StopReason.aborted &&
        isEmptyAssistantCompletion(settledMessage);
  }

  /// The process exit code of a finished headless run (gh-1603): an
  /// unfinished session (an empty settle after the headless nudge budget)
  /// prints the explicit [headlessIncompleteMarker] on the diagnostics
  /// channel and fails with 1 — a distinguishable failure for the bench
  /// adapter, never a silent exit 0.
  ///
  /// Otherwise the exit code describes the LAST completed turn's terminal
  /// outcome ([terminalStopReason], captured from the turn events — not
  /// the visible transcript, which post-run compaction rebuilds): the
  /// checkpoint fold drops the assistant turns entirely and the classic
  /// trim marker lands after the error stop; both used to mask a failed
  /// run as exit 0 (issue #413).
  int _headlessExitCode({
    required bool endedOnEmptyCompletion,
    required StopReason? terminalStopReason,
  }) {
    if (endedOnEmptyCompletion) {
      io.writeln(
        '$headlessIncompleteMarker the run ended on an empty model '
        'response — no final answer was produced; the task did not '
        'complete',
      );
      return 1;
    }
    return switch (terminalStopReason) {
      StopReason.error => 1,
      StopReason.aborted => 130,
      _ => 0,
    };
  }
}
