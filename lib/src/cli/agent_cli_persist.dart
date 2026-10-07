part of 'agent_cli.dart';

// Session-persistence members of [AgentCli] — split out of `agent_cli.dart`
// to keep it under the repo's 2800-line size gate. Same library (a `part
// of`), so the extension sees the class's private fields (`_session`,
// `_persistedCount`) with no visibility change.

extension AgentCliPersist on AgentCli {
  /// Persists a single message as soon as the agent adds it to the transcript.
  /// Keeps [_persistedCount] aligned so [_afterRun] only writes anything the
  /// listener may have missed (e.g. a crash between the append and the await).
  Future<void> _persistIncremental(AgentEvent event) async {
    if (event is! MessageEndEvent) return;
    final message = event.message;
    // Aborted assistant streams are incomplete; TTSR's discard mode prunes
    // them from memory and they should not survive in the session either.
    // EXCEPT backend agent mode (issue #155): a graceful SIGTERM cancel
    // must leave a resumable partial transcript on disk.
    if (message is AssistantMessage &&
        message.stopReason == StopReason.aborted &&
        !config.persistAbortedPartials) {
      return;
    }
    final session = _session;
    if (session == null) return;
    // Issue #437: a steered message merged at the step boundary carries
    // the SAME object the steering FIFO queued at accept — consume its
    // entry here (panel delivered + consumed marker), even if the append
    // below is skipped as already-counted.
    if (message is UserMessage && _pendingSteering.isNotEmpty) {
      final index = _pendingSteering.indexWhere(
        (entry) => identical(entry.message, message),
      );
      if (index >= 0) {
        final entry = _pendingSteering.removeAt(index);
        await _steeringDelivered(message, entry.recordId, entry.panel);
      }
    }
    final messages = _agent.state.messages;
    if (_persistedCount >= messages.length) return;
    final recordId = await session.appendMessage(message);
    _persistedCount++;
    if (message is UserMessage) {
      await _ingestObligations(message, recordId);
    }
  }

  /// Classifies a persisted real-user message into the obligations ledger
  /// and appends the snapshot (issue #1380 A1, rule-based v1 per Q1).
  /// Structured-engine sessions only — a classic session never grows
  /// ledger records, so its projection stays byte-identical (E3). The
  /// engine resolves through the live settings override first (#288 chain
  /// — the same expression the compaction driver uses). Persistence
  /// failures swallow: one missed classification must never break message
  /// persistence, and the writer's cumulative state rides the next
  /// successful snapshot.
  Future<void> _ingestObligations(UserMessage message, String recordId) async {
    if (_effectiveCompactionEngine() == CompactionEngine.classic) {
      return;
    }
    final session = _session;
    if (session == null) return;
    final writer = await _obligationsWriterFor(session);
    final payload = writer.ingest(
      text: userMessageText(message.content),
      sourceRecordId: recordId,
      at: message.timestamp,
    );
    if (payload == null) return;
    try {
      await session.appendCustomEntry(
        customType: obligationsLedgerRecordType,
        data: payload,
      );
    } on Object {
      // Swallowed deliberately (LedgerSnapshotDeduper protocol note): a
      // failed append must not poison every later write.
    }
  }

  /// The `obligation_mark_done` close path (issue #1380 lifecycle): marks
  /// an entry done/superseded and persists the snapshot. An empty [id] is
  /// the discovery mode — returns the open-obligation listing (ids,
  /// statuses, clipped quotes) without closing anything. Unlike the
  /// passive ingest above, failures are RETURNED — the agent must see
  /// that its close did not land.
  Future<String> closeObligation(String id, String status) async {
    final session = _session;
    if (session == null) return 'no session is open — the ledger is empty';
    final writer = await _obligationsWriterFor(session);
    if (id.isEmpty) {
      final open = writer.ledger.open;
      if (open.isEmpty) return 'no open obligations.';
      return [
        'open obligations (close with {"id": "..."}):',
        for (final e in open)
          '- ${e.id} [${e.kind.jsonName}] '
              '${capLedgerText(e.text) ?? ''}',
      ].join('\n');
    }
    final parsed = switch (status) {
      'done' => ObligationStatus.done,
      'superseded' => ObligationStatus.superseded,
      _ => null,
    };
    if (parsed == null) {
      return 'unknown status "$status" (use done or superseded)';
    }
    final payload = writer.markStatus(id, parsed);
    if (payload == null) {
      final ids = writer.ledger.entries.map((e) => e.id).toList();
      return 'no obligation carries id $id. Open ids: '
          '${ids.isEmpty ? "(none)" : ids.join(", ")}';
    }
    try {
      await session.appendCustomEntry(
        customType: obligationsLedgerRecordType,
        data: payload,
      );
    } on Object {
      return 'marking $id ${parsed.jsonName} failed — the snapshot did not '
          'persist; try again';
    }
    final openLeft = writer.ledger.open.length;
    return '$id marked ${parsed.jsonName}. '
        '$openLeft open obligation(s) remain.';
  }

