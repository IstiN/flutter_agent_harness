/// The session-lifecycle helpers on [AgentCli] — split out of
/// `agent_cli.dart` to keep it under the repo's 2800-line size gate (same
/// library — a `part of` — so the extension sees the private members).
part of 'agent_cli.dart';

/// Session resume hint, idle waiting and empty-session cleanup.
extension AgentCliSessionLifecycle on AgentCli {
  /// The `fa --session …` resume line, or null when nothing was persisted.
  /// Separate from [printSessionResumeHint] so non-REPL callers (the SIGINT
  /// exit path) can print it to the REAL stdout after the TUI is gone —
  /// routing through [io] there would write into a dead transcript.
  Future<String?> sessionResumeHint() async {
    final session = _session;
    if (session == null || _persistedCount == 0) return null;
    // A windowed marathon resume pages only the tail up to the compaction
    // boundary: a name written at creation stays OUTSIDE the resident
    // window, so getSessionName() reads null and the hint degraded to the
    // raw id (user report after #503 windowing). Probe the file's
    // head+tail windows — the same bounded quick path `--session NAME`
    // resolution uses (#369) — before falling back to the id.
    var name = await session.getSessionName();
    final metadata = await session.getMetadata();
    if (name == null) {
      final repo = _repo;
      if (repo is JsonlSessionRepo) {
        try {
          name = await repo.sessionNameQuick(metadata);
        } on Object {
          name = null; // unreadable file at exit: degrade to the id
        }
      }
    }
    final id = name ?? metadata.id;
    return "resume this session with: fa --session '$id'";
  }

  /// Resolves when the in-flight run settles, bounded by [timeout] so an
  /// exit path (SIGINT) can never wedge on a stuck provider — a partial
  /// transcript is still persisted by the run's own error/abort handling.
  Future<void> waitForIdle({Duration timeout = const Duration(seconds: 5)}) {
    return _settled.timeout(timeout, onTimeout: () {});
  }

  /// Deletes the active session's file when nothing was ever said in it:
  /// opening the CLI and leaving (or only poking slash commands) must not
  /// litter the sessions list with empty files. Best-effort - exit and
  /// session switching never fail on it. A session that owns subagents is
  /// NOT empty: its `subagent_registry` record is real content. A session
  /// that already has persisted records (e.g. a user message saved before a
  /// run that was interrupted) is also kept.
  Future<void> deleteSessionIfEmpty() async {
    if (!_sessionIsEmpty()) return;
    await _deleteEmptySessionFile();
  }
}
