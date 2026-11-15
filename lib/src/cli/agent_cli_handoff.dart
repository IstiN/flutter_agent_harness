part of 'agent_cli.dart';

// `/handoff` (gh-2102): start a FRESH session from an EDITABLE digest of the
// current one. The digest reuses the branch-digest generation
// (`handoff_digest.dart` — prepareBranchEntries + the shared summarizer
// seam) composed with a handoff preamble; the user edits it in their
// `$EDITOR`; the fresh session is seeded with the edited digest + the
// relevant-file list. The OLD session is never written to: nothing is
// deleted, the branch stays reachable (the lossless guarantee) — the
// receipt prints its resume link.

/// The `/handoff` scratch digest file name marker (the editor simulator in
/// tests keys off it; the file lives under `<cwd>/.fah/` and is removed
/// after the flow).
const _handoffDigestFilePattern = 'handoff-digest';

/// Composes the external-editor invocation for the digest file, quoted for
/// the HOST shell the env's `exec` runs it under (gh-2102 review):
/// POSIX `sh -c` wraps the path in single quotes (the `'\''` escape);
/// Windows `cmd /c` gets DOUBLE quotes — single quotes are literal
/// characters there, so the POSIX form handed the editor a quoted
/// (nonexistent) file name and the edit step silently never worked.
/// [isWindows] pins the shell flavour (unit tests; the CI runners cannot
/// exercise the Windows arm in situ).
String handoffEditorCommand(String editor, String path, {bool? isWindows}) {
  if (isWindows ?? hostShellIsWindows) {
    // cmd strips the double quotes; embedded double quotes double up
    // (defensive only — `"` is a reserved character in Windows file names).
    return '$editor "${path.replaceAll('"', '""')}"';
  }
  return "$editor '${path.replaceAll("'", r"'\''")}'";
}

/// `/handoff` (gh-2102) — the edit-then-start flow.
extension HandoffSlashCommand on AgentCli {
  Future<void> _handoffSlash(String rest) async {
    final session = _session;
    if (session == null) return;
    // Never switch sessions under a streaming turn (the /update settle
    // contract): the digest call itself is the only wait after this.
    await _settled;
    // The SESSION branch is the authority — not `_agent.state.messages`,
    // which a resumed session only rebuilds at its first drive.
    // gh-2102 review (BLOCKING): a resumed session is opened windowed and
    // the resume walk keeps only the parity-budget tail resident —
    // [collectEntriesForHandoff] primes whole-ledger residency first; the
    // tooLarge backstop refusal degrades LOUDLY here: the digest then
    // covers only the resident tail and the note says so (the old session
    // keeps the full history — nothing is lost, the digest is partial).
    List<SessionRecord> entries;
    try {
      entries = await collectEntriesForHandoff(session);
    } on SessionException catch (error) {
      if (error.code != SessionErrorCode.tooLarge) rethrow;
      io.writeln(
        'handoff: the session ledger exceeds the whole-ledger residency '
        'bound — the digest will cover only the resident tail; the old '
        'session keeps the full history',
      );
      io.writeln(_style.dim(error.message));
      entries = await collectResidentBranchForHandoff(session);
    }
    if (entries.isEmpty) {
      io.writeln('nothing to hand off — this session has no conversation');
      return;
    }

    // 1. Generate the digest (branch-digest machinery, handoff preamble).
    _pushBusyPhase('Writing handoff digest…');
    _waiting.compactionLivenessStart();
    // User-wired digest cancellation (gh-2102 review, issue #1085 M3
    // parity): the digest LM call is a multi-minute summarization and
    // Ctrl-C used to abort NOTHING — `_abortRunOrCompaction` found no
    // registered token, latched the sticky `_runAbortRequested`, and the
    // call ground to completion (the flag even riding toward the fresh
    // session). Mirror the compaction wiring: a per-flow CancelTokenSource
    // registered in `_activeCompactionAbort` (the interrupt routing's
    // `else if` arm — /handoff runs OUTSIDE a run bracket, `isBusy` false),
    // LINKED to the live run token when one exists, and cleared in the
    // `finally`. The digest.aborted → "handoff interrupted" receipt below
    // is the visible result.
    final abort = CancelTokenSource();
    _activeCompactionAbort = abort;
    final runToken = _agent.cancelToken;
    if (runToken != null) {
      unawaited(
        runToken.onCancel.then((_) => abort.cancel(runToken.cancelReason)),
      );
    }
    final HandoffDigestResult digest;
    try {
      final slot = _resolveMemoryLlmSlot();
      if (slot == null) {
        io.writeln('handoff digest failed: no summarizer model available');
        return;
      }
      digest = await generateHandoffDigest(
        entries,
        summarize: streamFunctionSummarizer(slot.stream, slot.model),
        // gh-2102 review (IMPORTANT): bound the digest payload to the
        // DIGEST MODEL's own window (the #729 parity guard the compaction
        // digest rides) — an over-budget branch chunk-folds instead of
        // overflowing the summarizer with one giant prompt.
        summarizerWindow: slot.model.contextWindow,
        settings: _effectiveCompactionSettings,
        cancelToken: abort.token,
      );
    } finally {
      _activeCompactionAbort = null;
      _waiting.compactionLivenessEnd();
      _pushBusyPhase('');
    }
    if (digest.aborted) {
      io.writeln(_style.dim('handoff interrupted'));
      return;
    }
    if (digest.summary == null) {
      io.writeln('handoff digest failed: ${digest.error}');
      return;
    }

    // 2. Open it for editing.
    final edited = await _editHandoffDigest(digest.summary!);
    if (edited == null) return; // cancelled — the flow already reported

    // 3. Start the fresh session seeded with digest + file list.
    await _switchToHandoffSession(
      digest: edited,
      readFiles: digest.readFiles,
      modifiedFiles: digest.modifiedFiles,
    );
  }

