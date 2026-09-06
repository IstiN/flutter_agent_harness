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
  }) : // ignore: prefer_initializing_formals
       _env = env,
       // ignore: prefer_initializing_formals
       _repo = repo,
       // ignore: prefer_initializing_formals
       _selfMailbox = selfMailbox,
       // ignore: prefer_initializing_formals
       _root = root;

  final ExecutionEnv _env;
  final MessagingRepository Function() _repo;
  // ignore: prefer_initializing_formals
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
        json = jsonDecode(text) as Map<String, dynamic>;
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
        record = jsonDecode(text) as Map<String, dynamic>;
      } on FormatException {
        continue; // torn write — leave for inspection
      }
      if ((record['dueMs'] as int? ?? 0) >
          DateTime.now().millisecondsSinceEpoch) {
        continue;
      }
      final to = record['to'] as String? ?? _self();
      await _repo().send(
        AgentMessage(
          id: record['id'] as String? ?? newMessageId(),
          fromId: record['from'] as String? ?? to,
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
    _timer?.cancel();
    _timer = null;
    _armAsync();
  }

  Future<void> _armAsync() async {
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
        final due = (jsonDecode(text) as Map<String, dynamic>)['dueMs'] as int?;
        if (due != null && (nearest == null || due < nearest)) {
          nearest = due;
        }
      } on FormatException {
        continue;
      }
    }
    if (nearest == null) return;
    final wait = nearest - DateTime.now().millisecondsSinceEpoch;
    _timer = Timer(Duration(milliseconds: wait.clamp(0, 1 << 40)), () async {
      await _deliverDue();
      _arm();
    });
  }
}
