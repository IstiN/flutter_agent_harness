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
    this.onScheduled,
    this.onFired,
  }) : _env = env,
       _repo = repo,
       _selfMailbox = selfMailbox,
       _ownerPrefix = ownerPrefix,
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

  /// Host-visible notice when a record is scheduled ('in 25m: <text>').
  final void Function(String text)? onScheduled;

  /// Host-visible notice when a record fires ('fired: <text>').
  final void Function(String text)? onFired;

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
  /// (session-cwd adoption) carries them over before the next scan, or
  /// repointing the queue strands pre-adoption reminders where nobody looks.
  String? _lastScanRoot;

  /// The live `_scheduled/` dir, migrating pending records across a root
  /// change first (best-effort: unreadable sources stay put).
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
      'dueMs': DateTime.now().millisecondsSinceEpoch + delay.inMilliseconds,
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
    } on Object {
      // Individual delivery failures must not kill the fire-and-forget
      // starter; the next start()/timer tick retries.
    }
    _arm();
  }

  /// Set by [dispose]: an in-flight re-arm must not arm a timer after the
  /// host tore the queue down (the orphaned timer would deliver into the
  /// dead session's mailbox — the stranded-reminder bug).
  bool _disposed = false;

  /// Cancels the armed delivery timer (host teardown). Pending record
  /// files stay put — they are the source of truth; a later [start]
  /// (host restart, session switch) re-arms and delivers them.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
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
          sentAt:
              json['sentAt'] as String? ??
              DateTime.now().toUtc().toIso8601String(),
          hops: json['hops'] as int? ?? 0,
        ),
      );
      await _env.remove(path, force: true);
    }
  }

  /// Delivers every due record. Returns how many were delivered.
  Future<int> deliverDue() => _deliverDue();

  /// In-flight delivery guard: a timer tick landing while [deliverDue] is
  /// still running must not send the same record twice (the file inbox has
  /// no id dedup). The skipped tick is re-armed right after.
  bool _delivering = false;

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
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null; // torn write — leave for inspection
    }
  }

  Future<int> _deliverDueInner() async {
    final dir = await _pendingDir();
    final entries = (await _env.listDir(dir)).valueOrNull ?? const [];
    var delivered = 0;
    for (final entry in entries) {
      if (entry.kind == FileKind.directory || !entry.path.endsWith('.json')) {
        continue;
      }
      // listDir implementations differ on absolute vs bare names.
      final path = entry.path.contains('/') ? entry.path : '$dir/${entry.path}';
      final record = await _readRecord(path);
      if (record == null) continue;
      final dueMs = record['dueMs'] as int?;
      if (dueMs == null || dueMs > DateTime.now().millisecondsSinceEpoch) {
        continue; // not a schedule record, or not due yet
      }
      final recordedTo = record['to'] as String? ?? _self();
      final from = record['from'] as String? ?? recordedTo;
      // Self-addressed records ride the LIVE self mailbox: the recorded
      // address was pinned at schedule time, but hosts re-address mailboxes
      // (session switch, app restart, service recreate) — the stale address
      // strands the reminder in a mailbox nobody drains while the tool
      // already reported success (the lost-schedule bug).
      final self = _self();
      // Ownership gate: re-address to the live self mailbox only when this
      // instance scheduled the record (_owns). A record owned by another
      // live instance is left for its owner: re-addressing it here steals
      // the reminder into the wrong mailbox and deletes the file
      // (cross-instance self-theft — issue #59).
      final owner = record['owner'] as String? ?? '';
      if (recordedTo == from && !_owns(owner)) continue;
      final to = (recordedTo == from && self != 'self' && self.isNotEmpty)
          ? self
          : recordedTo;
      await _repo().send(
        AgentMessage(
          id: record['id'] as String? ?? newMessageId(),
          fromId: from,
          toId: to,
          text: '[scheduled] ${record['text'] ?? ''}',
          sentAt: DateTime.now().toUtc().toIso8601String(),
          hops: 0,
        ),
      );
      await _env.remove(path, force: true);
      delivered++;
      onFired?.call('fired: ${record['text'] ?? ''}');
    }
    return delivered;
  }

  void _arm() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _armAsync();
  }

  Future<void> _armAsync() async {
    if (_disposed) return;
    final nearest = await _nearestDueMs();
    // The scan awaited above; the host may have torn the queue down meanwhile.
    if (_disposed || nearest == null) return;
    final wait = nearest - DateTime.now().millisecondsSinceEpoch;
    _timer = Timer(Duration(milliseconds: wait.clamp(0, 1 << 40)), () async {
      await _deliverDue();
      _arm();
    });
  }

  /// Scans the pending records for the earliest due time (null: none).
  Future<int?> _nearestDueMs() async {
    final dir = await _pendingDir();
    final entries = (await _env.listDir(dir)).valueOrNull ?? const [];
    int? nearest;
    for (final entry in entries) {
      if (!entry.path.endsWith('.json')) continue;
      final path = entry.path.contains('/') ? entry.path : '$dir/${entry.path}';
      final record = await _readRecord(path);
      final due = record?['dueMs'] as int?;
      // Foreign self-addressed records arm no timer here: this instance can
      // never deliver them, and arming would hot-loop a zero-delay timer
      // until the owner sweeps the record (issue #59).
      final to = record?['to'] as String? ?? _self();
      final from = record?['from'] as String? ?? to;
      if (to == from && !_owns(record?['owner'] as String? ?? '')) continue;
      if (due != null && (nearest == null || due < nearest)) {
        nearest = due;
      }
    }
    return nearest;
  }
}
