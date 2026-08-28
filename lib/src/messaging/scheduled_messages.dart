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
  }) : _env = env,
       _repo = repo,
       _root = root;

  final ExecutionEnv _env; // ignore: prefer_initializing_formals
  final MessagingRepository Function() _repo;
  final String Function() _root;

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
      'to': to ?? 'self',
      'from': from ?? to ?? 'self',
      'text': text,
    };
    (await _env.createDir(_dir)).getOrThrow();
    (await _env.writeFile('$_dir/$id.json', jsonEncode(record))).getOrThrow();
    _arm();
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
    try {
      await _deliverDue();
    } on Object {
      // Individual delivery failures must not kill the fire-and-forget
      // starter; the next start()/timer tick retries.
    }
    _arm();
  }

  /// Delivers every due record. Returns how many were delivered.
  Future<int> deliverDue() => _deliverDue();

  Future<int> _deliverDue() async {
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
      final to = record['to'] as String? ?? 'self';
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
