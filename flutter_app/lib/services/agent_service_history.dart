// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

part of 'agent_service.dart';

/// Windowed-history internals of [AgentService] (issue #135): the
/// paging/jump/view helpers BEHIND the [FaChatService] history
/// surface. The `@override` banner members themselves stay on the
/// class — an `implements` clause is satisfied only by real class
/// members — these helpers share its private state (same library).
extension AgentServiceHistory on AgentService {
  /// The windowed storage when the open session was opened windowed
  /// (issue #135); null for full-open sessions — no paging surface.
  WindowedSessionStorage? get _windowed {
    final storage = _session?.getStorage();
    return storage is WindowedSessionStorage ? storage : null;
  }

  /// Re-syncs the VIEW branch to the storage's CURRENT resident branch
  /// (issue #135 round 4, end-to-end memory bound): the view never
  /// re-accumulates records the residency cap evicted — transcript and
  /// ledger stay bounded by the same cache the storage enforces. The
  /// banners re-derive "more above/below" from the storage counts.
  Future<void> _syncViewToWindow(WindowedSessionStorage windowed) async {
    final branch = await windowed.currentBranch();
    if (branch.isNotEmpty) _viewBranch = branch;
  }

  int? _positionalRow(String messageId) {
    final index = int.tryParse(messageId.replaceFirst('msg-', ''));
    return index == null || index < 0 ? null : index;
  }

  /// A record-id jump on a FULL-OPEN session (the windowed-open
  /// fallback, issue #197 defect 4): everything is already loaded, so
  /// the jump is a scroll — resolve the record's transcript row and
  /// hand it to the scroll surface. `false` on an unknown record or one
  /// that projects no row. Fallback-open sessions are small by
  /// definition (that is why the full open won), so the prefix
  /// projection that finds the row costs nothing.
  Future<bool> _jumpLoadedRecord(String recordId) async {
    final session = _session;
    if (session == null) return false;
    try {
      final branch = await session.getBranch();
      final pos = branch.indexWhere((record) => record.id == recordId);
      if (pos < 0) return false;
      final index =
          session.projectPath(branch.take(pos + 1).toList()).length - 1;
      if (index < 0) return false;
      scrollToMessageHandler?.call('msg-$index');
      return true;
    } on Object {
      return false;
    }
  }

  /// The AC6 byte-offset seek: hit id → window re-center → view sync.
  Future<bool> _jumpToRecord(
    WindowedSessionStorage windowed,
    String recordId,
  ) async {
    if (_loadingHistory || isStreaming) return false;
    final gen = _loadGeneration;
    _loadingHistory = true;
    _notify();
    try {
      final branch = await windowed.jumpToRecord(recordId);
      if (branch.isEmpty || gen != _loadGeneration) return false;
      await _syncViewToWindow(windowed);
      await _applyViewBranch();
      if (gen != _loadGeneration) return false;
      await _refreshHistoryAbove();
      if (gen != _loadGeneration) return false;
      _historyLoadError = null;
      return true;
    } on Object catch (e) {
      _historyLoadError = e is StateError ? e.message : e.toString();
      return false;
    } finally {
      _loadingHistory = false;
      _notify();
    }
  }

  /// Recomputes [historyAboveCount] from the window's own above-count
  /// (maintained incrementally by the storage; `null` = unknown — right
  /// after a jump until an edge is walked). Also lands the total record
  /// count (the terminal banner's N) through the same lazy memo.
  Future<void> _refreshHistoryAbove() async {
    final windowed = _windowed;
    if (windowed == null) return;
    final gen = _loadGeneration;
    // Best-effort: this runs unawaited (background banner count), so a
    // read failure here would escape as an unhandled zone error. A
    // failed count just leaves the count null - the banner renders
    // without the number.
    final int? count;
    try {
      count = await windowed.countAbove();
    } on Object {
      return;
    }
    if (gen != _loadGeneration) return;
    if (_historyAboveCount != count || windowed.cachedTotalRecords != null) {
      _historyAboveCount = count;
      _notify();
    }
  }

  /// Rebuilds the visible transcript rows and the trajectory ledger
  /// from the VIEW branch (paging changes the view, never the provider
  /// context). Dynamic-message markers splice at [loadSession] only —
  /// widget records deep in paged history are rare enough that
  /// re-adopting the branch per page-in costs more than it buys.
  Future<void> _applyViewBranch() async {
    final session = _session;
    final branch = _viewBranch;
    if (session == null || branch == null) return;
    final projected = session.projectPath(branch);
    messages
      ..clear()
      ..addAll(projected.map(_toChatMessage));
    await _rebuildTrajectory(records: branch);
    _notify();
  }

  /// Rebuilds the agent context, the visible transcript, and the ledger
  /// from [session]'s active branch as currently loaded. Everything
  /// loaded is by definition already on disk, so the persist cursor rides
  /// to the full length (nothing re-appends on the next persist).
  Future<void> _reprojectLoadedWindow(Session session) async {
    final context = await session.buildContext();
    _agent.state.messages = context.messages;
    _persistedCount = context.messages.length;
    messages
      ..clear()
      ..addAll(context.messages.map(_toChatMessage));
    await _rebuildTrajectory();
    _notify();
  }
}
