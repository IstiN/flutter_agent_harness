// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

part of 'agent_service.dart';

/// Crash-safe persistence + idle-watchdog internals of [AgentService]
/// (library-private; the state fields they drive stay on the class).
extension AgentServicePersistence on AgentService {
  void _armIdleWatchdog() {
    _idleWatchdog?.cancel();
    _idleWatchdog = Timer(_responseTimeout, () {
      if (_activeToolCalls > 0) return; // a long tool is still running
      if (!isStreaming) return; // run already completed — no false positive
      abort();
      isStreaming = false;
      error =
          'The model stopped responding for '
          '${_responseTimeout.inSeconds} seconds.';
      notifyListeners();
    });
  }

  /// Crash-safe persistence: append finished messages/tool results to the
  /// session file AS THEY LAND (serialized through [_persistChain]), so a
  /// crash mid-run loses nothing the agent already produced — persisting
  /// only on AgentEnd (the old behavior) lost the whole turn, tool calls
  /// included, when the app died mid-run. Torn trailing writes from a crash
  /// mid-append self-heal on the next load (the JSONL storage truncates
  /// them).
  void _persistSoon() {
    // Our own appends grow the file — re-arm the external watcher's
    // baseline so our writes don't trigger an external reload.
    unawaited(() async {
      final file = _sessionFile;
      if (file == null) return;
      final info = (await env.fileInfo(file)).valueOrNull;
      if (info != null) _sessionWatchBytes = info.size;
    }());
    _persistChain = _persistChain.then((_) => _persist()).catchError((
      Object _,
    ) {
      // Best effort: the transcript stays in memory; the next trigger
      // retries the missed appends (see _persistedCount).
    });
  }

  Future<void> _persist() async {
    if (_persistRunning) return;
    _persistRunning = true;
    try {
      await _persistUnchecked();
    } finally {
      _persistRunning = false;
    }
  }

  Future<void> _persistUnchecked() async {
    // The session is created lazily on the first persisted message — no
    // JSONL file appears until the user actually writes something.
    await _materialiseSessionIfNeeded();
    final session = _session;
    if (session == null) return;
    final all = _agent.state.messages;
    for (final message in all.skip(_persistedCount)) {
      // A captured summary must sit on the chain AFTER the turn's user
      // message (else it roots itself off the turn) and BEFORE the assistant
      // message its request produced — the replay walk derives the step
      // from exactly that neighborhood.
      if (message is AssistantMessage) {
        await _flushRequestSummaries(session);
      }
      final id = await session.appendMessage(message);
      // The finalized record replaces the streamed synthetic rows in the
      // trajectory ledger (builder keys them by turn/step).
      final record = await session.getEntry(id);
      if (record != null) {
        _trajectory.append(record);
        // The view branch accumulates own-run records too — a rebuild
        // while deep-paged must not drop the tail rows the user just
        // watched stream in (issue #135 round 2).
        _viewBranch?.add(record);
      }
    }
    // Leftovers (a run aborted before its assistant reply) flush at the
    // tail; the next assistant step re-attaches them or they stay an
    // inert orphan.
    await _flushRequestSummaries(session);
    // Presented dynamic messages persist right after the messages that
    // carried them (the replay walk inserts each marker by counting the
    // message records ahead of it on the chain).
    await _flushDynamicWidgets(session);
    _persistedCount = all.length;
  }
}
