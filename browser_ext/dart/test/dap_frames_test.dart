// Pure DAP/1 pieces (dap_frames.dart): identity round-trip, agentId
// derivation, hello/send frame shapes + signature verification via
// fa_hub_client's canonical.dart, E2E DM crypto round-trip between two
// identities, reconnect backoff table, undecryptable mapping, mail dedupe.
//
// The transport (dap_client.dart) is js_interop WebSocket — CI verifies it
// end-to-end against test/hub/fake_hub.dart, not here.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:fa_hub_client/src/hub/canonical.dart';
import 'package:test/test.dart';

// The package has no lib/ — the SW entry compiles src/ directly.
import '../src/dap/dap_frames.dart';

Future<String> _agentIdOf(SimplePublicKey signingPub) async {
  final digest = await Sha256().hash(signingPub.bytes);
  return digest.bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .substring(0, 16);
}

void main() {
  group('DapIdentity', () {
    test(
      'generates a 16-hex agentId derived from the ed25519 public key',
      () async {
        final identity = await DapIdentity.generate();
        expect(identity.agentId, matches(RegExp(r'^[0-9a-f]{16}$')));
        expect(identity.agentId, await _agentIdOf(identity.signingPublicKey));
      },
    );

    test('round-trips through the key-file format', () async {
      final identity = await DapIdentity.generate();
      final restored = await DapIdentity.fromKeyFile(
        await identity.toKeyFile(),
      );
      expect(restored.agentId, identity.agentId);
      expect(restored.signingPubkeyB64, identity.signingPubkeyB64);
      expect(restored.dhPubkeyB64, identity.dhPubkeyB64);
    });

    test('key-file format matches the CLI layout', () async {
      final identity = await DapIdentity.generate();
      final lines = (await identity.toKeyFile()).split('\n');
      expect(lines[0], startsWith('ed25519:'));
      expect(lines[1], startsWith('x25519:'));
      expect(lines[2], 'x25519pub:${identity.dhPubkeyB64}');
      expect(
        base64Decode(lines[0].substring('ed25519:'.length)),
        hasLength(32),
      );
      expect(base64Decode(lines[1].substring('x25519:'.length)), hasLength(32));
    });

    test('rejects a torn key file', () async {
      expect(
        () => DapIdentity.fromKeyFile('ed25519:AAAA'),
        throwsArgumentError,
      );
    });

    test('signing key never equals the DH key', () async {
      final identity = await DapIdentity.generate();
      expect(identity.signingPubkeyB64, isNot(identity.dhPubkeyB64));
    });
  });

  group('helloFrame', () {
    test('signature verifies against the advertised pubkey', () async {
      final identity = await DapIdentity.generate();
      final frame = await helloFrame(identity, name: 'ext-agent');

      final unsigned = Map<String, dynamic>.from(frame)..remove('sig');
      expect(
        await verifyFrame(
          unsigned,
          frame['sig'] as String,
          SimplePublicKey(
            base64Decode(identity.signingPubkeyB64),
            type: KeyPairType.ed25519,
          ),
        ),
        isTrue,
      );
    });

    test('signature is bound to the frame content', () async {
      final identity = await DapIdentity.generate();
      final frame = await helloFrame(identity);
      final tampered = Map<String, dynamic>.from(frame)..remove('sig');
      tampered['name'] = 'spoofed';
      expect(
        await verifyFrame(
          tampered,
          frame['sig'] as String,
          SimplePublicKey(
            base64Decode(identity.signingPubkeyB64),
            type: KeyPairType.ed25519,
          ),
        ),
        isFalse,
      );
    });

    test('carries a fresh ts and a >=16-char hex nonce', () async {
      final before = DateTime.now().millisecondsSinceEpoch;
      final frame = await helloFrame(await DapIdentity.generate());
      final after = DateTime.now().millisecondsSinceEpoch;

      expect(frame['v'], 1);
      expect(frame['op'], 'hello');
      expect(frame['ts'], inInclusiveRange(before, after));
      final nonce = frame['nonce'] as String;
      expect(nonce.length, greaterThanOrEqualTo(16));
      expect(nonce, matches(RegExp(r'^[0-9a-f]+$')));
    });

    test('omits empty names, keeps real ones', () async {
      final identity = await DapIdentity.generate();
      expect((await helloFrame(identity)).containsKey('name'), isFalse);
      expect((await helloFrame(identity, name: 'x'))['name'], 'x');
    });
  });

  group('DM payload crypto', () {
    test('round-trips between two generated identities', () async {
      final alice = await DapIdentity.generate();
      final bob = await DapIdentity.generate();
      const frameId = '0197-fid';

      final ciphertext = await encryptDm(
        alice,
        bob.dhPubkeyB64,
        frameId,
        bob.agentId,
        'hello bob',
      );
      final plaintext = await decryptDm(
        bob,
        alice.dhPubkeyB64,
        frameId,
        ciphertext,
      );
      expect(plaintext, 'hello bob');
    });

    test('a third party cannot decrypt', () async {
      final alice = await DapIdentity.generate();
      final bob = await DapIdentity.generate();
      final mallory = await DapIdentity.generate();

      final ciphertext = await encryptDm(
        alice,
        bob.dhPubkeyB64,
        'frame-1',
        bob.agentId,
        'secret',
      );
      expect(
        () => decryptDm(mallory, alice.dhPubkeyB64, 'frame-1', ciphertext),
        throwsA(anything),
      );
    });

    test('cross-route payloads fail the AEAD tag (AAD binding)', () async {
      final alice = await DapIdentity.generate();
      final bob = await DapIdentity.generate();
      final carol = await DapIdentity.generate();

      // Encrypted for bob (AAD target = bob.agentId).
      final ciphertext = await encryptDm(
        alice,
        bob.dhPubkeyB64,
        'frame-1',
        bob.agentId,
        'secret',
      );
      // Carol decrypting fails: the AAD target is her own agentId.
      expect(
        () => decryptDm(carol, alice.dhPubkeyB64, 'frame-1', ciphertext),
        throwsA(anything),
      );
      // Bob decrypting succeeds — the AAD binds the DM route.
      expect(
        await decryptDm(bob, alice.dhPubkeyB64, 'frame-1', ciphertext),
        'secret',
      );
    });
  });

  group('sendFrame', () {
    test('carries to/id/ts/ciphertext and verifies', () async {
      final alice = await DapIdentity.generate();
      final frame = await sendFrame(
        from: alice,
        to: '0123456789abcdef',
        ciphertext: 'box',
        frameId: 'abc',
        ts: 1756700000000,
      );

      expect(frame['op'], 'send');
      expect(frame['to'], '0123456789abcdef');
      expect(frame['id'], 'abc');
      expect(frame['ts'], 1756700000000);
      final unsigned = Map<String, dynamic>.from(frame)..remove('sig');
      expect(
        await verifyFrame(
          unsigned,
          frame['sig'] as String,
          SimplePublicKey(
            base64Decode(alice.signingPubkeyB64),
            type: KeyPairType.ed25519,
          ),
        ),
        isTrue,
      );
    });
  });

  group('frame builders', () {
    test('whois/flush are unsigned minimal frames', () {
      expect(whoisFrame('abc'), {'op': 'whois', 'agentId': 'abc'});
      expect(flushFrame(), {'op': 'flush'});
    });

    test('presence_query carries the id echoed back as replyTo', () {
      final frame = presenceQueryFrame('req-1');
      expect(frame, {'op': 'presence_query', 'id': 'req-1'});
    });

    test('join is signed (wire completeness; channels v1 unused)', () async {
      final identity = await DapIdentity.generate();
      final frame = await joinFrame(
        identity: identity,
        channel: 'general',
        chanPubkey: identity.dhPubkeyB64,
      );
      final unsigned = Map<String, dynamic>.from(frame)..remove('sig');
      expect(
        await verifyFrame(
          unsigned,
          frame['sig'] as String,
          SimplePublicKey(
            base64Decode(identity.signingPubkeyB64),
            type: KeyPairType.ed25519,
          ),
        ),
        isTrue,
      );
    });
  });

  group('reconnectBackoff', () {
    test('doubles from 1 s and caps at 30 s', () {
      final expected = const {
        0: 1,
        1: 1,
        2: 2,
        3: 4,
        4: 8,
        5: 16,
        6: 30, // 1 << 5 = 32, clamped
        7: 30,
        50: 30,
      };
      expected.forEach((attempt, seconds) {
        expect(
          reconnectBackoff(attempt),
          Duration(seconds: seconds),
          reason: 'attempt $attempt',
        );
      });
    });
  });

  group('undecryptable mapping', () {
    test('maps an undecryptable payload to placeholder text', () {
      expect(
        undecryptableText('abc123'),
        '[hub] undecryptable message from abc123',
      );
    });

    test(
      'wrong-key and tampered payloads decrypt to null → placeholder',
      () async {
        final alice = await DapIdentity.generate();
        final bob = await DapIdentity.generate();
        final ciphertext = await encryptDm(
          alice,
          bob.dhPubkeyB64,
          'frame-1',
          bob.agentId,
          'hello',
        );
        final corrupted =
            '${ciphertext.substring(0, ciphertext.length - 4)}AAAA';

        String? recovered;
        try {
          recovered = await decryptDm(
            bob,
            alice.dhPubkeyB64,
            'frame-1',
            corrupted,
          );
        } on Object {
          recovered = null; // dap_client maps any throw to the placeholder
        }
        expect(recovered, isNull);
        expect(
          recovered ?? undecryptableText(alice.agentId),
          '[hub] undecryptable message from ${alice.agentId}',
        );
      },
    );
  });

  group('MailDeduper', () {
    test('suppresses exact (from, text) duplicates only', () {
      final deduper = MailDeduper();
      expect(deduper.first('a', 'hi'), isTrue);
      expect(deduper.first('a', 'hi'), isFalse);
      expect(deduper.first('b', 'hi'), isTrue);
      expect(deduper.first('a', 'ho'), isTrue);
    });

    test('evicts the oldest entry once the window overflows', () {
      final deduper = MailDeduper(capacity: 2);
      expect(deduper.first('a', '1'), isTrue);
      expect(deduper.first('b', '2'), isTrue);
      expect(deduper.first('c', '3'), isTrue); // evicts ('a','1')
      expect(deduper.first('a', '1'), isTrue); // seen again → delivered again
    });
  });
}
