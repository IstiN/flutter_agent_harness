part of 'agent_cli.dart';

// The gh-1241 usage-ledger members of [AgentCli]: the segment-start marker
// (`usage_segment_start` custom record appended after the ownership lease
// is claimed — a viewer never mutates the owner's chain), the segment-close
// flush (fold the chain → atomic usage.json → one `fa-tokens:` diagnostic
// log line), and the `/usage rebuild` command path (the fold is always
// rebuildable from the chain; AC3/I6).

/// Usage-ledger (gh-1241) members of [AgentCli].
extension AgentCliUsageLedger on AgentCli {
  /// Appends the segment-start marker: ONE per owner process per session
  /// (I1: the fold derives segment boundaries and `resumedCount` from
  /// these markers). Every drive path lands here lazily at the FIRST drive
  /// of a session ([_runPrompt] — REPL lines, wire-serve frames) so an
  /// idle boot/switch adds zero session bytes (issue #428 invariant); the
  /// headless boot marks eagerly right after the lease gate (it always
  /// drives, and its drive bypasses [_runPrompt]). A VIEWER must never
  /// append to the owner's chain. Failures are swallowed — the ledger is
  /// a best-effort artifact, never a boot blocker.
  Future<void> _markUsageSegmentStart() async {
    if (_viewer != null) return;
    final session = _session;
    if (session == null) return;
    // Per-session idempotency: identical() holds across turns of one
    // process; a `/sessions` switch installs a fresh instance, so the new
    // session re-marks on its first drive.
    if (identical(_usageSegmentMarkedFor, session)) return;
    try {
      await session.appendCustomEntry(
        customType: usageSegmentStartCustomType,
        data: {'at': DateTime.now().toIso8601String()},
      );
      _usageSegmentMarkedFor = session;
    } on Object catch (error) {
      _logDiagnostic('usage ledger segment marker failed: $error');
    }
  }

  /// Segment-close flush: folds the session chain (the source of truth)
  /// into the per-session `usage.json` and logs one `fa-tokens:` line for
  /// the closed segment (surface 2 — the dmtools-agents dashboard's
  /// log-grepping reporter). Idempotent and rebuild-safe (I6/E3): a zero
  /// -request session writes nothing; a stale/corrupt artifact is replaced
  /// by the fresh fold, never merged into. Failures stay in the diagnostic
  /// log — exit paths never fail on the ledger.
  /// [mirrorTokensLineToRunLog]: the headless/CI leg passes true — its
  /// diag file dies with the ephemeral runner, so the segment-close line
  /// is also emitted on the CLI diagnostics channel ([CliIO.writeln]:
  /// stderr on headless hosts) where the captured run log sees it. It
  /// never rides [CliIO.write] — headless stdout stays pipeable prose
  /// (issue #774 AC3). The REPL exit/switch paths keep the default
  /// false: interactive transcripts (and PTY screen assertions) stay
  /// clean.
  Future<void> _flushUsageLedger({
    bool mirrorTokensLineToRunLog = false,
  }) async {
    if (_viewer != null) return;
    final session = _session;
    if (session == null) return;
    try {
      final metadata = await session.getMetadata();
      if (metadata.id.isEmpty || metadata.path.isEmpty) return;
      final read = await _env.readTextLines(metadata.path);
      if (read.isErr) return; // deleted/empty session: nothing to fold
      final ledger = const UsageChainFolder().foldChain(
        sessionId: metadata.id,
        lines: read.valueOrNull!,
      );
      if (ledger.total.totals.requests == 0) return; // nothing was spent
      final dir = UsageLedgerWriter.usageDirFor(
        sessionsRoot: config.sessionRoot,
        sessionId: metadata.id,
      );
      await _persistFoldIfStale(dir, ledger);
      final closed = ledger.segments.lastOrNull;
      if (closed != null) {
        final line = usageTokensLogLine(
          sessionId: metadata.id,
          segment: closed,
        );
        _logDiagnostic(line);
        // gh-1292: mirror the segment-close line onto the CLI diagnostics
        // channel ([CliIO.writeln] — stderr on headless hosts) so the
        // ephemeral runner's captured run log sees it. It must NOT ride
        // [CliIO.write]: headless stdout is the pipeable primary stream
        // (issue #774 AC3 — byte-identical assistant prose only). The
        // reporter greps the whole GH job log, stderr included. TUI
        // sessions keep the channel clean (the line stays in fa.log);
        // structured modes (HEP/stream-json) forward writeln to the
        // host's diagnostics channel via [HepEventsIO] — their NDJSON
        // wires stay pure by construction.
        if (mirrorTokensLineToRunLog && !_useTui) io.writeln(line);
      }
    } on Object catch (error) {
      _logDiagnostic('usage ledger flush failed: $error');
    }
  }

