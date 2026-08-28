/// The auto-compaction UI hooks — split out of `agent_cli.dart` to keep it
/// under the repo's 2800-line size gate. Same library (a `part of`), so the
/// class sees the AgentCli's private members (`_logDiagnostic`).
part of 'agent_cli.dart';

/// [AutoCompactorHooks] impl that drives the CLI TUI / stderr and the
/// diagnostic log file (`~/.fah/logs/fa.log`). One per run; cheap to
/// allocate.
class _AutoCompactorCliHooks implements AutoCompactorHooks {
  _AutoCompactorCliHooks(this.cli);

  final AgentCli cli;

  DateTime? _lastDeltaPhase;
  String _compactionTail = '';

  @override
  void onDelta(String delta) {
    // Live tail of the summary being written, shown in the busy row so
    // compaction reads as work, not a hang. Throttled — deltas are hot.
    final merged = (_compactionTail + delta).replaceAll('\n', ' ');
    _compactionTail = _rollingTail(merged);
    final now = DateTime.now();
    final last = _lastDeltaPhase;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 150)) {
      return;
    }
    _lastDeltaPhase = now;
    cli._tuiController?.setBusyPhase('Compacting context… $_compactionTail');
  }

  /// The last 60 chars of the merged tail (newlines flattened) — a helper
  /// so [onDelta] stays at the repo's CC gate.
  static String _rollingTail(String merged) =>
      merged.length > 60 ? merged.substring(merged.length - 60) : merged;

  @override
  void onPass(AutoCompactorPass pass) {
    if (!pass.ok) {
      // The pass failed: onBothRolesFailed already prints the user-facing
      // hint. Printing the success-looking "auto-compacted" line here
      // claimed context was summarized when nothing was.
      cli._logDiagnostic(
        'auto-compact pass ${pass.pass} FAILED '
        'tokens ${pass.tokensBefore}→${pass.tokensAfter} '
        'error=${pass.error ?? '-'}',
      );
      return;
    }
    if (pass.fallback == 'local-trim') {
      // Mechanical in-memory trim (summarizer down): honest wording, no
      // "summarized" claim.
      cli.io.writeln(
        '[context trimmed] ${pass.tokensBefore} → ${pass.tokensAfter} '
        'tokens (summarizer unavailable — kept the most recent messages '
        'locally; the session file keeps the full history)',
      );
      cli._logDiagnostic(
        'auto-compact pass ${pass.pass} local-trim '
        'tokens ${pass.tokensBefore}→${pass.tokensAfter}',
      );
      return;
    }
    if (pass.tokensAfter == pass.tokensBefore) {
      // No-op pass (already compacted at the leaf): nothing changed —
      // stay quiet instead of printing a fake "N tokens summarized".
      cli._logDiagnostic('auto-compact pass ${pass.pass} no-op');
      return;
    }
    cli.io.writeln(
      '[auto-compacted${pass.pass == 1 ? '' : ' pass=${pass.pass}'}] '
      '${pass.tokensBefore} tokens summarized',
    );
    cli._logDiagnostic(
      'auto-compact pass ${pass.pass} '
      'fallback=${pass.fallback ?? '-'} '
      'tokens ${pass.tokensBefore}→${pass.tokensAfter} '
      'ok=${pass.ok} error=${pass.error ?? '-'}',
    );
  }

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {
    cli.io.writeln(
      'compaction transient error (attempt $attempt/$maxAttempts); '
      'retrying in ${backoff.inSeconds}s — $error',
    );
    cli._logDiagnostic(
      'compact retry attempt=$attempt backoff=${backoff.inSeconds}s '
      'error=$error',
    );
  }

  @override
  void onDone(int passes, int tokens) {
    if (passes > 0) {
      cli._logDiagnostic('auto-compact done passes=$passes tokens=$tokens');
    }
  }

  @override
  void onBothRolesFailed(Object lastError) {
    final hint = cli._compactionFailureHint(lastError);
    cli.io.writeln('compaction both roles failed: $hint');
    cli.io.writeln(
      'compaction both roles failed; the agent cannot make progress '
      'until you switch models (e.g. `/model`) or start a new session '
      '(`/new`).',
    );
  }
}
