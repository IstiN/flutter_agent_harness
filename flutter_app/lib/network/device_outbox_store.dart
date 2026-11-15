// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The file-backed offline outbox of the machine connector (contract §10
/// "offline outbox (file-backed, injectable store)", issue #2062 chunk
/// 14): one JSON line per queued frame under the app support directory,
/// with EXACTLY the [MemoryOutboxStore] semantics — FIFO insertion order,
/// idempotent `put` (same `msgId` replaces in place, order + attempts
/// preserved), `ack` retires, `remove` deletes — plus restart replay: a
/// fresh instance over the same file continues the same queue in the
/// same order. A torn tail line (crash mid-append) is skipped, never
/// fatal.
///
/// The `msgId` is the fanet1 frameId (contract v1.1 §7): entries are
/// stored byte-for-byte as minted and replayed unchanged.
library;

import 'dart:convert';
import 'dart:io';

// The core outbox contract (pure Dart); implementation import per the
// lib/network convention (key_wallet.dart).
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/offline_outbox.dart';

/// Serializes one queued frame to its JSONL line.
String encodeOutboxEntry(OutboxEntry entry) => jsonEncode({
  'msgId': entry.envelope.msgId,
  'queuedAt': entry.queuedAt.toUtc().toIso8601String(),
  'attempts': entry.attempts,
  'envelope': entry.envelope.toJson(),
});

/// Parses one JSONL line back into a queued frame; null on a corrupt or
/// unknown line (a torn tail from a crash mid-write must never wedge the
/// queue).
OutboxEntry? tryDecodeOutboxEntry(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) return null;
    final envelope = NetworkEnvelope.fromJson(decoded['envelope']);
    final queuedAt = DateTime.tryParse('${decoded['queuedAt'] ?? ''}');
    final attempts = decoded['attempts'];
    return OutboxEntry(
      envelope: envelope,
      queuedAt: queuedAt,
      attempts: attempts is int ? attempts : 0,
    );
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}

/// The [OutboxStore] over a JSONL file. State mirrors
/// [MemoryOutboxStore] in memory; new entries append one line, every
/// other mutation rewrites the file. Load is lazy and tolerant: missing
/// file = empty queue, corrupt lines are skipped.
final class FileOutboxStore implements OutboxStore {
  /// Backs the store with [file] (typically
  /// `<app support dir>/device_outbox.jsonl`).
  FileOutboxStore(this.file);

  /// The JSONL backing file.
  final File file;

  final _entries = <String, OutboxEntry>{};
  final _order = <String>[];
  var _loaded = false;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    if (!await file.exists()) return;
    final lines = await file.readAsLines();
    for (final line in lines) {
      final entry = tryDecodeOutboxEntry(line);
      if (entry == null) continue;
      final msgId = entry.envelope.msgId;
      if (!_entries.containsKey(msgId)) _order.add(msgId);
      _entries[msgId] = entry;
    }
  }

  @override
  Future<void> put(OutboxEntry entry) async {
    await _ensureLoaded();
    final isNew = !_entries.containsKey(entry.envelope.msgId);
    if (isNew) _order.add(entry.envelope.msgId);
    _entries[entry.envelope.msgId] = entry;
    if (isNew) {
      final parent = file.parent;
      if (!await parent.exists()) await parent.create(recursive: true);
      await file.writeAsString(
        '${encodeOutboxEntry(entry)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } else {
      await _rewrite();
    }
  }

  @override
  Future<List<OutboxEntry>> list() async {
    await _ensureLoaded();
    return [
      for (final msgId in _order)
        if (_entries[msgId] != null) _entries[msgId]!,
    ];
  }

  @override
  Future<void> ack(String msgId) async {
    await _ensureLoaded();
    if (_entries.remove(msgId) == null) return;
    _order.remove(msgId);
    await _rewrite();
  }

  @override
  Future<void> remove(String msgId) => ack(msgId);

  @override
  Future<int> pendingCount() async {
    await _ensureLoaded();
    return _entries.length;
  }

  /// Rewrites the whole file from the in-memory state (replace/rename is
  /// overkill here: the write is small, and a torn rewrite tail is
  /// skipped on the next load by the same tolerance that covers appends).
  Future<void> _rewrite() async {
    final parent = file.parent;
    if (!await parent.exists()) await parent.create(recursive: true);
    final buffer = StringBuffer();
    for (final msgId in _order) {
      final entry = _entries[msgId];
      if (entry == null) continue;
      buffer.writeln(encodeOutboxEntry(entry));
    }
    await file.writeAsString(buffer.toString(), flush: true);
  }
}
