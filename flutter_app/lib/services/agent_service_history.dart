// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

part of 'agent_service.dart';

/// Windowed-history surface of [AgentService] (issue #135): the
/// [FaChatService] banner overrides, the paging/jump helpers behind
/// them, and their private view state. A MIXIN (not an extension) so
/// the `implements FaChatService` clause on [AgentService] is still
/// satisfied and subclass overrides keep working; the remaining state
/// it reads lives on the class (same library).
mixin AgentServiceHistory on ChangeNotifier {
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
    notifyListeners();
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
      notifyListeners();
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
      notifyListeners();
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
    notifyListeners();
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
    notifyListeners();
  }

  int? get historyAboveCount => _windowed == null ? 0 : _historyAboveCount;

  int? _historyAboveCount;

  Future<List<TrajectoryHiddenRecordPreview>> Function(
    TrajectoryCompactedRecord record,
  )?
  get resolveHiddenRecords {
    final reader = _windowed?.reader;
    if (reader == null) return null;
    return (record) async {
      final ids = record.hiddenRecordIds ?? const <String>[];
      if (ids.isEmpty) return const [];
      try {
        final resolved = await reader.readRecordsByIds(ids.toSet());
        return projectHiddenRecordPreviews(recordIds: ids, resolved: resolved);
      } on Object {
        return [
          for (final id in ids)
            TrajectoryHiddenRecordPreview(
              id: id,
              type: 'missing',
              preview: '[hidden: not captured for this session]',
            ),
        ];
      }
    };
  }

  bool _loadingHistory = false;

  bool get historyLoading => _loadingHistory;

  int? get historyTotalCount => _windowed?.cachedTotalRecords;

  bool get historyHasNewer => _windowed?.hasNewer ?? false;

  int? get historyBelowCount => _windowed?.countBelow;

  String? get historyLoadError => _historyLoadError;

  String? _historyLoadError;

  /// The VIEW branch (issue #135 round 2): every loaded branch record,
  /// root-first — what the transcript renders. Paging in either
  /// direction only grows/sets this list; the provider context
  /// ([_agent.state.messages]) is NEVER touched by paging (windowing
  /// is a view concern, not a context concern). `null` for full-open
  /// sessions (rows come straight from the loaded context).
  List<SessionRecord>? _viewBranch;

  Future<void> loadOlderHistory() async {
    if (_loadingHistory || isStreaming) return;
    final windowed = _windowed;
    if (windowed == null) return;
    final gen = _loadGeneration;
    _loadingHistory = true;
    notifyListeners();
    try {
      final joined = await windowed.loadOlder();
      if (gen != _loadGeneration) return;
      if (joined.isNotEmpty) {
        await _syncViewToWindow(windowed);
        await _applyViewBranch();
      }
      await _refreshHistoryAbove();
      if (gen != _loadGeneration) return;
      if (_historyLoadError != null) {
        _historyLoadError = null;
        notifyListeners();
      }
    } on Object catch (e) {
      _historyLoadError = e is StateError ? e.message : e.toString();
      notifyListeners();
    } finally {
      _loadingHistory = false;
      notifyListeners();
    }
  }

  Future<void> loadNewerHistory() async {
    if (_loadingHistory) return;
    final windowed = _windowed;
    if (windowed == null) return;
    // At-tail tap: nothing sits below — skip the rebuild and the
    // whole-file count re-scan entirely.
    if (!windowed.hasNewer) return;
    final gen = _loadGeneration;
    _loadingHistory = true;
    notifyListeners();
    try {
      await windowed.jumpToTail();
      if (gen != _loadGeneration) return;
      // Let an in-flight persist pass flush first so the branch read
      // below observes just-finalized records: a turn boundary landing
      // mid-jump must not leave its row stranded out of view until the
      // next reprojection (review -FbK vanish variant). Best effort —
      // a failed persist must not break the jump.
      if (_persistPass case final pass?) {
        try {
          await pass;
        } on Object {
          // Ignored: the next persist pass retries.
        }
        if (gen != _loadGeneration) return;
      }
      await _syncViewToWindow(windowed);
      if (gen != _loadGeneration) return;
      await _applyViewBranch();
      if (gen != _loadGeneration) return;
      // Live rows the projection cannot know — in-flight tool activity
      // tiles and the streaming assistant/thinking bubbles are plain
      // rows in [messages], not records yet. Re-read AFTER the rebuild
      // settles: capturing earlier races a mid-jump turn boundary into
      // re-appending a bubble the finalize already landed as a record —
      // a duplicate (review -FbK). There is no await between the rebuild
      // and this capture, so the fields are read atomically with the
      // projection snapshot. The contains-check and the empty-bubble
      // guard mirror _finalizeAssistant's own invariants.
      final liveRows = [
        ..._inFlightToolRows.map((e) => e.row),
        if (_currentThinkingMessage case final t?) t,
        if (_currentAssistantMessage case final a?
            when a.content.trim().isNotEmpty)
          a,
      ].where((row) => !messages.contains(row)).toList();
      messages.addAll(liveRows);
      await _refreshHistoryAbove();
      if (gen != _loadGeneration) return;
      _historyLoadError = null;
      notifyListeners();
    } on Object catch (e) {
      _historyLoadError = e is StateError ? e.message : e.toString();
      notifyListeners();
    } finally {
      _loadingHistory = false;
      notifyListeners();
    }
  }

  Future<bool> jumpToMessage(String messageId) async {
    final windowed = _windowed;
    if (windowed == null) {
      final index = _positionalRow(messageId);
      if (index == null) return _jumpLoadedRecord(messageId);
      return index >= 0 && index < messages.length;
    }
    if (!messageId.startsWith('msg-')) {
      return _jumpToRecord(windowed, messageId);
    }
    final index = _positionalRow(messageId);
    if (index == null) return false;
    if (_loadingHistory || isStreaming) return index < messages.length;
    final gen = _loadGeneration;
    _loadingHistory = true;
    notifyListeners();
    var reached = index < messages.length;
    try {
      for (var pass = 0; !reached && pass < 100 && windowed.hasOlder; pass++) {
        final joined = await windowed.loadOlder();
        if (joined.isEmpty || gen != _loadGeneration) break;
        await _syncViewToWindow(windowed);
        await _applyViewBranch();
        reached = index < messages.length;
      }
    } on Object catch (e) {
      _historyLoadError = e is StateError ? e.message : e.toString();
    } finally {
      _loadingHistory = false;
      notifyListeners();
    }
    return reached;
  }
}
