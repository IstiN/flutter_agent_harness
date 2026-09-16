// ignore_for_file: prefer_initializing_formals
/// Persisted delayed messages ("send myself a note on a timer").
///
/// `schedule_message` writes a pending JSON record under
/// `<messagesRoot>/_scheduled/`; a timer delivers due records into the
/// recipient's inbox as normal agent mail, where the existing idle-wake
/// turns the recipient on. Pending files are the source of truth — the
/// scheduler survives restarts (a fresh instance re-arms overdue records
/// on start), so both the CLI and the Flutter app get identical behavior
/// from this one component.
library;

import 'dart:async';
import 'dart:convert';

import '../env/execution_env.dart';
import 'agent_message.dart';
import 'messaging_repository.dart';

final class ScheduledMessageQueue {
  ScheduledMessageQueue({
    required ExecutionEnv env,
    required MessagingRepository Function() repo,
    required String Function() root,
    String Function()? selfMailbox,
    String Function()? ownerPrefix,
    DateTime Function()? clock,
    this.onScheduled,
    this.onFired,
    this.onError,
    this.failureBackoff = maxTimerLeg,
  }) : _env = env,
       _repo = repo,
       _selfMailbox = selfMailbox,
       _ownerPrefix = ownerPrefix,
       _clock = clock,
       _root = root;

  final ExecutionEnv _env;
  final MessagingRepository Function() _repo;
  final String Function() _root;

  /// The scheduling agent's own mailbox (e.g. `<sessionId>/main`). Records
  /// without an explicit `to` default here, and `from` too — a missing
  /// self mailbox stored the literal string 'self', delivering reminders
  /// into a phantom mailbox nobody drains (lost production mail).
  final String Function()? _selfMailbox;

  /// This instance's mailbox prefix (the session id), captured live. Stored
  /// on every record as `owner` at schedule time: a sweeper may re-address
  /// a self-addressed record to its LIVE mailbox only when the stored owner
  /// matches its own prefix — a differing owner means another live instance
  /// scheduled it, and the record is left for its owner.
  final String Function()? _ownerPrefix;

  /// Injectable wall clock (issue #259): scheduling and due comparisons
  /// must ride one wall-clock source so a fake clock can simulate system
  /// sleep in tests, and so every due check recomputes from the CURRENT
  /// wall time instead of trusting duration-based timer state. Defaults
  /// to [DateTime.now]; pure Dart, no dart:io.
  final DateTime Function()? _clock;

  DateTime _now() => _clock?.call() ?? DateTime.now();

  /// Host-visible notice when a record is scheduled ('in 25m: `<text>`').
  final void Function(String text)? onScheduled;

  /// Host-visible notice when a record fires ('fired: `<text>`').
  final void Function(String text)? onFired;

  /// Host-visible notice when a delivery fails (issue #270).
  final void Function(String text)? onError;

  /// Wait before retrying a pass that just failed (issue #270).
  final Duration failureBackoff;

  String _self() => _selfMailbox?.call() ?? 'self';

  /// Whether this instance may consume a self-addressed record: the stored
  /// owner prefix is empty (legacy, pre-tagging) or matches this instance's
  /// live prefix. A differing owner belongs to another live instance.
  bool _owns(String owner) =>
      owner.isEmpty || owner == (_ownerPrefix?.call() ?? '');

  /// Compact human delay: 90s / 25m / 2h / 1d.
  static String formatDelay(Duration d) {
    if (d.inDays >= 1) return '${d.inDays}d';
    if (d.inHours >= 1) return '${d.inHours}h';
    if (d.inMinutes >= 1) return '${d.inMinutes}m';
    if (d.inSeconds >= 1) return '${d.inSeconds}s';
    return '${d.inMilliseconds}ms';
  }

  String get _dir => '${_root()}/_scheduled';

  /// The root pending records were last scanned under: a live-root change
  /// (session-cwd adoption) carries over what we may consume before the
  /// next scan.
  String? _lastScanRoot;

