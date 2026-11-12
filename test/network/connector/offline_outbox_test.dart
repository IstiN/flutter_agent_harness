// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:flutter_agent_harness/src/network/connector/offline_outbox.dart';
import 'package:test/test.dart';

void main() {
  OutboxEntry entry(String msgId) => OutboxEntry(
    envelope: NetworkEnvelope(
      kind: NetworkEnvelopeKind.mail,
      msgId: msgId,
      network: 'net-a',
      channel: 'chan-1',
      from: 'goal_builder@macbook',
      to: 'user:u1',
      ts: '2026-11-12T10:00:00.000Z',
      ciphertext: 'c-$msgId',
    ),
  );

  group('MemoryOutboxStore (put/list/ack/remove)', () {
    test('list() keeps insertion order (drain-in-order basis)', () async {
      final store = MemoryOutboxStore();
      await store.put(entry('m-3'));
      await store.put(entry('m-1'));
      await store.put(entry('m-2'));
      final pending = await store.list();
      expect(pending.map((e) => e.envelope.msgId), ['m-3', 'm-1', 'm-2']);
      expect(await store.pendingCount(), 3);
    });

    test(
      're-put of the same msgId replaces in place — no duplicates',
      () async {
        final store = MemoryOutboxStore();
        await store.put(entry('m-1'));
        await store.put(entry('m-2'));
        final first = await store.list();
        final replacementEnvelope = first[1].envelope;
        final replacement = OutboxEntry(
          envelope: replacementEnvelope,
          queuedAt: first[1].queuedAt,
          attempts: 4,
        );
        await store.put(replacement);
        final pending = await store.list();
        expect(pending, hasLength(2));
        expect(pending[1].attempts, 4, reason: 'entry replaced, order kept');
      },
    );

    test(
      'ack retires a frame from list() (ack-after-write contract)',
      () async {
        final store = MemoryOutboxStore();
        await store.put(entry('m-1'));
        await store.put(entry('m-2'));
        await store.ack('m-1');
        final pending = await store.list();
        expect(pending.map((e) => e.envelope.msgId), ['m-2']);
        expect(await store.pendingCount(), 1);
      },
    );

    test('remove deletes without delivering', () async {
      final store = MemoryOutboxStore();
      await store.put(entry('m-1'));
      await store.remove('m-1');
      expect(await store.list(), isEmpty);
      expect(await store.pendingCount(), 0);
    });

    test('entries carry envelope, queuedAt and attempts bookkeeping', () {
      final e = entry('m-1');
      expect(e.envelope.msgId, 'm-1');
      expect(e.queuedAt, isNotNull);
      expect(e.attempts, 0);
      expect(e.retried().attempts, 1);
      expect(e.retried().envelope.msgId, 'm-1');
    });
  });

  group('drainOutbox (AC5 local half, contract v1.1 msgId rule)', () {
    test(
      'drains head-first in order, acking only after send completes',
      () async {
        final store = MemoryOutboxStore()
          ..put(entry('m-1'))
          ..put(entry('m-2'))
          ..put(entry('m-3'));
        final sent = <String>[];
        final delivered = await drainOutbox(
          store,
          (e) async => sent.add(e.envelope.msgId),
        );
        expect(delivered, 3);
        expect(sent, ['m-1', 'm-2', 'm-3']);
        expect(await store.pendingCount(), 0);
      },
    );

    test(
      'retry reuses the ORIGINAL msgId byte-for-byte (fanet1 frameId)',
      () async {
        final store = MemoryOutboxStore()
          ..put(entry('m-original'))
          ..put(entry('m-2'));
        final sentIds = <String>[];
        var firstAttemptFailed = false;
        final delivered = await drainOutbox(store, (e) async {
          final id = e.envelope.msgId;
          if (id == 'm-original' && !firstAttemptFailed) {
            firstAttemptFailed = true;
            throw StateError('link down mid-drain');
          }
          sentIds.add(id);
        });
        // First drain delivers m-2? No — m-original is the head; its failure
        // stops the drain with NOTHING delivered, order intact.
        expect(delivered, 0);
        expect(await store.pendingCount(), 2);
        // Restore: the SAME id goes out again — never a re-minted one.
        final second = await drainOutbox(
          store,
          (e) async => sentIds.add(e.envelope.msgId),
        );
        expect(second, 2);
        expect(sentIds, ['m-original', 'm-2']);
      },
    );

    test(
      'a failed send stops the drain; the frame stays queued at head',
      () async {
        final store = MemoryOutboxStore()
          ..put(entry('m-1'))
          ..put(entry('m-2'));
        final sent = <String>[];
        final delivered = await drainOutbox(store, (e) async {
          if (e.envelope.msgId == 'm-2') throw StateError('down');
          sent.add(e.envelope.msgId);
        });
        expect(delivered, 1);
        expect(sent, ['m-1']);
        final remaining = await store.list();
        expect(remaining.map((e) => e.envelope.msgId), ['m-2']);
      },
    );

    test('canSend=false sends nothing', () async {
      final store = MemoryOutboxStore()..put(entry('m-1'));
      var sends = 0;
      final delivered = await drainOutbox(
        store,
        (e) async => sends++,
        canSend: () => false,
      );
      expect(delivered, 0);
      expect(sends, 0);
      expect(await store.pendingCount(), 1);
    });

    test('draining an empty outbox delivers nothing', () async {
      expect(await drainOutbox(MemoryOutboxStore(), (e) async {}), 0);
    });
  });
}