  /// E3: rewrite the fold only when the on-disk artifact is
  /// missing/stale/corrupt — an already-valid artifact means a
  /// concurrent writer landed the same fold (E2).
  Future<void> _persistFoldIfStale(String dir, UsageLedger ledger) async {
    final writer = UsageLedgerWriter(_env);
    final existing = await writer.readIfValid(
      dir,
      expectedRecords: ledger.chainRecords,
      expectedHash: ledger.chainHash,
    );
    if (existing != null) return;
    // E2: a fingerprint mismatch can also mean the on-disk artifact is a
    // NEWER fold than our chain view (a concurrent writer got further
    // along the chain before we flushed). Never clobber a fold that
    // consumed more chain records than ours — the slowest writer must
    // not win; the next close over the full chain rebuilds the complete
    // ledger (E3/I6).
    final onDisk = await writer.read(dir);
    if (onDisk == null || onDisk.chainRecords <= ledger.chainRecords) {
      await writer.write(
        dir,
        ledger,
        tmpSuffix: config.processId?.toString(),
        forbiddenSecrets: _usageLedgerForbiddenSecrets(),
      );
    }
  }

  /// The `/usage` command: `rebuild` re-folds the active session's chain
  /// onto disk (the rebuild-from-chain command path the IT suite drives),
  /// a bare `/usage` prints the current ledger.
  Future<void> _handleUsageCommand(String rest) async {
    final session = _session;
    if (session == null) {
      io.writeln('no active session');
      return;
    }
    final metadata = await session.getMetadata();
    // Same guard the flush path has: with no chain location there is
    // nothing to fold — say so instead of failing on readTextLines('').
    if (metadata.id.isEmpty || metadata.path.isEmpty) {
      io.writeln('usage: no session chain');
      return;
    }
    final dir = UsageLedgerWriter.usageDirFor(
      sessionsRoot: config.sessionRoot,
      sessionId: metadata.id,
    );
    if (rest.trim() == 'rebuild') {
      final read = await _env.readTextLines(metadata.path);
      if (read.isErr) {
        io.writeln('usage: cannot read session chain (${read.errorOrNull})');
        return;
      }
      final ledger = const UsageChainFolder().foldChain(
        sessionId: metadata.id,
        lines: read.valueOrNull!,
      );
      await UsageLedgerWriter(_env).write(
        dir,
        ledger,
        tmpSuffix: config.processId?.toString(),
        forbiddenSecrets: _usageLedgerForbiddenSecrets(),
      );
      io.writeln(
        'usage: rebuilt ${ledger.segments.length} segment(s), '
        '${ledger.total.totals.requests} request(s), '
        '${ledger.total.totals.input} in / '
        '${ledger.total.totals.output} out '
        '(${ledger.total.source.wire})',
      );
      return;
    }
    final existing = await UsageLedgerWriter(_env).read(dir);
    if (existing == null) {
      io.writeln(
        'usage: no usage.json for this session yet — run a turn, then '
        '/usage rebuild',
      );
      return;
    }
    io.writeln(
      'usage: ${existing.segments.length} segment(s), '
      '${existing.total.totals.requests} request(s), '
      '${existing.total.totals.input} in / ${existing.total.totals.output} '
      'out (${existing.total.source.wire})',
    );
  }

  /// Configured secrets the artifact must never contain (I4/UT-6): the
  /// active redaction pipeline's registered secret values (the process's
  /// merged secrets) plus runtime grants.
  List<String> _usageLedgerForbiddenSecrets() => [
    ...?config.redactionPipeline?.registeredSecrets,
    ..._runtimeSecrets.values,
  ];
}
