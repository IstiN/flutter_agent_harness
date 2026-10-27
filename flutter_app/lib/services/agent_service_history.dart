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
    // Full-open external reload — same stale-anchor reset as [loadSession]
    // (issue #1332): disk records still carry generation-time usage.
    final projected = resetLoadedUsageAnchors(context.messages);
    _agent.state.messages = projected;
    _persistedCount = projected.length;
    messages
      ..clear()
      ..addAll(projected.map(_toChatMessage));
    await _rebuildTrajectory();
    _notify();
  }

  /// Resolves one compacted row's hidden records (issue #385 F4): reads
  /// them by id from the session file and projects bounded previews; a
  /// failed read degrades EVERY id to an explicit "not captured"
  /// placeholder instead of erroring the drill-in.
  Future<List<TrajectoryHiddenRecordPreview>> _hiddenRecordsResolver(
    SessionChunkReader reader,
    TrajectoryCompactedRecord record,
  ) async {
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
  }

  /// History-page failure text for the banner: StateError messages are
  /// actionable (they carry the "why"), everything else stringifies.
  static String _historyErrorText(Object e) =>
      e is StateError ? e.message : e.toString();

  /// Pages the transcript back to the live tail (the body behind
  /// [AgentService.loadNewerHistory], issue #1159): jump-to-tail, flush
  /// the in-flight persist, reproject, re-append live rows, refresh the
  /// banner counts. Returns false — after surfacing the failure in
  /// [_historyLoadError] — when a step failed or the load generation
  /// moved mid-flight (stale work must never land); success clears any
  /// stale [_historyLoadError].
  Future<bool> _jumpNewerHistory(
    WindowedSessionStorage windowed,
    int gen,
  ) async {
    try {
      if (!await _jumpAndFlushPersist(windowed, gen)) return false;
      if (!await _applyJumpedTailView(windowed, gen)) return false;
      _historyLoadError = null;
      _notify();
      return true;
    } on Object catch (e) {
      _historyLoadError = _historyErrorText(e);
      _notify();
      return false;
    }
  }

  /// Jumps the window to the tail (one bounded read, no chunk crawl)
  /// and lets an in-flight persist pass flush first so the branch read
  /// below observes just-finalized records: a turn boundary landing
  /// mid-jump must not leave its row stranded out of view until the
  /// next reprojection (review -FbK vanish variant). Best effort — a
  /// failed persist must not break the jump. Returns false when the
  /// load generation moved mid-flight.
  Future<bool> _jumpAndFlushPersist(
    WindowedSessionStorage windowed,
    int gen,
  ) async {
    await windowed.jumpToTail();
    if (gen != _loadGeneration) return false;
    final pass = _persistPass;
    if (pass == null) return true;
    try {
      await pass;
    } on Object {
      // Ignored: the next persist pass retries.
    }
    return gen == _loadGeneration;
  }

  /// Re-centers the view on the jumped-to-tail window: reproject the
  /// view branch, re-append the live rows, refresh the banner counts.
  /// Returns false when the load generation moved mid-way (stale work
  /// must not land).
  Future<bool> _applyJumpedTailView(
    WindowedSessionStorage windowed,
    int gen,
  ) async {
    await _syncViewToWindow(windowed);
    if (gen != _loadGeneration) return false;
    await _applyViewBranch();
    if (gen != _loadGeneration) return false;
    // Live rows the projection cannot know — in-flight tool activity
    // tiles and the streaming assistant/thinking bubbles are plain rows
    // in [messages], not records yet. Re-read AFTER the rebuild
    // settles: capturing earlier races a mid-jump turn boundary into
    // re-appending a bubble the finalize already landed as a record —
    // a duplicate (review -FbK). There is no await between the rebuild
    // and this capture, so the fields are read atomically with the
    // projection snapshot. The contains-check and the empty-bubble
    // guard mirror _finalizeAssistant's own invariants.
    messages.addAll(_liveTranscriptRows().toList());
    await _refreshHistoryAbove();
    return gen == _loadGeneration;
  }

  /// Live rows the projection cannot know: in-flight tool activity
  /// tiles and the streaming assistant/thinking bubbles, minus rows
  /// already visible. The empty-bubble guard mirrors
  /// _finalizeAssistant's own invariant.
  Iterable<FahChatMessage> _liveTranscriptRows() {
    return [
      ..._inFlightToolRows.map((e) => e.row),
      if (_currentThinkingMessage case final t?) t,
      if (_currentAssistantMessage case final a?
          when a.content.trim().isNotEmpty)
        a,
    ].where((row) => !messages.contains(row));
  }

  /// Jump within a FULL-OPEN session (the windowed-null fallback of
  /// [AgentService.jumpToMessage]): positional row keys resolve against
  /// the loaded transcript bounds, record ids via the loaded-record
  /// lookup.
  Future<bool> _jumpLoadedTranscript(String messageId) async {
    final index = _positionalRow(messageId);
    if (index == null) return _jumpLoadedRecord(messageId);
    return index >= 0 && index < messages.length;
  }

  /// Positional `msg-<index>` jump with history paging (issue #135 AC6,
  /// the `msg-` branch of [AgentService.jumpToMessage]): pages older
  /// history in until the target row is loaded. Mid-run taps
  /// ([_loadingHistory]/isStreaming) resolve against what is already
  /// loaded instead of paging.
  Future<bool> _jumpPositional(
    WindowedSessionStorage windowed,
    String messageId,
  ) async {
    final index = _positionalRow(messageId);
    if (index == null) return false;
    if (_loadingHistory || isStreaming) return index < messages.length;
    return _pageUntilRowVisible(windowed, index);
  }

  /// Runs the bounded page-older crawl with the history-banner error
  /// bookkeeping (a failed page surfaces in [_historyLoadError]).
  Future<bool> _pageUntilRowVisible(
    WindowedSessionStorage windowed,
    int index,
  ) async {
    final gen = _loadGeneration;
    _loadingHistory = true;
    _notify();
    try {
      return await _crawlOlderForRow(windowed, gen, index);
    } on Object catch (e) {
      _historyLoadError = _historyErrorText(e);
      // Messages still reflect the last successful page-in (a page-in
      // and its visibility update have no await between them), so the
      // visibility answer is the crawl's own partial result.
      return index < messages.length;
    } finally {
      _loadingHistory = false;
      _notify();
    }
  }

  /// The bounded page-older crawl: up to 100 passes, until history runs
  /// out or the load generation moves (stale work must not land).
  Future<bool> _crawlOlderForRow(
    WindowedSessionStorage windowed,
    int gen,
    int index,
  ) async {
    var reached = index < messages.length;
    for (var pass = 0; !reached && pass < 100 && windowed.hasOlder; pass++) {
      final joined = await windowed.loadOlder();
      if (_olderPageSpent(joined, gen)) break;
      await _syncViewToWindow(windowed);
      await _applyViewBranch();
      reached = index < messages.length;
    }
    return reached;
  }

  /// Whether the crawl must stop: history ended (an empty join) or a
  /// newer load owns the state.
  bool _olderPageSpent(List<dynamic> joined, int gen) =>
      joined.isEmpty || gen != _loadGeneration;
}
