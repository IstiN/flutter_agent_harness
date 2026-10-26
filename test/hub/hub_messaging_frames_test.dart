// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Frame-level coverage for `HubMessagingRepository`'s inbound dispatch
/// (gh-1888 rework): `joined` and `error` hub frames plus PUBLIC channel
/// mail (the raw base64 JSON text contract). The CRAP ratchet measures
/// the merged unit-suite lcov; these branches were invisible to the
/// FakeHub protocol tests because the production `LocalHub` answers
/// joins promptly and never emits foreign channel payloads.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/messaging/hub_crypto.dart';
import 'package:test/test.dart';

const timeout = Timeout(Duration(seconds: 30));

Duration testBackoff(int attempt) => const Duration(milliseconds: 5);

/// Raw-socket hub speaking just enough DAP to steer the repository:
/// hello → welcome; join `ok-channel` → joined (+ a pushed PUBLIC channel
/// message from a fabricated peer); join `denied-channel` → access_denied.
/// [postJoinFrames] adds channel-pushed frames after a successful join of
/// the matching channel (keyed fanet1 / legacy dap1 coverage), and
/// [whoisKey] answers whois with a fixed X25519 key.
final class _FrameHub {
  HttpServer? _server;

  /// channel → extra `msg` frames pushed right after the `joined` ack.
  Map<String, List<Map<String, dynamic>>> postJoinFrames = const {};

  /// agentId → base64 X25519 key answered for `whois`.
  Map<String, String> whoisKeys = const {};

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    unawaited(_serve());
  }

  Uri get url => Uri.parse('ws://127.0.0.1:${_server!.port}/ws');

  Future<void> stop() async {
    await _server?.close(force: true);
  }

  Future<void> _serve() async {
    await for (final request in _server!) {
      unawaited(_handle(await WebSocketTransformer.upgrade(request)));
    }
  }

  Future<void> _handle(WebSocket ws) async {
    try {
      await for (final data in ws) {
        final frame = jsonDecode(data as String) as Map<String, dynamic>;
        switch (frame['op'] as String?) {
          case 'hello':
            final digest = await Sha256().hash(
              base64Decode(frame['pubkey'] as String),
            );
            final agentId = digest.bytes
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join()
                .substring(0, 16);
            ws.add(jsonEncode({'op': 'welcome', 'agentId': agentId}));
          case 'join':
            final channel = frame['channel'] as String?;
            if (channel == 'denied-channel') {
              ws.add(
                jsonEncode({
                  'op': 'error',
                  'code': 'access_denied',
                  'msg': 'not invited',
                }),
              );
            } else {
              ws.add(jsonEncode({'op': 'joined', 'channel': channel}));
              for (final extra in postJoinFrames[channel] ?? const []) {
                ws.add(jsonEncode(extra));
              }
              if (channel == 'ok-channel') {
                // A PUBLIC payload from a fabricated peer: raw base64 of
                // the JSON text contract (what a keyless member decodes).
                ws.add(
                  jsonEncode({
                    'op': 'msg',
                    'id': 'cm-1',
                    'channel': channel,
                    'from': 'fabricated-peer',
                    'ts': 1700000000000,
                    'ciphertext': base64Encode(
                      utf8.encode(jsonEncode({'text': 'hello room'})),
                    ),
                  }),
                );
              }
            }
          case 'whois':
            final agentId = frame['agentId'] as String?;
            final key = whoisKeys[agentId];
            if (key != null) {
              ws.add(
                jsonEncode({
                  'op': 'agent_info',
                  'agentId': agentId,
                  'online': true,
                  'x25519': key,
                }),
              );
            }
          case 'flush':
            ws.add(jsonEncode({'op': 'flushed', 'count': 0}));
        }
      }
    } on Object {
      // socket gone — test teardown
    }
  }
}

