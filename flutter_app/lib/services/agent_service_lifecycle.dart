// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

part of 'agent_service.dart';

/// Session-lifecycle internals of [AgentService]: the error clearing,
/// the service teardown behind [AgentService.dispose] (everything but
/// the `super.dispose()` call, which must stay on the class — an
/// extension has no super), the trajectory-ledger rebuild, and the
/// dynamic-widget / request-capture record flushes that ride the
/// persist pass. The state fields they drive stay on the class (same
/// library).
extension AgentServiceLifecycle on AgentService {
  void _clearError() {
    if (error != null) {
      error = null;
      _notify();
    }
  }

  String _shortArgs(Map<String, dynamic> args) {
    final encoded = jsonEncode(args);
    if (encoded.length <= 80) return encoded;
    return '${encoded.substring(0, 80)}...';
  }

  /// Persists presented dynamic messages as `dynamic_widget` custom
  /// records (the replay source; see [DynamicMessagesService.adoptBranch]).
  Future<void> _flushDynamicWidgets(Session session) async {
    for (final data in dynamicMessages.drainRecordPayloads()) {
      await session.appendCustomEntry(
        customType: DynamicMessagesService.recordType,
        data: data,
      );
    }
  }

  /// Writes every buffered request-capture record as context-omitted
  /// CustomRecords, in chain order (blobs first, summary last — the replay
  /// walk expects the summary as the step's predecessor). // ponytail: N
  /// buffered requests flush as one batch — the replay walk keys by chain
  /// position, so a throttled multi-request burst can coalesce onto one
  /// step; per-request keys if that matters.
  Future<void> _flushRequestSummaries(Session session) async {
    if (_pendingRequestRecords.isEmpty) return;
    final pending = List.of(_pendingRequestRecords);
    _pendingRequestRecords.clear();
    for (final (:customType, :data) in pending) {
      if (customType == _pendingModelChangeMarker) {
        // Issue #440: the System row for this request-context version —
        // a real ModelChangeRecord through the same session API the
        // model-switch flow uses, so replay projects the row the
        // following summary stamps (F7a). Never a custom record.
        await session.appendModelChange(
          provider: _agent.state.model.provider,
          modelId: _agent.state.model.id,
        );
        continue;
      }
      await session.appendCustomEntry(customType: customType, data: data);
    }
  }

  /// Rebuilds the trajectory ledger from the active session branch
  /// (session open/switch/external reload); windowed callers pass the
  /// VIEW branch so paged-in history feeds the ledger without a storage
  /// walk.
  Future<void> _rebuildTrajectory({List<SessionRecord>? records}) async {
    final session = _session;
    if (session == null) return;
    final gen = _loadGeneration;
    _trajectory.reset();
    final sw = Stopwatch()..start();
    final branch = records ?? await session.getBranch();
    if (gen != _loadGeneration || !identical(session, _session)) return;
    // One bulk snapshot (issue #262): the whole backfill is synchronous
    // O(n) work — no intermediate snapshots exist to render, and the old
    // per-append materialization was the O(n²) open stall. With no awaits
    // inside, the fold is atomic for the event loop: a generation bump or
    // session swap lands either fully before or fully after it (the #199
    // E1 guard, now checked around the single synchronous block).
    _trajectory.appendAll(branch);
    AppLog.i(
      'trajectory',
      'backfill: ${branch.length} records, '
          '${_trajectory.latest.records.length} rows in '
          '${sw.elapsedMilliseconds}ms',
    );
  }

  TrajectoryBlobPersister _trajectoryBlobPersisterFor() {
    final session = _session;
    final existing = _trajectoryBlobPersister;
    // Same session (or the session materialised after the first capture
    // — the null→real transition must ADOPT, not reset: the seen-hash
    // state implements the #385 blob dedup and the #440 model-change
    // dedup, and wiping it once per session re-persisted known blobs and
    // appended a second model_change for an unchanged version).
    if (existing != null &&
        (_trajectoryBlobPersisterSession == null ||
            identical(_trajectoryBlobPersisterSession, session))) {
      _trajectoryBlobPersisterSession = session;
      return existing;
    }
    final persister = TrajectoryBlobPersister(
      redactText: _redactionPipeline?.redact,
    );
    _trajectoryBlobPersister = persister;
    _trajectoryBlobPersisterSession = session;
    return persister;
  }

  /// Whether a provider add/connect flow is latched (gh-1044 I1/AC6).
  bool get providerAddFlowInProgress => _providerAddFlowDepth > 0;

  /// Whether a `reconfigure` from outside an add-provider flow is
  /// currently refused (the gh-1044 I1 latch): shared by the base
  /// [reconfigure] and subclass overrides (the extension relay) so the
  /// refusal rule exists in exactly one shape.
  bool reconfigureRefusedByAddFlow(bool fromProviderAddFlow) =>
      _providerAddFlowDepth > 0 && !fromProviderAddFlow;

  /// Marks a provider add/connect flow start (see [reconfigure]'s
  /// `fromProviderAddFlow`).
  void beginProviderAddFlow() => _providerAddFlowDepth++;

  /// Marks a provider add/connect flow end.
  void endProviderAddFlow() {
    if (_providerAddFlowDepth > 0) _providerAddFlowDepth--;
  }

  /// The service teardown behind [AgentService.dispose]: everything
  /// except the `super.dispose()` call, which must stay on the class
  /// (an extension has no super). Extracted with the rest of the
  /// lifecycle internals so the main file stays under the line cap.
  void _disposeService() {
    if (identical(AgentService.maybeCurrent, this))
      AgentService.maybeCurrent = null;
    _disposed = true;
    // Drop the sleep-prevention assertion (issue #325): best-effort and
    // fire-and-forget — dispose stays synchronous.
    unawaited(powerAssertion?.release());
    // Disposing the service cancels an in-flight run: the agent's idle
    // watchdog would otherwise outlive the host by minutes (and wedge
    // widget tests' fake_async invariants on a pending timer).
    _agent.abort();
    _agentNetwork?.dispose();
    _compactExpand?.dispose();
    if (_subagentManager != null) _scheduledMessages.dispose();
    _inboxWatchTimer?.cancel();
    unawaited(_taskCompletionsSub?.cancel());
    _idleWatchdog?.cancel();
    _liveActivityEndTimer?.cancel();
    _sessionWatchTimer?.cancel();
    fsRevision.dispose();
    externalSessionRevision.dispose();
    _trajectory.dispose();
    dynamicMessages.dispose();
  }
}