  /// The writer for [session], rehydrated from its latest
  /// `obligations_ledger` snapshot via the RAW FILE SCAN — never the
  /// resident view: the latest snapshot routinely lies below a windowed
  /// tail, and a resident-view rehydration would let the next snapshot
  /// silently erase every entry under it (#488 class, review-blocking on
  /// this slice). Rebuilt lazily when the session switches.
  Future<ObligationsLedgerWriter> _obligationsWriterFor(
    Session session,
  ) async {
    final existing = _obligationsWriter;
    if (existing != null && identical(_obligationsWriterSession, session)) {
      return existing;
    }
    final ledger = await _latestObligationsFromScan(session);
    final writer = ObligationsLedgerWriter(initial: ledger);
    _obligationsWriterSession = session;
    return _obligationsWriter = writer;
  }

  /// The latest snapshot payload over the session's full file chain (the
  /// repo's streamed, rotation-aware scan), or an empty ledger.
  Future<ObligationsLedger> _latestObligationsFromScan(
    Session session,
  ) async {
    final repo = _repo;
    if (repo is! JsonlSessionRepo) return const ObligationsLedger([]);
    final records = await repo.readCustomRecordsOfType(
      await session.getMetadata(),
      {obligationsLedgerRecordType},
    );
    return records.isEmpty
        ? const ObligationsLedger([])
        : ObligationsLedger.fromPayload(records.last.data);
  }

  /// Handles a CodeMie auth-session expiry if [message] matches one. Returns
  /// `true` when the expiry was handled and the turn is finished.

  Future<void> _persistMessages() async {
    final session = _session;
    if (session == null) return;
    final messages = _agent.state.messages;
    for (final message in messages.skip(_persistedCount)) {
      await session.appendMessage(message);
    }
    _persistedCount = messages.length;
  }

  /// Persists a stuck-call liveness record (`tool_heartbeat` /
  /// `tool_stuck`, gh-1054) at the session leaf. Custom records stay out of
  /// model context — they are the session-visible audit trail external
  /// watchers (and post-mortems) read to distinguish alive-busy from dead.
  ///
  /// Free-text fields (the args summary, the stuck detail with its
  /// partial-output pointer) pass through the host's redaction pipeline
  /// first: the session JSONL is an audit surface and must not leak
  /// secrets the in-run hooks already mask elsewhere (gh-1054 review).
  Future<void> _persistToolLivenessRecord(
    String customType,
    Map<String, Object?> data,
  ) async {
    final session = _session;
    if (session == null) return;
    final pipeline = config.redactionPipeline;
    final safe = pipeline == null
        ? data
        : {
            for (final entry in data.entries)
              entry.key: entry.value is String
                  ? pipeline.redact(entry.value as String)
                  : entry.value,
          };
    await session.appendCustomEntry(customType: customType, data: safe);
  }

  /// The args summary for a liveness record: the command for shell calls,
  /// otherwise the truncated JSON of the arguments — the record must name
  /// WHAT was stuck without bloating the ledger.
  Object? _stuckArgsSummary(Map<String, dynamic> args) {
    const cap = 500;
    final command = args['command'];
    if (command is String) {
      return command.length > cap ? command.substring(0, cap) : command;
    }
    if (args.isEmpty) return null;
    final json = jsonEncode(args);
    return json.length > cap ? '${json.substring(0, cap)}…' : json;
  }

  /// Persists one in-memory [message] at the session leaf on demand (the
  /// checkpoint/rewind controller's sink), keeping [_persistedCount] aligned
  /// so the run-end batch persistence skips it. Returns the new record id.
  Future<String> _persistOneMessage(Message message) async {
    final session = _session;
    if (session == null) return '';
    final id = await session.appendMessage(message);
    _persistedCount++;
    return id;
  }

  /// Persists a TTSR injection at the session leaf (the TTSR controller's
  /// sink): the reminder as a hidden `ttsr-injection` custom message (it
  /// projects into context as a user message and survives compaction) plus a
  /// `ttsr_injection` record of the rule names for session restore. Bumps
  /// [_persistedCount] by one — the in-memory injection message then counts
  /// as persisted.
  Future<void> _persistTtsrInjection(
    String content,
    List<String> ruleNames,
  ) async {
    final session = _session;
    if (session == null) return;
    await session.appendCustomMessageEntry(
      customType: ttsrInjectionCustomType,
      content: content,
      display: false,
      details: {'rules': ruleNames},
    );
    await session.appendCustomEntry(
      customType: ttsrInjectionRecordType,
      data: {'rules': ruleNames},
    );
    _persistedCount++;
  }
}