  /// The live `_scheduled/` dir, migrating records across a root change
  /// first. Only THIS instance's records ([_owns] — the live prefix is
  /// already the adopted session's) are carried: dragging foreign records
  /// across a root change steals them from their owner's sweeps on the old
  /// root, the move-based form of the issue #59 theft. Unreadable sources
  /// stay put. Copy-then-remove leaves a crash window that can
  /// double-deliver — the same window every send+remove sweep here already
  /// has; the file inbox has no id dedup, accepted at this layer.
  Future<String> _pendingDir() async {
    final root = _root();
    final previous = _lastScanRoot;
    _lastScanRoot = root;
    if (previous == null || previous == root) return _dir;
    final from = '$previous/_scheduled';
    final entries = (await _env.listDir(from)).valueOrNull ?? const [];
    for (final entry in entries) {
      if (entry.kind == FileKind.directory || !entry.path.endsWith('.json')) {
        continue;
      }
      final path = entry.path.contains('/')
          ? entry.path
          : '$from/${entry.path}';
      final text = (await _env.readTextFile(path)).valueOrNull;
      if (text == null) continue;
      final record = _parseRecord(text);
      if (record == null || !_owns(record['owner'] as String? ?? '')) {
        continue;
      }
      final name = path.split('/').last;
      try {
        (await _env.writeFile('$_dir/$name', text)).getOrThrow();
      } on Object {
        continue; // unwritable target — leave in the old root
      }
      await _env.remove(path, force: true);
    }
    return _dir;
  }

  Timer? _timer;

  /// Persists a delayed message and arms the timer. Returns the record id.
  Future<String> schedule({
    required String text,
    required Duration delay,
    String? to,
    String? from,
  }) async {
    final id = newMessageId();
    final record = {
      'id': id,
      'dueMs': _now().millisecondsSinceEpoch + delay.inMilliseconds,
      'to': to ?? _self(),
      'from': from ?? _self(),
      'text': text,
      'owner': _ownerPrefix?.call() ?? '',
    };
    (await _env.createDir(_dir)).getOrThrow();
    (await _env.writeFile('$_dir/$id.json', jsonEncode(record))).getOrThrow();
    _arm();
    onScheduled?.call('in ${formatDelay(delay)}: $text');
    return id;
  }

  /// Scans pending records and arms the nearest-due timer. Safe to call
  /// repeatedly (idempotent re-arm). Best-effort like mailbox registration:
  /// an unwritable messages root disables scheduling instead of crashing
  /// startup.
  Future<void> start() async {
    try {
      (await _env.createDir(_dir)).getOrThrow();
    } on Object {
      return;
    }
    await _migrateLegacySelfMailbox();
    try {
      await _deliverDue();
    } on Object catch (e) {
      // Individual delivery failures must not kill the fire-and-forget
      // starter; the next start()/timer tick retries.
      onError?.call('startup sweep failed: $e');
    }
    _arm();
  }

  /// Set by [dispose]: an in-flight re-arm must not arm a timer after the
  /// host tore the queue down (the orphaned timer would deliver into the
  /// dead session's mailbox — the stranded-reminder bug).
  bool _disposed = false;