void main() {
  late _FrameHub hub;
  late HubMessagingRepository repo;

  setUp(() async {
    hub = _FrameHub();
    await hub.start();
  });

  tearDown(() async {
    await repo.stop();
    await hub.stop();
  });

  /// Poll-drains until channel mail lands (the hub pushes it right after
  /// the join ack; delivery races the drain call).
  Future<List<AgentMessage>> drainUntilNotEmpty() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    do {
      final mail = await repo.drain('main');
      if (mail.isNotEmpty) return mail;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    } while (DateTime.now().isBefore(deadline));
    return const [];
  }

  test(
    'joined frame completes joinChannel; PUBLIC channel mail drains',
    () async {
      repo = HubMessagingRepository(
        url: hub.url,
        transport: const IoHubTransport(),
        backoff: testBackoff,
      );
      await repo.start();
      await repo.joinChannel('ok-channel');
      // The hub pushed a PUBLIC channel message right after the join.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      List<AgentMessage> mail;
      do {
        mail = await repo.drain('main');
        if (mail.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      } while (DateTime.now().isBefore(deadline));
      expect(mail, hasLength(1));
      expect(mail.single.toId, '#ok-channel');
      expect(mail.single.text, 'hello room');
      expect(mail.single.fromId, 'fabricated-peer');
    },
  );

  test('an access_denied error frame fails the pending join with a clear '
      'error', () async {
    repo = HubMessagingRepository(
      url: hub.url,
      transport: const IoHubTransport(),
      backoff: testBackoff,
    );
    await repo.start();
    await expectLater(
      repo.joinChannel('denied-channel'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('hub denied channel join'),
        ),
      ),
    );
  });

  group('keyed channel mail (gh-1888 review: fanet1 first, dap1 fallback)', () {
    late HubIdentity sender;
    late SimpleKeyPair channelPair;
    late HubChannelKeys channelKeys;

    Future<String> fanet1Payload(String frameId, String plaintext) async {
      // Mirrors flutter_app EnvelopeCodec.encrypt byte-for-byte: the raw
      // dap/1 AEAD output wrapped as 0x01 || spk(32) || nonce || ct || tag.
      final dap1 = await hubEncryptPayload(
        sender: sender,
        recipientDhPubkey: await channelPair.extractPublicKey(),
        frameId: frameId,
        aadTarget: 'priv-channel',
        plaintext: plaintext,
      );
      return base64Encode([
        1,
        ...sender.dhPublicKey.bytes,
        ...base64Decode(dap1),
      ]);
    }

    Future<String> legacyDap1Payload(
      String frameId,
      String plaintext, {
      required List<int> nonce,
    }) async {
      // Manual AEAD with a caller-chosen nonce so the payload can be made
      // to LOOK fanet1-shaped (nonce[0] == 1, length >= 61).
      final channelPub = await channelPair.extractPublicKey();
      final ecdh = await X25519().sharedSecretKey(
        keyPair: sender.dhKeyPair,
        remotePublicKey: channelPub,
      );
      final key = await _hkdfSha256(
        ikm: await ecdh.extractBytes(),
        salt: utf8.encode(frameId),
        info: utf8.encode('dap1/v1'),
        length: 32,
      );
      final box = await Chacha20.poly1305Aead().encrypt(
        utf8.encode(plaintext),
        secretKey: SecretKey(key),
        nonce: nonce,
        aad: utf8.encode('dap1|$frameId|priv-channel'),
      );
      return base64Encode([...nonce, ...box.cipherText, ...box.mac.bytes]);
    }

    setUp(() async {
      sender = await HubIdentity.generate();
      channelPair = await X25519().newKeyPair();
      final channelData = await channelPair.extract();
      channelKeys = HubChannelKeys(
        pub: base64Encode(channelData.publicKey.bytes),
        priv: base64Encode(channelData.bytes),
      );
      hub.whoisKeys = {'fabric-peer': sender.dhPubkeyB64};
    });

    test('a fanet1 frame from the CLI fabric decrypts with the channel '
        'key alone (no whois needed)', () async {
      hub.postJoinFrames = {
        'priv-channel': [
          {
            'op': 'msg',
            'id': 'cm-f1',
            'channel': 'priv-channel',
            'from': 'fabric-peer',
            'ts': 1700000000000,
            'ciphertext': await fanet1Payload('cm-f1', 'secret room text'),
          },
        ],
      };
      repo = HubMessagingRepository(
        url: hub.url,
        transport: const IoHubTransport(),
        backoff: testBackoff,
      );
      await repo.start();
      await repo.joinChannel('priv-channel', keys: channelKeys);
      final mail = await drainUntilNotEmpty();
      expect(mail, hasLength(1));
      expect(mail.single.toId, '#priv-channel');
      expect(mail.single.text, 'secret room text');
    });

    test('a legacy dap1 frame still decrypts via whois (interop back)', () async {
      hub.postJoinFrames = {
        'priv-channel': [
          {
            'op': 'msg',
            'id': 'cm-l1',
            'channel': 'priv-channel',
            'from': 'fabric-peer',
            'ts': 1700000000000,
            'ciphertext': await legacyDap1Payload(
              'cm-l1',
              'legacy room text',
              nonce: List<int>.generate(12, (i) => i + 2),
            ),
          },
        ],
      };
      repo = HubMessagingRepository(
        url: hub.url,
        transport: const IoHubTransport(),
        backoff: testBackoff,
      );
      await repo.start();
      await repo.joinChannel('priv-channel', keys: channelKeys);
      final mail = await drainUntilNotEmpty();
      expect(mail.single.text, 'legacy room text');
    });

    test('a fanet1-SHAPED but legacy payload falls back instead of being '
        'dropped (nonce[0] == 1 collision)', () async {
      final plaintext = 'x' * 33; // raw dap1 length lands on exactly 61
      hub.postJoinFrames = {
        'priv-channel': [
          {
            'op': 'msg',
            'id': 'cm-x1',
            'channel': 'priv-channel',
            'from': 'fabric-peer',
            'ts': 1700000000000,
            'ciphertext': await legacyDap1Payload(
              'cm-x1',
              plaintext,
              nonce: [1, ...List<int>.generate(11, (i) => i + 2)],
            ),
          },
        ],
      };
      repo = HubMessagingRepository(
        url: hub.url,
        transport: const IoHubTransport(),
        backoff: testBackoff,
      );
      await repo.start();
      await repo.joinChannel('priv-channel', keys: channelKeys);
      final mail = await drainUntilNotEmpty();
      expect(mail.single.text, plaintext);
    });
  });
}

/// HKDF-SHA256 extract+expand per RFC 5869 (mirrors the production
/// primitive; the package's Hkdf has no `info` parameter).
Future<List<int>> _hkdfSha256({
  required List<int> ikm,
  required List<int> salt,
  required List<int> info,
  required int length,
}) async {
  final prk = await Hmac.sha256().calculateMac(ikm, secretKey: SecretKey(salt));
  var okm = <int>[];
  var previous = const <int>[];
  var counter = 1;
  while (okm.length < length) {
    final block = await Hmac.sha256().calculateMac(
      [...previous, ...info, counter],
      secretKey: SecretKey(prk.bytes),
    );
    previous = block.bytes;
    okm = [...okm, ...block.bytes];
    counter++;
  }
  return okm.sublist(0, length);
}