  /// Writes [digest] to a scratch file, opens it in the user's editor, and
  /// returns the edited text. Returns `null` only when the handoff is
  /// CANCELLED (the file was emptied). Every unavailable-edit path degrades
  /// to the generated digest with a visible note — the LM call is already
  /// paid for; an unusable editor must not waste it.
  Future<String?> _editHandoffDigest(String digest) async {
    final dir = (await _env.joinPath([_env.cwd, '.fah'])).valueOrNull;
    if (dir == null) return digest;
    await _env.createDir(dir, recursive: true);
    final path = (await _env.joinPath([
      dir,
      '$_handoffDigestFilePattern-${DateTime.now().millisecondsSinceEpoch}.md',
    ])).valueOrNull;
    if (path == null) return digest;
    final editor = _resolveHandoffEditor();
    try {
      if ((await _env.writeFile(path, digest)).isErr) {
        io.writeln(
          _style.dim(
            'handoff: could not write the digest file — using it as '
            'generated',
          ),
        );
        return digest;
      }
      if (editor == null || !io.isInteractive) {
        io.writeln(
          _style.dim(
            'no editor configured — using the digest as generated '
            '(set FA_EDITOR, VISUAL or EDITOR to edit before the handoff)',
          ),
        );
        return digest;
      }
      final run = await _env.exec(handoffEditorCommand(editor, path));
      final exit = run.valueOrNull?.exitCode;
      if (run.isErr || (exit != null && exit != 0)) {
        io.writeln(
          _style.dim(
            'editor exited (${run.errorOrNull?.message ?? 'exit $exit'}) — '
            'using the digest as generated',
          ),
        );
        return digest;
      }
      final readBack = await _env.readTextFile(path);
      final text = readBack.valueOrNull;
      if (text == null) {
        io.writeln(
          _style.dim(
            'handoff: could not read back the edited digest — using it as '
            'generated',
          ),
        );
        return digest;
      }
      if (text.trim().isEmpty) {
        // Emptying the file is the cancel gesture: no session switch.
        io.writeln('handoff cancelled — the digest was emptied');
        return null;
      }
      return text;
    } finally {
      // Best-effort scratch cleanup — never blocks or fails the flow.
      unawaited(_env.remove(path, force: true));
    }
  }

  /// The external editor for the digest: `FA_EDITOR` > `VISUAL` > `EDITOR`;
  /// null when the host wired no env lookup or none is set.
  String? _resolveHandoffEditor() {
    final lookup = config.envVarValue;
    if (lookup == null) return null;
    for (final name in const ['FA_EDITOR', 'VISUAL', 'EDITOR']) {
      final value = lookup(name);
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  /// The switch itself: mirrors `/reset`'s in-process session switch, seeds
  /// the fresh session with the digest record, and injects the digest as
  /// the live opening context (counted as persisted — its durable form is
  /// the `handoff_digest` record, so the next run never re-persists it as
  /// a plain message; the TTSR-injection pattern).
  Future<void> _switchToHandoffSession({
    required String digest,
    required List<String> readFiles,
    required List<String> modifiedFiles,
  }) async {
    _agent.reset();
    _checkpoints.clear();
    _ttsr?.reset();
    // The image-drop latch is run-lifetime state (issue #1889 R4): a
    // brand-new session re-latches from its first request.
    imageDropUx.reset();
    final previousSession = _session;
    final fresh = await _createSession();
    await seedHandoffRecord(
      fresh,
      digest: digest,
      readFiles: readFiles,
      modifiedFiles: modifiedFiles,
    );
    _agent.state.messages = [UserMessage.text(digest)];
    _session = fresh;
    _notifyPluginSessionReady();
    // herdr must re-report the switch (#1483 review) and the fabric
    // mailboxes follow the new session.
    _herdrSessionSwitched();
    _syncMailboxPrefix();
    // Re-claim ownership for the new session (#428).
    await _reclaimAfterSwitch(previousSession);
    await _printViewerBannerIfAny();
    _persistedCount = 1;
    io.writeln('handed off to a fresh session');
    // Cross-session link back: the old session is untouched and reachable.
    var oldRef = (await previousSession?.getMetadata())?.id;
    final oldName = await previousSession?.getSessionName();
    if (oldName != null && oldName.isNotEmpty) oldRef = oldName;
    io.writeln(
      _style.dim(
        "the previous session is byte-identical and stays reachable: "
        "fa --session '$oldRef'",
      ),
    );
  }
}
