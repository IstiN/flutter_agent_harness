/// The offline outbox of the machine connector (contract
/// `docs/fa_network_connector.md` §4/§10): frames generated while the
/// upstream is down queue here and drain IN ORDER on restore, with no
/// duplicates.
///
/// Per §4 the server ALSO queues undelivered mail and redelivers unacked
/// frames in seq order on resume — the local outbox covers the other
/// direction: outbound mail minted while disconnected. Contract v1.1 §7
/// makes `msgId` the fanet1 frameId (HKDF salt / AAD / dedup key in one
/// string), so retries MUST reuse the original id byte-for-byte: the drain
/// helper re-sends exactly the stored envelope, never re-mints ids.
///
/// The store is abstract so hosts can back it with a file (contract §10:
/// "offline outbox (file-backed, injectable store)"); the in-memory
/// implementation serves tests and short-lived hosts.
///
/// Pure Dart: no `dart:io`, no Flutter.
library;

import 'envelope.dart';

/// One queued outbound frame: the envelope exactly as minted (its `msgId`
/// is frozen — see the library docs) plus queue bookkeeping.
final class OutboxEntry {
  /// Wraps [envelope]; [queuedAt] defaults to now, [attempts] counts drain
  /// sends already tried for this entry.
  OutboxEntry({required this.envelope, DateTime? queuedAt, this.attempts = 0})
    : queuedAt = queuedAt ?? DateTime.now().toUtc();

  /// The frame to deliver. Retries carry this instance's `msgId`
  /// byte-for-byte (contract v1.1 §7).
  final NetworkEnvelope envelope;

  /// When the frame entered the outbox.
  final DateTime queuedAt;

  /// How many times the drain has attempted this frame.
  final int attempts;

  /// A copy with [attempts] incremented (the store applies it).
  OutboxEntry retried() => OutboxEntry(
    envelope: envelope,
    queuedAt: queuedAt,
    attempts: attempts + 1,
  );

  @override
  String toString() =>
      'OutboxEntry(${envelope.kind.wireName} msgId=${envelope.msgId} '
      'attempts=$attempts)';
}

/// The durable outbound queue (contract §10). `list()` is the drain order —
/// FIFO by insertion; `ack` retires a delivered frame, `remove` deletes one
/// without delivering. Implementations must preserve insertion order across
/// restarts where the medium allows (file-backed hosts).
abstract interface class OutboxStore {
  /// Enqueues [entry]. Re-putting an existing `msgId` REPLACES the entry in
  /// place (order and attempts preserved) — idempotent enqueue, no local
  /// duplicates.
  Future<void> put(OutboxEntry entry);

  /// The pending (unacked) frames in drain order — FIFO, oldest first.
  Future<List<OutboxEntry>> list();

  /// Marks [msgId] delivered: the entry leaves [list] forever.
  Future<void> ack(String msgId);

  /// Deletes [msgId] outright (caller-canceled frames), delivered or not.
  Future<void> remove(String msgId);

  /// How many frames are pending.
  Future<int> pendingCount();
}

/// The in-memory [OutboxStore]: FIFO, idempotent puts, no duplicates.
final class MemoryOutboxStore implements OutboxStore {
  final _entries = <String, OutboxEntry>{};
  final _order = <String>[];

  @override
  Future<void> put(OutboxEntry entry) async {
    final msgId = entry.envelope.msgId;
    if (!_entries.containsKey(msgId)) _order.add(msgId);
    _entries[msgId] = entry;
  }

  @override
  Future<List<OutboxEntry>> list() async => [
    for (final msgId in _order)
      if (_entries[msgId] != null) _entries[msgId]!,
  ];

  @override
  Future<void> ack(String msgId) async {
    _entries.remove(msgId);
    _order.remove(msgId);
  }

  @override
  Future<void> remove(String msgId) async {
    _entries.remove(msgId);
    _order.remove(msgId);
  }

  @override
  Future<int> pendingCount() async => _entries.length;
}

/// Drains [store] IN ORDER through [send]: frames go out head-first; a
/// frame is acked only AFTER its send completed (contract §3 ack-after-
/// write), so a failed or interrupted drain leaves the frame queued and the
/// next drain resumes from exactly there — no skips, no duplicates, and
/// retries reuse the original `msgId`. A failed send STOPS the drain (the
/// link is down; later frames keep their order behind the stuck head).
///
/// [canSend] gates the drain start (e.g. upstream not yet ready) — false
/// sends nothing. Returns the number of frames delivered.
Future<int> drainOutbox(
  OutboxStore store,
  Future<void> Function(OutboxEntry entry) send, {
  bool Function()? canSend,
}) async {
  if (canSend != null && !canSend()) return 0;
  var delivered = 0;
  while (true) {
    final pending = await store.list();
    if (pending.isEmpty) return delivered;
    final head = pending.first;
    try {
      await send(head);
    } on Object {
      return delivered;
    }
    await store.ack(head.envelope.msgId);
    delivered++;
  }
}
