// Write-path guarantees: reject ordering (error frame THEN close) and
// slow-consumer shedding at the queued-bytes cap; the DM dead-connection
// mailbox fallback. Port of the Go writepath_test.go +
// dm_drop_fallback_test.go.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dap_hub/dap_hub.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late TestHub hub;
  setUp(() async => hub = await startTestHub());
  tearDown(() => hub.close());

  test('reject delivers the error frame, then closes', () async {
    final a = await TestAgent.create('rejectee');
    final conn = await dial(hub);

    // Binary frame first: queues a bad_frame error, conn stays up.
    conn.socket.add(utf8.encode('x'));
    // Unsigned hello: reject queues bad_signature behind it — fatal.
    conn.writeJson(helloMap(a));

    final first = await conn.readOp('error', skip: const []);
    expect(first['code'], DapCodes.badFrame);
    final second = await conn.readOp('error', skip: const []);
    expect(second['code'], DapCodes.badSignature);
    expect(await conn.read(), isNull, reason: 'reject is fatal');
  });

  test('a slow consumer is shed at the queue cap; the sender survives',
      () async {
    final a = await TestAgent.create('sender');
    final v = await TestAgent.create('victim');
    final ca = await connect(hub, a);
    await joinChan(ca, a, 'general');

    // The victim dials and joins through a manual subscription so we can
    // PAUSE it — a paused socket stream stops draining the kernel buffer
    // and applies real TCP backpressure to the hub's writes.
    final socket = await WebSocket.connect(
      hub.url,
      headers: {'authorization': 'Bearer $testMasterSecret'},
    );
    final received = <String>[];
    final sub = socket.listen((e) => received.add(e as String));
    Future<Map<String, Object?>> pollFor(String op) async {
      for (var i = 0; i < 400; i++) {
        for (final raw in received) {
          final frame = jsonDecode(raw) as Map<String, Object?>;
          if (frame['op'] == op) return frame;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      fail('victim never saw $op');
    }

    socket.add(jsonEncode(await signFrame(v, helloMap(v))));
    await pollFor('welcome');
    socket.add(jsonEncode(await signFrame(v, {
      'op': 'join',
      'channel': 'general',
      'chanPubkey': 'chan-pub',
      'ts': DateTime.now().millisecondsSinceEpoch,
    })));
    await pollFor('joined');
    sub.pause(); // from here the victim reads nothing

    final victimSession = hub.hub.clients[v.id];
    expect(victimSession, isNotNull);

    // 48 x ~700KB (~33MB) is far past loopback TCP buffering, so the
    // victim's queue provably crosses maxQueuedBytes and it gets shed.
    final ct = 'Q' * 700000;
    for (var i = 0; i < 48; i++) {
      await sendChan(ca, a, 'general', 'flood-$i', ct);
      await ca.readOp('msg'); // drain the sender's own echo per send
    }

    await waitOffline(ca, v.id);
    expect(
      victimSession!.queuedBytes,
      lessThanOrEqualTo(maxQueuedBytes + (1 << 20)),
      reason: 'cap plus at most one frame of slack',
    );
    final info = await whois(ca, a.id);
    expect(info['online'], isTrue, reason: 'the healthy sender survives');
    await sub.cancel();
    await socket.close();
  });

  test('DM to a dead registered connection falls back to the mailbox',
      () async {
    final a = await TestAgent.create('a');
    final b = await TestAgent.create('b');
    final ca = await connect(hub, a);
    await connect(hub, b);

    // Kill B's connection server-side and re-insert the corpse into the
    // registry before the hub notices — the exact lookup/push race
    // window the mailbox fallback covers (the Go test can wait for
    // deregister first: its sendFrame sees the closed channel; ours
    // must act inside the window).
    final corpse = hub.hub.clients[b.id]!;
    await corpse.close();
    hub.hub.clients[b.id] = corpse;

    await sendDM(ca, a, b.id, 'race-1', 'Q1JD');
    await ca.expectQuiet();

    final queue = hub.hub.mailbox[b.id];
    expect(queue?.length, 1);
    expect(queue?.first['id'], 'race-1');

    // The real B reconnects (register evicts the corpse) and the flush
    // delivers the queued DM.
    final cb2 = await connect(hub, b);
    cb2.writeJson({'op': 'flush'});
    final msg = await cb2.readOp('msg', skip: const []);
    expect(msg['id'], 'race-1');
    expect(msg['ciphertext'], 'Q1JD');
    await cb2.readOp('flushed', skip: const []);
  });
}
