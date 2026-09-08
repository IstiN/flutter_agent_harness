// Message routing: channel fanout, DM online/offline, eviction, ping,
// unknown ops. Port of the Go routing_test.go + membership_test.go +
// acl_test.go + dedupe_test.go.

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

  test('channel broadcast fans out with sender echo', () async {
    await joinChan(ca, a, 'general');
    await joinChan(cb, b, 'general');
    await sendChan(ca, a, 'general', 'm1', 'Q1JD');
    final echo = await ca.readOp('msg');
    expect(echo['from'], a.id);
    expect(echo['id'], 'm1');
    expect(echo['channel'], 'general');
    expect(echo['ciphertext'], 'Q1JD');
    final got = await cb.readOp('msg');
    expect(got['from'], a.id);
    expect(got['id'], 'm1');
  });

  test('direct message: recipient only, no sender echo', () async {
    await sendDM(ca, a, b.id, 'd1', 'Q1JD');
    final got = await cb.readOp('msg', skip: const []);
    expect(got['to'], b.id);
    expect(got['from'], a.id);
    await ca.expectQuiet();
  });

  test('DM to unknown agent is rejected', () async {
    await sendDM(ca, a, 'ffffffffffffffff', 'd1', 'Q1JD');
    final err = await ca.readOp('error', skip: const []);
    expect(err['code'], DapCodes.unknownAgent);
  });

  test('send to unknown channel is rejected', () async {
    await sendChan(ca, a, 'nope', 'm1', 'Q1JD');
    final err = await ca.readOp('error', skip: const []);
    expect(err['code'], DapCodes.unknownChannel);
  });

  test('eviction: a second connection for the agent kills the first', () async {
    final cb2 = await connect(hub, b);
    expect(await cb.read(), isNull, reason: 'old connection must close');
    // the new connection is functional
    final info = await whois(cb2, b.id);
    expect(info['online'], isTrue);
  });

  test('unknown op is a bad frame', () async {
    ca.writeJson({'op': 'teleport'});
    final err = await ca.readOp('error', skip: const []);
    expect(err['code'], DapCodes.badFrame);
  });

  group('membership', () {
    test('non-member publish is denied', () async {
      await joinChan(cb, b, 'general');
      await sendChan(ca, a, 'general', 'm1', 'Q1JD');
      final err = await ca.readOp('error', skip: const []);
      expect(err['code'], DapCodes.accessDenied);
    });

    test('member publishes after join', () async {
      await joinChan(ca, a, 'general');
      await sendChan(ca, a, 'general', 'm1', 'Q1JD');
      final echo = await ca.readOp('msg');
      expect(echo['id'], 'm1');
    });
  });

  group('ACL', () {
    test('join denied for a pubkey not on the ACL', () async {
      // A creates the channel; admin restricts it to A's pubkey.
      await joinChan(ca, a, 'vip');
      final setAcl = hub.hub.adminSetAcl(
        adminTestToken,
        'vip',
        '{"allowed":["${a.pubB64}"]}',
      );
      expect(setAcl.status, 204);
      await connWriteJoin(cb, b, 'vip');
      final err = await cb.readOp('error');
      expect(err['code'], DapCodes.accessDenied);
    });

    test('publish denied even for a member dropped from the ACL', () async {
      await joinChan(ca, a, 'vip');
      await joinChan(cb, b, 'vip');
      hub.hub.adminSetAcl(
        adminTestToken,
        'vip',
        '{"allowed":["${a.pubB64}"]}',
      );
      await sendChan(cb, b, 'vip', 'm1', 'Q1JD');
      final err = await cb.readOp('error', skip: const []);
      expect(err['code'], DapCodes.accessDenied);
    });

    test('empty ACL allows any authenticated agent', () async {
      await joinChan(ca, a, 'open');
      await joinChan(cb, b, 'open');
      await sendChan(cb, b, 'open', 'm1', 'Q1JD');
      final got = await ca.readOp('msg');
      expect(got['from'], b.id);
    });
  });

  group('dedupe', () {
    test('send requires an id', () async {
      await ca.writeSigned(a, {
        'op': 'send',
        'to': b.id,
        'ts': DateTime.now().millisecondsSinceEpoch,
        'ciphertext': 'Q1JD',
      });
      final err = await ca.readOp('error', skip: const []);
      expect(err['code'], DapCodes.badFrame);
    });

    test('duplicate DM id delivers once', () async {
      final frame = await signFrame(a, {
        'op': 'send',
        'to': b.id,
        'id': 'dup-1',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'ciphertext': 'Q1JD',
      });
      ca.writeJson(frame);
      final got = await cb.readOp('msg', skip: const []);
      expect(got['id'], 'dup-1');
      ca.writeJson(frame);
      final err = await ca.readOp('error', skip: const []);
      expect(err['code'], DapCodes.replayedNonce);
      await cb.expectQuiet();
    });

    test('duplicate channel id delivers once', () async {
      await joinChan(ca, a, 'general');
      await joinChan(cb, b, 'general');
      final frame = await signFrame(a, {
        'op': 'send',
        'channel': 'general',
        'id': 'dup-2',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'ciphertext': 'Q1JD',
      });
      ca.writeJson(frame);
      await ca.readOp('msg'); // echo
      await cb.readOp('msg');
      ca.writeJson(frame);
      final err = await ca.readOp('error', skip: const []);
      expect(err['code'], DapCodes.replayedNonce);
      await ca.expectQuiet();
      await cb.expectQuiet();
    });

    test('a rejected send does not latch its id', () async {
      // Unknown agent → rejected; after B exists, the same id must work.
      final frame = await signFrame(a, {
        'op': 'send',
        'to': 'eeeeeeeeeeeeeeee',
        'id': 'retry-1',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'ciphertext': 'Q1JD',
      });
      ca.writeJson(frame);
      var err = await ca.readOp('error', skip: const []);
      expect(err['code'], DapCodes.unknownAgent);

      // Not a member → rejected; after joining, the same id must work.
      await joinChan(cb, b, 'general');
      final frame2 = await signFrame(a, {
        'op': 'send',
        'channel': 'general',
        'id': 'retry-2',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'ciphertext': 'Q1JD',
      });
      ca.writeJson(frame2);
      err = await ca.readOp('error', skip: const []);
      expect(err['code'], DapCodes.accessDenied);
      await joinChan(ca, a, 'general');
      ca.writeJson(frame2);
      final echo = await ca.readOp('msg');
      expect(echo['id'], 'retry-2');
    });
  });
}

/// Writes a join frame without asserting the joined reply (denial paths
/// answer with an error instead).
Future<void> connWriteJoin(
  TestConn conn,
  TestAgent agent,
  String channel,
) =>
    conn.writeSigned(agent, {
      'op': 'join',
      'channel': channel,
      'chanPubkey': 'chan-pub',
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
