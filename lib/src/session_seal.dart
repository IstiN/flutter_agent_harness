/// gh-1589: the session seal — the close boundary behind the headless run.
///
/// Once a run's terminal state is recorded (`runHeadless` completes, the
/// REPL tears down), the session JSONL must become immutable FOR THIS
/// PROCESS: stray background-shell settles, a late usage fold, a queued
/// job-board persist — no writer may append after the boundary, no matter
/// how long the process lingers (I1). The seal is state in the WRITER, not
/// in the file: no session file format changes, no migration (the
/// excluded/second-tier rows of the lifecycle table), and a new Session
/// instance over the same file resumes unsealed (I5/E5 — the seal is
/// per-run, not per-file-forever).
///
/// Late-write policy (the ticket's open question, resolved): drop + warn —
/// exactly ONE warning per writer class (message, `custom:<type>`,
/// compaction, …) through [onLateWrite], never a throw into an unhandled
/// zone. A hard failure would retroactively poison a solved trial because
/// of a stray job; the exit code stays the turn's terminal outcome
/// (issue #413 semantics untouched).
final class SessionSeal {
  SessionSeal({this.onLateWrite});

  /// Where the one-per-class warnings go. The CLI wires its diagnostics
  /// channel (stderr on headless hosts); null degrades to a silent drop.
  final void Function(String message)? onLateWrite;

  DateTime? _sealedAt;

  /// The writer classes already warned about — the "exactly one loud
  /// warning each class" dedupe set.
  final Set<String> _warnedClasses = {};

  /// Whether the seal is closed.
  bool get isSealed => _sealedAt != null;

  /// When the seal closed (null while open).
  DateTime? get sealedAt => _sealedAt;

  /// Seals the session. Idempotent: the first call wins, later calls (and
  /// their sinks) are no-ops.
  void seal() => _sealedAt ??= DateTime.now();

  /// Reports a late write of [writerClass] against a closed seal: drops
  /// nothing itself (the caller skips the append), warns once per class.
  void rejectWrite(String writerClass) {
    if (!isSealed) return;
    if (!_warnedClasses.add(writerClass)) return;
    final sink = onLateWrite;
    if (sink == null) return;
    final at = _sealedAt;
    sink(
      'session sealed${at == null ? '' : ' at ${at.toIso8601String()}'} — '
      'dropped late write ($writerClass): the session JSONL is immutable '
      'for this process (gh-1589)',
    );
  }
}
