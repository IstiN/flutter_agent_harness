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
    this.onScheduled,
    this.onFired,
  }) : _env = env,
       _repo = repo,
       _selfMailbox = selfMailbox,
       _root = root;

  final ExecutionEnv _env;
  final MessagingRepository Function() _repo;
  final String Function() _root;

  /// The scheduling agent's own mailbox (e.g. `&lt;sessionId&gt;/main`). Records
  /// without an explicit `to` default here, and `from` too — a missing
  /// self mailbox stored the literal string 'self', delivering reminders
  /// into a phantom mailbox nobody drains (lost production mail).
  final String Function()? _selfMailbox;

  /// Host-visible notice when a record is scheduled ('in 25m: &lt;text&gt;').
  final void Function(String text)? onScheduled;

  /// Host-visible notice when a record fires ('fired: &lt;text&gt;').
  final void Function(String text)? onFired;

  String _self() => _selfMailbox?.call() ?? 'self';

  /// Compact human delay: 90s / 25m / 2h / 1d.
  static String formatDelay(Duration d) {
    if (d.inDays >= 1) return '${d.inDays}d';
    if (d.inHours >= 1) return '${d.inHours}h';
    if (d.inMinutes >= 1) return '${d.inMinutes}m';
    if (d.inSeconds >= 1) return '${d.inSeconds}s';
    return '${d.inMilliseconds}ms';
  }

  String get _dir => '${_root()}/_scheduled';
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

  Future<int> _deliverDueInner() async {
    final entries = (await _env.listDir(_dir)).valueOrNull ?? const [];
    var delivered = 0;
    for (final entry in entries) {
      if (entry.kind == FileKind.directory || !entry.path.endsWith('.json')) {
        continue;
      }
      // listDir implementations differ on absolute vs bare names.
      final path = entry.path.contains('/')
          ? entry.path
          : '$_dir/${entry.path}';
      final text = (await _env.readTextFile(path)).valueOrNull;
      if (text == null) {
        continue;
      }
      final Map<String, dynamic> record;
      try {
        final decoded = jsonDecode(text);
        if (decoded is! Map<String, dynamic>) {
          continue; // valid json, wrong shape — not a record
        }
        record = decoded;
      } on FormatException {
        continue; // torn write — leave for inspection
      }
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
    final entries = (await _env.listDir(_dir)).valueOrNull ?? const [];
    int? nearest;
    for (final entry in entries) {
      if (!entry.path.endsWith('.json')) continue;
      final path = entry.path.contains('/')
          ? entry.path
          : '$_dir/${entry.path}';
      final text = (await _env.readTextFile(path)).valueOrNull;
      if (text == null) continue;
      try {
        final decoded = jsonDecode(text);
        if (decoded is! Map<String, dynamic>) continue; // valid json, wrong shape
        final due = decoded['dueMs'] as int?;
        if (due != null && (nearest == null || due < nearest)) {
          nearest = due;
        }
      } on FormatException {
        continue;
      }
    }
    return nearest;
  }
}
