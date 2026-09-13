/// Steering members of [AgentCli], split from agent_cli.dart to keep it
/// under the repo's 2800-line size gate. Same library (a `part of`), so the
/// extension sees the class's private members.
part of 'agent_cli.dart';

/// Steering that arrived too late to enter a run: resolution and the loud
/// drop print. Named so the driver-test seams below stay reachable from
/// the test suite (the private members stay library-private).
extension AgentCliSteering on AgentCli {
  /// Steers [trimmed] into the running agent with the file-reference
  /// resolution applied (a pasted path becomes an explicit
  /// `[attached file: …]` marker — a bare path steered as plain text made
  /// the model miss the attachment entirely). [images] rides along when
  /// the steer originated from a composer submit carrying clipboard chips
  /// (issue #276): they become ImageContent blocks next to the text.
  void _steerResolved(
    String trimmed, {
    List<TuiImageAttachment> images = const [],
  }) {
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
    if (images.isEmpty) {
      _agent.steer(UserMessage.text(resolved));
      return;
    }
    _agent.steer(
      UserMessage(
        content: [
          TextContent(text: resolved),
          for (final image in images)
            ImageContent(
              data: base64Encode(image.bytes),
              mimeType: image.mimeType,
            ),
        ],
        timestamp: DateTime.now(),
      ),
    );
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

  /// Test seam: queues a steer through the same `_steerResolved` path
  /// mid-run input takes (panel join + agent steer queue).
  @visibleForTesting
  void steerForTest(String text) => _steerResolved(text);

  /// Test seam: the run-settle steering resolution (leftover run or loud
  /// drop) so driver tests can exercise both branches deterministically
  /// instead of racing the real settle window.
  @visibleForTesting
  void settleLeftoverSteeringForTest() => _settleLeftoverSteering();
}
