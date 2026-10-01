/// The tool-misuse circuit breaker (issue #862, second tier): N consecutive
/// identical rejections of the same tool inject a corrective note into the
/// next request; M stop executing that identical call for the rest of the
/// run — an honest refusal instead of a 15-retry burn loop.
///
/// The luna incident (2026-09-23): a model re-sent the byte-identical
/// malformed `edit` call 15 consecutive times across 15 turns, hard-rejected
/// every time, then hallucinated success. This breaker is loop-owned (the
/// agent loop feeds failures/successes and drains the pending note into the
/// request payload), so this class stays a pure state machine: no results,
/// no messages beyond the note, no I/O.
///
/// Keying: per (tool name, canonical arguments JSON) — the true loop
/// signature is the IDENTICAL call failing identically (E2: counters are
/// per tool, never global). A different call, a different error, or a
/// success resets that tool's consecutive-failure state. Counters reset
/// wholesale at run start ([beginRun], called by the loop).
library;

/// Threshold semantics: [noteThreshold] consecutive identical failures arm
/// the corrective note for the NEXT request; [stopThreshold] stop executing
/// that identical call in the current run (the loop refuses it before any
/// execution, with an honest error naming the misuse).
final class ToolMisuseBreaker {
  ToolMisuseBreaker({
    this.noteThreshold = 3,
    this.stopThreshold = 6,
    this.descriptionLimit = 240,
  }) : assert(noteThreshold >= 2),
       assert(stopThreshold > noteThreshold);

  /// Consecutive identical failures before the corrective note arms.
  final int noteThreshold;

  /// Consecutive identical failures before the identical call is refused
  /// for the rest of the run.
  final int stopThreshold;

  /// Cap on the tool-description excerpt carried by the corrective note.
  final int descriptionLimit;

  final _states = <String, _MisuseState>{};
  final _pendingNotes = <String>[];

  /// Wipes all counters, notes, and stopped keys (loop run start).
  void beginRun() {
    _states.clear();
    _pendingNotes.clear();
  }

  /// Canonical key for a tool call's arguments: the identical retry has a
  /// byte-identical argument map (same JSON source, same insertion order).
  String argsKey(Map<String, dynamic> arguments) => arguments.toString();

  /// Whether the loop must refuse this call without executing it: the
  /// identical call has hit [stopThreshold] consecutive failures in this
  /// run. The returned text is the honest, remedy-bearing refusal.
  String? refusalFor(String toolName, Map<String, dynamic> arguments) {
    final state = _states['$toolName\u0000${argsKey(arguments)}'];
    if (state == null || !state.stopped) return null;
    return 'Tool "$toolName" refused: this exact call already failed '
        '${state.failures} consecutive times with the same error '
        '(${state.lastError}) and the harness stopped executing it for '
        'this run. Change the arguments or use a different tool.';
  }

  /// Records one failed execution of [toolName]. Returns true when this
  /// failure just armed a corrective note for the next request (the loop
  /// drains it via [drainPendingNote]).
  bool observeFailure(
    String toolName,
    Map<String, dynamic> arguments,
    String errorText, {
    String? toolDescription,
  }) {
    if (errorText == 'Operation aborted') return false;
    final key = '$toolName\u0000${argsKey(arguments)}';
    final state = _states[key] ??= _MisuseState();
    if (state.lastError != errorText) {
      // A different error means a different failure: restart the count.
      state
        ..lastError = errorText
        ..failures = 1
        ..stopped = false
        ..noted = false;
    } else {
      state.failures++;
    }
    if (state.failures >= stopThreshold) {
      state.stopped = true;
      return false;
    }
    if (state.failures >= noteThreshold && !state.noted) {
      state.noted = true;
      _pendingNotes.add(_noteText(toolName, state, toolDescription));
      return true;
    }
    return false;
  }

  /// Records a successful execution: the model recovered, so this tool's
  /// consecutive-failure state clears.
  void observeSuccess(String toolName) {
    _states.removeWhere((key, _) => key.startsWith('$toolName\u0000'));
  }

  /// Drains armed corrective notes (joined) for injection into the next
  /// request payload; null when none armed. Request-only: the transcript
  /// never sees the note.
  String? drainPendingNote() {
    if (_pendingNotes.isEmpty) return null;
    final note = _pendingNotes.join('\n\n');
    _pendingNotes.clear();
    return note;
  }

  String _noteText(String toolName, _MisuseState state, String? description) {
    final excerpt = (description ?? '').trim();
    final contract = excerpt.isEmpty
        ? ''
        : '\nTool contract (excerpt): '
            '${excerpt.length <= descriptionLimit ? excerpt : '${excerpt.substring(0, descriptionLimit)}…'}\n';
    return '[tool-misuse notice] The "$toolName" tool has rejected the '
        'identical call ${state.failures} consecutive times. Last error: '
        '${state.lastError}.$contract'
        'Fix the call before retrying: after $stopThreshold identical '
        'failures the harness stops executing this call in this run.';
  }
}

final class _MisuseState {
  int failures = 0;
  String lastError = '';
  bool noted = false;
  bool stopped = false;
}