  /// Cancels the armed delivery timer (host teardown) and releases
  /// ownership of my pending self-addressed records (their `owner` tag is
  /// cleared, fire-and-forget): a torn-down session is DEAD, and #59's
  /// contract is that a fresh session taking over adopts its reminders —
  /// while #88's anti-theft tagging protects only LIVE foreign owners.
  /// Pending record files stay put either way — they are the source of
  /// truth; a later [start] (host restart, session switch) re-arms and
  /// delivers them.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    unawaited(_releaseOwnedRecords());
  }

  /// Clears the `owner` tag on my pending self-addressed records so the
  /// next session's queue adopts them via the legacy (ownerless) path.
  /// Foreign-owned and non-self-addressed records are never touched.
  Future<void> _releaseOwnedRecords() async {
    final mine = _ownerPrefix?.call() ?? '';
    if (mine.isEmpty) return;
    final dir = _dir;
    final entries = (await _env.listDir(dir)).valueOrNull ?? const [];
    for (final entry in entries) {
      if (entry.kind == FileKind.directory || !entry.path.endsWith('.json')) {
        continue;
      }
      final path = entry.path.contains('/') ? entry.path : '$dir/${entry.path}';
      final record = await _readRecord(path);
      if (record == null) continue;
      if (record['owner'] != mine) continue;
      final to = record['to'] as String? ?? '';
      if (to != (record['from'] as String? ?? '')) continue; // not self-mail
      record['owner'] = '';
      try {
        (await _env.writeFile(path, jsonEncode(record))).getOrThrow();
      } on Object {
        // Best-effort: the record stays owned — a same-owner restart
        // still delivers it.
      }
    }
  }

  /// One-time repair: pre-fix builds delivered self-scheduled mail into a
  /// literal `<root>/self` mailbox nobody drains. Move those into the real
  /// self mailbox (ids rewritten from 'self') so the reminders resurface.
  Future<void> _migrateLegacySelfMailbox() async {
    final self = _self();
    if (self == 'self') return;
    final legacyDir = '${_root()}/self/inbox';
    final entries = (await _env.listDir(legacyDir)).valueOrNull ?? const [];
    for (final entry in entries) {
      if (entry.kind == FileKind.directory || !entry.path.endsWith('.json')) {
        continue;
      }
      final path = entry.path.contains('/')
          ? entry.path
          : '$legacyDir/${entry.path}';
      final text = (await _env.readTextFile(path)).valueOrNull;
      if (text == null) continue;
      final Map<String, dynamic> json;
      try {
        final decoded = jsonDecode(text);
        if (decoded is! Map<String, dynamic>) continue; // wrong shape
        json = decoded;
      } on FormatException {
        continue;
      }
      String fix(dynamic id) => id == 'self' ? self : (id as String? ?? self);
      await _repo().send(
        AgentMessage(
          id: json['id'] as String? ?? newMessageId(),
          fromId: fix(json['fromId']),
          toId: fix(json['toId']),
          text: json['text'] as String? ?? '',
          sentAt: json['sentAt'] as String? ?? _now().toUtc().toIso8601String(),
          hops: json['hops'] as int? ?? 0,
        ),
      );
      await _env.remove(path, force: true);
    }
  }

  /// Delivers every due record. Returns how many were delivered.
  Future<int> deliverDue() => _deliverDue();

  /// The pending records this instance can still deliver: how many, and
  /// the earliest due time (epoch ms; null: none). Same deliverability
  /// rule as the timer — foreign-owned self-addressed records are not
  /// ours to fire, so they are not ours to show either. Powers the CLI's
  /// scheduled-follow-ups indicator (issue #115).
  Future<({int count, int? nextDueMs})> pendingSummary() async {
    final records = await pendingRecords();
    int? nearest;
    for (final record in records) {
      final due = record.dueMs;
      if (due != null && (nearest == null || due < nearest)) nearest = due;
    }
    return (count: records.length, nextDueMs: nearest);
  }

  /// Every deliverable pending record with its due time (epoch ms, null
  /// when unknown) and text preview — the raw view behind [pendingSummary]
  /// and the CLI's visible-waiting row (issue #450). Same deliverability
  /// rule as the timer: foreign-owned self-addressed records are not ours
  /// to fire, so they are not ours to show either. Corrupt records arm no
  /// timer and light no indicator.
  Future<List<({int? dueMs, String text})>> pendingRecords() async {
    final dir = await _pendingDir();
    final entries = (await _env.listDir(dir)).valueOrNull ?? const [];
    final records = <({int? dueMs, String text})>[];
    for (final entry in entries) {
      if (!entry.path.endsWith('.json')) continue;
      final path = entry.path.contains('/') ? entry.path : '$dir/${entry.path}';
      final record = await _readRecord(path);
      if (record == null || _deliveryTarget(record) == null) continue;
      records.add((
        dueMs: record['dueMs'] as int?,
        text: record['text'] as String? ?? '',
      ));
    }
    return records;
  }

  /// In-flight delivery guard: a timer tick landing while [deliverDue] is
  /// still running must not send the same record twice (the file inbox has
  /// no id dedup). The skipped tick is re-armed right after.
  bool _delivering = false;

  /// Set by a delivery pass that saw at least one failed send (issue
  /// #270): the re-arm that follows floors the leg at [failureBackoff]
  /// instead of 0 — a persistently failing record would otherwise re-arm
  /// a zero-delay timer in a tight loop. Reset at each pass start.
  bool _passHadFailure = false;

  Future<int> _deliverDue() async {
    if (_delivering) return 0;
    _delivering = true;
    try {
      return await _deliverDueInner();
    } finally {
      _delivering = false;
    }
  }

  /// Reads and tolerantly parses one `_scheduled/` record file: null for an
  /// unreadable file, malformed json, or valid json that is not a Map — one
  /// corrupt record must never crash a delivery/arming pass (issue #59).
  Future<Map<String, dynamic>?> _readRecord(String path) async {
    final text = (await _env.readTextFile(path)).valueOrNull;
    if (text == null) return null;
    return _parseRecord(text);
  }

  Map<String, dynamic>? _parseRecord(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null; // torn write — leave for inspection
    }
  }

  /// The live mailbox a due record delivers to (null: skip it).
  ///
  /// Self-addressed records ride the LIVE self mailbox: the recorded
  /// address was pinned at schedule time, but hosts re-address mailboxes
  /// (session switch, app restart, service recreate) — the stale address
  /// strands the reminder in a mailbox nobody drains while the tool
  /// already reported success (the lost-schedule bug). The live re-address
  /// happens only when this instance scheduled the record ([_owns]):
  /// re-addressing a foreign-owned record here steals the reminder into
  /// the wrong mailbox and deletes the file (cross-instance self-theft —
  /// issue #59), so those return null and stay with their owner.
  String? _deliveryTarget(Map<String, dynamic> record) {
    final recordedTo = record['to'] as String? ?? _self();
    final from = record['from'] as String? ?? recordedTo;
    if (recordedTo != from) return recordedTo;
    if (!_owns(record['owner'] as String? ?? '')) return null;
    final self = _self();
    return (self != 'self' && self.isNotEmpty) ? self : recordedTo;
  }

  Future<int> _deliverDueInner() async {
    final dir = await _pendingDir();
    final entries = (await _env.listDir(dir)).valueOrNull ?? const [];
    final dueRecords =
        <({String path, Map<String, dynamic> record, String to})>[];
    for (final entry in entries) {
      if (entry.kind == FileKind.directory || !entry.path.endsWith('.json')) {
        continue;
      }
      // listDir implementations differ on absolute vs bare names.
      final path = entry.path.contains('/') ? entry.path : '$dir/${entry.path}';
      final record = await _readRecord(path);
      if (record == null) continue;
      final dueMs = record['dueMs'] as int?;
      if (dueMs == null || dueMs > _now().millisecondsSinceEpoch) {
        continue; // not a schedule record, or not due yet
      }
      final to = _deliveryTarget(record);
      if (to == null) continue;
      dueRecords.add((path: path, record: record, to: to));
    }
    // Deliver in due-time order, not directory order (issue #270): the
    // oldest reminder fires first no matter which file listDir saw first.
    dueRecords.sort(
      (a, b) => (a.record['dueMs'] as int).compareTo(b.record['dueMs'] as int),
    );
    var delivered = 0;
    _passHadFailure = false;
    for (final (:path, :record, :to) in dueRecords) {
      final from =
          record['from'] as String? ?? record['to'] as String? ?? _self();
      try {
        await _repo().send(
          AgentMessage(
            id: record['id'] as String? ?? newMessageId(),
            fromId: from,
            toId: to,
            text: '[scheduled] ${record['text'] ?? ''}',
            sentAt: _now().toUtc().toIso8601String(),
            hops: 0,
          ),
        );
        await _env.remove(path, force: true);
        delivered++;
        onFired?.call('fired: ${record['text'] ?? ''}');
      } on Object catch (e) {
        // Failure isolation (issue #270): one throwing send must not kill
        // the sweep, its sweep-mates, or the timer heartbeat — log it and
        // keep the record on disk (remove only ever runs after a
        // successful send); the next sweep/tick retries it.
        _passHadFailure = true;
        onError?.call(
          'delivery failed (${record['id'] ?? '?'}): $e — '
          'record kept for the next sweep',
        );
      }
    }
    return delivered;
  }

  void _arm() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _armAsync();
  }

  /// Scans the pending records for the earliest due time (null: none).
  Future<int?> _nearestDueMs() async => (await pendingSummary()).nextDueMs;

  /// The longest single timer leg (issue #259). A one-shot timer armed for
  /// the full wait freezes with OS sleep (monotonic clocks pause while the
  /// lid is closed) and fires late by the slept duration. Capping each leg
  /// turns long waits into a lightweight idle heartbeat: every leg's fire
  /// recomputes the remaining delay from the WALL clock ([_now]) — never
  /// accumulating duration-based drift — so the first post-sleep fire
  /// immediately sees and delivers every overdue record.
  static const Duration maxTimerLeg = Duration(seconds: 60);

  Future<void> _armAsync() async {
    if (_disposed) return;
    final nearest = await _nearestDueMs();
    // The scan awaited above; the host may have torn the queue down meanwhile.
    if (_disposed || nearest == null) return;
    final wait = nearest - _now().millisecondsSinceEpoch;
    var leg = wait.clamp(0, 1 << 40);
    if (leg > maxTimerLeg.inMilliseconds) leg = maxTimerLeg.inMilliseconds;
    final floor = _passHadFailure ? failureBackoff.inMilliseconds : 0;
    if (leg < floor) leg = floor;
    _timer = Timer(Duration(milliseconds: leg), () async {
      try {
        await _deliverDue();
      } on Object catch (e) {
        // A throw escaping this callback would skip the _arm() below —
        // the whole heartbeat chain silently dies until the next
        // turn-start sweep (issue #270). Contain it and re-arm.
        _passHadFailure = true;
        onError?.call('delivery pass failed: $e');
      }
      _arm();
    });
  }
}
