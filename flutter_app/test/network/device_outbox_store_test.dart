// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Tests for the file-backed device outbox (issue #2062 chunk 14): the
/// [MemoryOutboxStore] conformance battery runs against BOTH stores (the
/// file store must be semantics-identical), plus the file-only restart
/// replay and torn-tail tolerance.
library;

import 'dart:io';

import 'package:fa/network/device_outbox_store.dart';
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:flutter_agent_harness/src/network/connector/offline_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

OutboxEntry _entry(String msgId, {int attempts = 0, int minute = 0}) =>
    OutboxEntry(
      envelope: NetworkEnvelope(
        kind: NetworkEnvelopeKind.mail,
        msgId: msgId,
        network: 'net-1',
        channel: 'chan-1',
        from: 'fa@dev-1',
        to: 'user:u2',
        ts: rfc3339Timestamp(DateTime.utc(2026, 11, 12, 10, minute)),
        ciphertext: 'ct-$msgId',
      ),
      attempts: attempts,
    );

/// The semantics battery shared by the memory store and the file store.
/// [makeStore] is called inside each test (a fresh store per test; for
/// the file store the factory reads late fields set in setUp).
void runOutboxConformance(OutboxStore Function() makeStore) {
  test('put/list preserve FIFO insertion order', () async {
    final store = makeStore();
    await store.put(_entry('m-1'));
    await store.put(_entry('m-2'));
    await store.put(_entry('m-3'));

    final pending = await store.list();
    expect(pending.map((e) => e.envelope.msgId), ['m-1', 'm-2', 'm-3']);
    expect(await store.pendingCount(), 3);
  });

  test('re-putting an existing msgId replaces in place (order + attempts '
      'preserved)', () async {
    final store = makeStore();
    await store.put(_entry('m-1'));
    await store.put(_entry('m-2'));
    await store.put(_entry('m-3'));
    await store.put(_entry('m-2', attempts: 2));

    final pending = await store.list();
    expect(pending.map((e) => e.envelope.msgId), ['m-1', 'm-2', 'm-3']);
    expect(pending[1].attempts, 2);
    expect(await store.pendingCount(), 3);
  });

  test('ack retires the frame; remove deletes outright', () async {
    final store = makeStore();
    await store.put(_entry('m-1'));
    await store.put(_entry('m-2'));

    await store.ack('m-1');
    expect((await store.list()).map((e) => e.envelope.msgId), ['m-2']);

    await store.remove('m-2');
    expect(await store.list(), isEmpty);
    expect(await store.pendingCount(), 0);

    // Idempotent: acking/removing unknown ids is a no-op.
    await store.ack('m-1');
    await store.remove('m-1');
    expect(await store.pendingCount(), 0);
  });
}

void main() {
  group('MemoryOutboxStore (baseline)', () {
    runOutboxConformance(MemoryOutboxStore.new);
  });

  group('FileOutboxStore conformance', () {
    late Directory dir;
    late File file;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fa_outbox_test');
      file = File('${dir.path}/device_outbox.jsonl');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    runOutboxConformance(() => FileOutboxStore(file));

    test(
      'a fresh instance over the same file replays the queue in order',
      () async {
        final store = FileOutboxStore(file);
        await store.put(_entry('m-1', minute: 1));
        await store.put(_entry('m-2', minute: 2));
        await store.put(_entry('m-3', minute: 3));
        await store.ack('m-1');

        // "Restart": a brand-new store over the same backing file.
        final before = await store.list();
        final queuedAtBefore = before[0].queuedAt;
        final replayed = FileOutboxStore(file);
        final pending = await replayed.list();
        expect(pending.map((e) => e.envelope.msgId), ['m-2', 'm-3']);
        expect(pending[0].envelope.ciphertext, 'ct-m-2');
        expect(
          pending[0].queuedAt,
          queuedAtBefore,
          reason: 'queuedAt survives the round-trip (stored, not re-minted)',
        );
        expect(await replayed.pendingCount(), 2);

        // The replayed queue stays live: append + ack round-trips.
        await replayed.put(_entry('m-4'));
        expect(
          (await FileOutboxStore(file).list()).map((e) => e.envelope.msgId),
          ['m-2', 'm-3', 'm-4'],
        );
      },
    );

    test('a torn tail line (crash mid-append) is skipped, the rest '
        'replays', () async {
      final store = FileOutboxStore(file);
      await store.put(_entry('m-1'));
      await store.put(_entry('m-2'));
      await file.writeAsString(
        '${await file.readAsString()}{"msgId": "torn", "env', // truncated
        mode: FileMode.append,
      );

      final replayed = FileOutboxStore(file);
      expect((await replayed.list()).map((e) => e.envelope.msgId), [
        'm-1',
        'm-2',
      ]);
      expect(await replayed.pendingCount(), 2);
    });

    test('a missing backing file is an empty queue', () async {
      final store = FileOutboxStore(file);
      expect(await store.list(), isEmpty);
      expect(await store.pendingCount(), 0);
    });

    test('jsonl round-trip helpers reject garbage lines', () {
      expect(tryDecodeOutboxEntry(''), isNull);
      expect(tryDecodeOutboxEntry('not json'), isNull);
      expect(tryDecodeOutboxEntry('{"no":"envelope"}'), isNull);
      expect(tryDecodeOutboxEntry('{"envelope":"not-a-map"}'), isNull);
    });
  });
}
