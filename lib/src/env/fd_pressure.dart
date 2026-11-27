/// fd-pressure guard contracts for the tool layer (gh-2415).
///
/// A long-lived session at the descriptor soft limit saw the bash tool
/// die with an uncaught `ProcessException: Too many open files` (surfaced
/// to the model as "the tool may be unavailable in this environment") and
/// the receipt writer lose writes on every tick. This file is the pure
/// half: the snapshot shape, the threshold, the errno-24 recognizer shared
/// by the bash tool and the receipt writer, and the typed, visible error
/// the bash tool raises instead of the uncaught exception. The VM probe
/// lives in `fd_pressure_io.dart` (behind a web stub).
library;

import '../exceptions.dart';

/// One fd-table sample: open descriptors vs the process's soft limit.
typedef FdPressureSnapshot = ({int open, int limit});

/// The fraction of the soft limit at which the bash tool path guards.
const double fdPressureThreshold = 0.8;

/// Whether [snapshot] is in the pressure zone (above [fdPressureThreshold]
/// of a positive limit). Pure.
bool fdPressureExceeded(FdPressureSnapshot snapshot) =>
    snapshot.limit > 0 && snapshot.open > snapshot.limit * fdPressureThreshold;

/// The text a sample renders in errors and notices: `N/M open`.
String fdPressureLabel(FdPressureSnapshot snapshot) =>
    '${snapshot.open}/${snapshot.limit} open';

/// Whether [error] is the OS saying the descriptor table is full: errno 24
/// (`EMFILE` on macOS and Linux alike) or its message, read off the
/// rendered text — pure (no `dart:io` types), so a harness-wrapped
/// `FileError`, a `ProcessException` and a `FileSystemException` all
/// match.
bool isFdPressureError(Object error) {
  final text = error.toString();
  return text.contains('Too many open files') ||
      text.contains('errno 24') ||
      text.contains('EMFILE');
}

/// The typed, visible bash tool error for descriptor exhaustion (gh-2415):
/// operational (a [ToolValidationException], so the loop renders it as a
/// tool error, never "an uncaught exception inside the harness tool
/// implementation") and actionable — it names the pressure and the lever.
final class FdPressureException extends ToolValidationException {
  FdPressureException({required this.open, required this.limit})
    : super(
        'bash',
        'fd pressure: $open/$limit open — retried after closing settled '
            'jobs, still above the limit. Wait for running jobs to settle or '
            'stop one (bash_job action: stop), then retry this call.',
      );

  /// The same error for an EMFILE the OS raised before a sample existed
  /// (a spawn failure, a thrown `FileSystemException`): no counts.
  const FdPressureException.unsampled()
    : open = -1,
      limit = -1,
      super(
        'bash',
        'fd pressure: the descriptor table is full (Too many open files) — '
            'wait for running jobs to settle or stop one (bash_job action: '
            'stop), then retry this call.',
      );

  /// Open descriptors at the time of the refusal (-1 when unsampled).
  final int open;

  /// The soft limit in force (-1 when unsampled).
  final int limit;
}
