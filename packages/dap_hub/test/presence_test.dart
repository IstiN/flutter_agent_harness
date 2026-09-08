// Presence query/broadcast semantics, offline mailbox, reconnect.
// Port of the Go presence_test.go + join_presence_test.go +
// lastseen_test.go + mailbox_prune_test.go + presence overflow.

import 'package:dap_hub/dap_hub.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late TestHub hub;
  late TestAgent a;
  late TestAgent b;
  late TestConn ca;
  late TestConn cb;

  setUp(() async {
    hub = await startTestHub();
    a = await TestAgent.create('a');
    b = await TestAgent.create('b');
    ca = await connect(hub, a);
    cb = await connect(hub, b);
  });
  tearDown(() => hub.close());

  test('presence query answer echoes the request id as replyTo', () async {
    ca.writeJson({'op': 'presence_query', 'id': 'q-1'});
    final answer = await ca.readUntil(
      (f) => f['op'] == 'presence',
      skip: const [],
    );
    expect(answer['replyTo'], 'q-1');
    final agents = answer['agents'] as List;
    expect(agents.length, 2);
    final ids = agents.map((e) => (e as Map)['agentId']).toSet();
    expect(ids, {a.id, b.id});
    for (final entry in agents) {
      expect((entry as Map)['online'], isTrue);
      expect(entry['pubkey'], isNotEmpty);
      expect(entry.containsKey('lastSeen'), isTrue);
    }
  });

  test('a query without id gets an answer without replyTo', () async {
    ca.writeJson({'op': 'presence_query'});
    final answer = await ca.readUntil(
      (f) => f['op'] == 'presence',
      skip: const [],
    );
    expect(answer.containsKey('replyTo'), isFalse);
  });

  test('join broadcasts presence to channel peers', () async {
    await joinChan(ca, a, 'general');
    // A's own join does not broadcast to A (no peers yet).
    await joinChan(cb, b, 'general');
    final push = await ca.readUntil(
      (f) =>
          f['op'] == 'presence' &&
          ((f['agents'] as List).first as Map)['agentId'] == b.id,
    );
    expect(push.containsKey('replyTo'), isFalse,
        reason: 'broadcast pushes never carry replyTo');
    final info = (push['agents'] as List).first as Map;
    expect(info['online'], isTrue);
    expect(info['name'], 'b');
  });

  test('connect broadcasts presence to channel peers', () async {
    await joinChan(ca, a, 'general');
    await joinChan(cb, b, 'general');
    // drain B's join push on A
    await ca.readOp('presence', skip: const []);
    // C joins the channel, then D connects — A and B learn of D only
    // after D joins (registry presence is per-channel).
    final d = await TestAgent.create('d');
    final cd = await connect(hub, d);
    await joinChan(cd, d, 'general');
    final pushToA = await ca.readOp('presence');
    final pushToB = await cb.readOp('presence');
    for (final push in [pushToA, pushToB]) {
      final info = (push['agents'] as List).first as Map;
      expect(info['agentId'], d.id);
      expect(info['online'], isTrue);
    }
  });

  test('disconnect broadcasts offline presence', () async {
    await joinChan(ca, a, 'general');
    await joinChan(cb, b, 'general');
    await ca.readOp('presence', skip: const []); // drain b's join push
    await cb.close();
    final push = await ca.readOp('presence', skip: const []);
    final info = (push['agents'] as List).first as Map;
    expect(info['agentId'], b.id);
    expect(info['online'], isFalse);
  });

  test('a denied join sends no presence', () async {
    await joinChan(ca, a, 'vip');
    hub.hub.adminSetAcl(
      adminTestToken,
      'vip',
      '{"allowed":["${a.pubB64}"]}',
    );
    // B tries to join → denied → A must see no presence push.
    await cb.writeSigned(b, {
      'op': 'join',
      'channel': 'vip',
      'chanPubkey': 'chan-pub',
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    final err = await cb.readOp('error', skip: const []);
    expect(err['code'], DapCodes.accessDenied);
    await ca.expectQuiet();
  });

  test('offline mailbox: DMs queue and flush in order', () async {
    await cb.close();
    await waitOffline(ca, b.id);
    await sendDM(ca, a, b.id, 'm1', 'QT0=');
    await sendDM(ca, a, b.id, 'm2', 'Qj0=');
    await ca.expectQuiet();

    final cb2 = await connect(hub, b);
    cb2.writeJson({'op': 'flush'});
    final first = await cb2.readOp('msg', skip: const []);
    final second = await cb2.readOp('msg', skip: const []);
    expect([first['id'], second['id']], ['m1', 'm2']);
    final flushed = await cb2.readOp('flushed', skip: const []);
    expect(flushed['count'], 2);
  });

  test('mailbox overflow drops oldest and reports mailbox_full once', () async {
    await cb.close();
    await waitOffline(ca, b.id);
    for (var i = 0; i < 120; i++) {
      await sendDM(ca, a, b.id, 'm$i', 'Q1JD');
    }
    final cb2 = await connect(hub, b);
    cb2.writeJson({'op': 'flush'});
    // 100 messages (m20..m119), one mailbox_full error, one flushed.
    var msgs = 0;
    String? fullCode;
    int? count;
    while (count == null) {
      final frame = await cb2.read();
      if (frame == null) fail('connection closed mid-flush');
      switch (frame['op']) {
        case 'msg':
          msgs++;
        case 'error':
          fullCode = frame['code'] as String?;
        case 'flushed':
          count = frame['count'] as int?;
      }
    }
    expect(msgs, 100);
    expect(fullCode, DapCodes.mailboxFull);
    expect(count, 100);
  });

  test('DM to a long-offline agent is enqueued, not rejected', () async {
    await cb.close();
    await waitOffline(ca, b.id);
    // No TTL pruning: the identity stays addressable.
    await sendDM(ca, a, b.id, 'late-1', 'Q1JD');
    await ca.expectQuiet();
    expect(hub.hub.mailbox[b.id]?.length, 1);
  });

  test('reconnect: agentId stays stable and whois resolves', () async {
    await cb.close();
    await waitOffline(ca, b.id);
    final cb2 = await connect(hub, b);
    final info = await whois(ca, b.id);
    expect(info['online'], isTrue);
    await cb2.close();
  });

  group('lastSeen', () {
    test('advances on authenticated frames, stamps at disconnect', () async {
      final clock = TestClock();
      final timed = await startTestHub(clock: clock);
      final ta = await TestAgent.create('ta');
      final tb = await TestAgent.create('tb');
      final tca = await connect(timed, ta);
      final tcb = await connect(timed, tb);
      final atConnect = (await whois(tca, ta.id))['lastSeen'] as int;

      clock.advance(const Duration(seconds: 5));
      tca.writeJson({'op': 'presence_query'});
      await tca.readOp('presence', skip: const []);
      final afterActivity = (await whois(tca, ta.id))['lastSeen'] as int;
      expect(afterActivity, greaterThan(atConnect));

      await tca.close();
      await waitOffline(tcb, ta.id);
      final atClose = (await whois(tcb, ta.id))['lastSeen'];
      expect(atClose, greaterThanOrEqualTo(afterActivity));
      await timed.close();
    });
  });
}
