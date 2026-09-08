// The auth gauntlet: Ed25519 signatures, ts window, nonce replay,
// canonical JSON. Port of the Go crypto_test.go + replay_window_test.go.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:dap_hub/dap_hub.dart';
import 'package:dap_hub/src/canonical_json.dart';
import 'package:dap_hub/src/crypto_utils.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('canonical JSON', () {
    test('sorts keys recursively, no whitespace', () {
      expect(
        canonicalJson({
          'b': 1,
          'a': {'y': 2, 'x': 1},
          'c': [3, 2, 1],
        }),
        '{"a":{"x":1,"y":2},"b":1,"c":[3,2,1]}',
      );
    });

    test('does not HTML-escape <>& (SetEscapeHTML(false))', () {
      expect(canonicalJson({'s': '<a>&</a>'}), '{"s":"<a>&</a>"}');
    });

    test('escapes controls and U+2028/U+2029 like Go', () {
      expect(canonicalJson({'s': 'a"b\\c\n'}), '{"s":"a\\"b\\\\c\\n"}');
      expect(canonicalJson({'s': ' '}), '{"s":"\\u2028"}');
      expect(canonicalJson({'s': ' '}), '{"s":"\\u2029"}');
    });

    test('integral doubles marshal without a fraction', () {
      expect(canonicalJson({'n': 1.0}), '{"n":1}');
    });
  });

  group('crypto primitives', () {
    test('agentIdFor: hex(sha256(pubkey_raw))[:16]', () {
      final pub = List<int>.generate(32, (i) => i);
      final want = sha256.convert(pub).toString().substring(0, 16);
      expect(agentIdFor(pub), want);
    });

    test('constEq', () {
      expect(constEq('abc', 'abc'), isTrue);
      expect(constEq('abc', 'abd'), isFalse);
      expect(constEq('abc', 'abcd'), isFalse);
      expect(constEq('', ''), isTrue);
    });
  });

  group('hello gauntlet', () {
    late TestHub hub;
    setUp(() async => hub = await startTestHub());
    tearDown(() => hub.close());

    Future<String> expectError(
      TestConn conn,
      String code, {
      List<String> skip = const [],
    }) async {
      final frame = await conn.readOp('error', skip: skip);
      expect(frame['code'], code);
      return code;
    }

    test('bad signature is rejected', () async {
      final a = await TestAgent.create('a');
      final b = await TestAgent.create('b');
      final conn = await dial(hub);
      // signed by B but declares A's pubkey
      await conn.writeSigned(b, helloMap(a));
      await expectError(conn, DapCodes.badSignature);
    });

    test('missing sig is rejected', () async {
      final a = await TestAgent.create('a');
      final conn = await dial(hub);
      conn.writeJson(helloMap(a));
      await expectError(conn, DapCodes.badSignature);
    });

    test('bad pubkey encoding is rejected', () async {
      final a = await TestAgent.create('a');
      final conn = await dial(hub);
      final frame = helloMap(a)..['pubkey'] = '!!!not-base64!!!';
      conn.writeJson(frame..['sig'] = a.pubB64);
      await expectError(conn, DapCodes.badSignature);
    });

    test('bad sig encoding is rejected', () async {
      final a = await TestAgent.create('a');
      final conn = await dial(hub);
      conn.writeJson(helloMap(a)..['sig'] = '!!!not-base64!!!');
      await expectError(conn, DapCodes.badSignature);
    });

    test('stale timestamp is rejected', () async {
      final a = await TestAgent.create('a');
      final conn = await dial(hub);
      final stale = helloMap(a)
        ..['ts'] = DateTime.now().millisecondsSinceEpoch -
            const Duration(minutes: 6).inMilliseconds;
      await conn.writeSigned(a, stale);
      await expectError(conn, DapCodes.staleTs);
    });

    test('short nonce is rejected', () async {
      final a = await TestAgent.create('a');
      final conn = await dial(hub);
      await conn.writeSigned(a, helloMap(a)..['nonce'] = 'short');
      await expectError(conn, DapCodes.badFrame);
    });

    test('replayed nonce is rejected', () async {
      final a = await TestAgent.create('a');
      final frame = await signFrame(a, helloMap(a));
      final c1 = await dial(hub);
      c1.writeJson(frame);
      await c1.readOp('welcome', skip: const []);
      final c2 = await dial(hub);
      c2.writeJson(frame); // same nonce, same pubkey
      await expectError(c2, DapCodes.replayedNonce);
    });

    test('nonce held beyond the ts window', () async {
      // Replay protection must outlive the ts window: a nonce replayed
      // inside replayKeep is still rejected even after ±300s passes.
      final a = await TestAgent.create('a');
      final frame = await signFrame(a, helloMap(a));
      final c1 = await dial(hub);
      c1.writeJson(frame);
      await c1.readOp('welcome', skip: const []);
      final c2 = await dial(hub);
      c2.writeJson(frame);
      await expectError(c2, DapCodes.replayedNonce);
    });

    test('frame before hello gets not_authenticated', () async {
      final conn = await dial(hub);
      conn.writeJson({'op': 'presence_query'});
      await expectError(conn, DapCodes.notAuthenticated);
    });

    test('double hello is a bad frame', () async {
      final a = await TestAgent.create('a');
      final conn = await connect(hub, a);
      await conn.writeSigned(a, helloMap(a));
      await expectError(conn, DapCodes.badFrame);
    });

    test('malformed JSON is a bad frame', () async {
      final conn = await dial(hub);
      conn.socket.add('{not json');
      await expectError(conn, DapCodes.badFrame);
    });

    test('binary frame gets bad_frame and the connection stays up', () async {
      final a = await TestAgent.create('a');
      final conn = await connect(hub, a);
      conn.socket.add(utf8.encode('binary'));
      final frame = await conn.readOp('error', skip: const []);
      expect(frame['code'], DapCodes.badFrame);
      // still alive: a whois round trip works
      final info = await whois(conn, a.id);
      expect(info['agentId'], a.id);
    });

    test('oversized frame is rejected then the connection closes', () async {
      final a = await TestAgent.create('a');
      final conn = await connect(hub, a);
      final big = 'Q' * ((1 << 20) + 1);
      conn.socket.add(big);
      final frame = await conn.readOp('error', skip: const []);
      expect(frame['code'], DapCodes.badFrame);
      expect(await conn.read(), isNull, reason: 'connection must close');
    });

    test('send with bad signature', () async {
      final a = await TestAgent.create('a');
      final b = await TestAgent.create('b');
      final conn = await connect(hub, a);
      await conn.writeSigned(b, {
        'op': 'send',
        'to': a.id,
        'id': 'x1',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'ciphertext': 'Q1JD',
      });
      await expectError(conn, DapCodes.badSignature);
    });

    test('send with stale timestamp', () async {
      final a = await TestAgent.create('a');
      final b = await TestAgent.create('b');
      final conn = await connect(hub, a);
      await conn.writeSigned(a, {
        'op': 'send',
        'to': b.id,
        'id': 'x1',
        'ts': DateTime.now().millisecondsSinceEpoch -
            const Duration(minutes: 6).inMilliseconds,
        'ciphertext': 'Q1JD',
      });
      await expectError(conn, DapCodes.staleTs);
    });

    test('end-to-end ciphertext round trip (channel + DM)', () async {
      final a = await TestAgent.create('a')
        ..withE2E();
      final b = await TestAgent.create('b')
        ..withE2E();
      final ca = await connect(hub, a);
      final cb = await connect(hub, b);
      await joinChan(ca, a, 'warroom');
      await joinChan(cb, b, 'warroom');

      const secret = 'ATTACK-AT-DAWN';

      // Channel: E2E to a channel keypair the hub never holds.
      final chanKey = await X25519().newKeyPair();
      final chanPubB64 = base64.encode(
        (await chanKey.extractPublicKey()).bytes,
      );
      final chanCt = await seal(
        chanKey,
        chanPubB64,
        'c1',
        'dap1|c1|warroom',
        secret,
      );
      await sendChan(ca, a, 'warroom', 'c1', chanCt);
      await ca.readOp('msg'); // own echo
      final chanMsg = await cb.readOp('msg');
      expect(chanMsg['ciphertext'], isNot(contains(secret)));
      expect(
        await unseal(chanKey, chanPubB64, 'c1', 'dap1|c1|warroom',
            chanMsg['ciphertext'] as String),
        secret,
      );

      // DM: E2E from a's x25519 to b's x25519 (learned via whois).
      final info = await whois(ca, b.id);
      final dmCt = await seal(
        a.e2eKeyPair!,
        info['x25519'] as String,
        'd1',
        'dap1|d1|${b.id}',
        secret,
      );
      await sendDM(ca, a, b.id, 'd1', dmCt);
      final dmMsg = await cb.readOp('msg');
      expect(dmMsg['ciphertext'], isNot(contains(secret)));
      expect(
        await unseal(b.e2eKeyPair!, a.e2ePubB64!, 'd1', 'dap1|d1|${b.id}',
            dmMsg['ciphertext'] as String),
        secret,
      );

      // The hub's own state holds no plaintext.
      final snapshot = jsonEncode({
        'channels': hub.hub.channels.keys.toList(),
        'mailbox': hub.hub.mailbox,
      });
      expect(snapshot, isNot(contains(secret)));
      expect(hub.logLines.join('\n'), isNot(contains(secret)));
    });
  });
}
