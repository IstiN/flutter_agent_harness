// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_agent_harness/src/messaging/hub_crypto.dart';
import 'package:flutter_agent_harness/src/network/connector/device_dm.dart';
import 'package:flutter_agent_harness/src/network/connector/device_dm_keys.dart';
import 'package:flutter_agent_harness/src/network/connector/device_registry.dart';
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:flutter_agent_harness/src/network/connector/machine_connector.dart';
import 'package:flutter_agent_harness/src/network/connector/upstream_client.dart';
import 'package:test/test.dart';

import 'fake_device_server.dart';

void main() {
  const agentAddress = 'main@device-1';
  const channel = 'dm:user:user-1:main@device-1';

  group('DeviceDmKeyProvider.loadExisting', () {
    test(
      'restores a provisioned key without creating an unknown address',
      () async {
        final store = MemoryDeviceDmKeyStore();
        final provisioned = await DeviceDmKeyProvider(
          store,
        ).loadOrCreate(agentAddress);
        final provider = DeviceDmKeyProvider(store);

        final restored = await provider.loadExisting(agentAddress);

        expect(restored?.publicKey, provisioned.publicKey);
        expect(await provider.loadExisting('other@device-1'), isNull);
        expect(store.keys.keys, {agentAddress});
        expect(store.writes, 1);
      },
    );

    test('a key-store read failure remains transient', () async {
      final provider = DeviceDmKeyProvider(_ThrowingKeyStore());

      expect(
        () => provider.loadExisting(agentAddress),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('DeviceDmCodec', () {
    test(
      'decodes fanet1 metadata and preserves the complete payload',
      () async {
        final store = MemoryDeviceDmKeyStore();
        final agent = await DeviceDmKeyProvider(
          store,
        ).loadOrCreate(agentAddress);
        final user = await hubGenerateX25519KeyPair();
        final userPub = await user.extractPublicKey();
        final plaintext = jsonEncode({
          'text': 'steer this session',
          'sessionId': 'session-1',
          'threading': 1,
        });
        final ciphertext = await hubSealFanet1(
          senderDhKeyPair: user,
          recipientDhPubkey: SimplePublicKey(
            base64Decode(agent.publicKey),
            type: KeyPairType.x25519,
          ),
          frameId: 'frame-1',
          aadTarget: channel,
          plaintext: plaintext,
        );
        final codec = DeviceDmCodec(
          keys: DeviceDmKeyProvider(store),
          deviceId: 'device-1',
        );

        final decoded = await codec.decode(
          _mail(msgId: 'frame-1', channel: channel, ciphertext: ciphertext),
        );

        expect(decoded.payload, plaintext);
        expect(decoded.sessionId, 'session-1');
        expect(decoded.threaded, isTrue);
        expect(decoded.senderPubkey, base64Encode(userPub.bytes));
      },
    );

    test('legacy raw text and non-DM ciphertext pass through', () async {
      final store = MemoryDeviceDmKeyStore();
      final agent = await DeviceDmKeyProvider(store).loadOrCreate(agentAddress);
      final user = await hubGenerateX25519KeyPair();
      final codec = DeviceDmCodec(
        keys: DeviceDmKeyProvider(store),
        deviceId: 'device-1',
      );
      final ciphertext = await hubSealFanet1(
        senderDhKeyPair: user,
        recipientDhPubkey: SimplePublicKey(
          base64Decode(agent.publicKey),
          type: KeyPairType.x25519,
        ),
        frameId: 'frame-raw',
        aadTarget: channel,
        plaintext: 'legacy assistant text',
      );

      final decoded = await codec.decode(
        _mail(msgId: 'frame-raw', channel: channel, ciphertext: ciphertext),
      );
      final plain = await codec.decode(
        _mail(msgId: 'plain', channel: 'channel-1', ciphertext: 'opaque'),
      );

      expect(decoded.payload, 'legacy assistant text');
      expect(decoded.sessionId, isNull);
      expect(decoded.threaded, isFalse);
      expect(plain.payload, 'opaque');
      expect(plain.senderPubkey, isNull);
    });

    for (final testCase in [
      (label: 'malformed fanet1', mutate: (String value) => 'not-fanet1'),
      (
        label: 'tampered ciphertext',
        mutate: (String value) {
          final raw = base64Decode(value);
          raw[raw.length - 1] ^= 1;
          return base64Encode(raw);
        },
      ),
    ]) {
      test(
        '${testCase.label} is a typed permanent rejection without secrets',
        () async {
          final store = MemoryDeviceDmKeyStore();
          final agent = await DeviceDmKeyProvider(
            store,
          ).loadOrCreate(agentAddress);
          final user = await hubGenerateX25519KeyPair();
          final ciphertext = await hubSealFanet1(
            senderDhKeyPair: user,
            recipientDhPubkey: SimplePublicKey(
              base64Decode(agent.publicKey),
              type: KeyPairType.x25519,
            ),
            frameId: 'frame-bad',
            aadTarget: channel,
            plaintext: 'TOP SECRET PLAINTEXT',
          );
          final codec = DeviceDmCodec(
            keys: DeviceDmKeyProvider(store),
            deviceId: 'device-1',
          );

          final error = await _throwing<MailDecodeException>(
            () => codec.decode(
              _mail(
                msgId: 'frame-bad',
                channel: channel,
                ciphertext: testCase.mutate(ciphertext),
              ),
            ),
          );

          expect(error.toString(), isNot(contains('TOP SECRET PLAINTEXT')));
          expect(error.toString(), isNot(contains(agent.privateKey)));
          expect(error.toString(), isNot(contains(agent.publicKey)));
        },
      );
    }

    test(
      'wrong key is a typed permanent rejection without plaintext',
      () async {
        final agentStore = MemoryDeviceDmKeyStore();
        await DeviceDmKeyProvider(agentStore).loadOrCreate(agentAddress);
        final wrongStore = MemoryDeviceDmKeyStore();
        final wrong = await DeviceDmKeyProvider(
          wrongStore,
        ).loadOrCreate('wrong@device-2');
        final user = await hubGenerateX25519KeyPair();
        final ciphertext = await hubSealFanet1(
          senderDhKeyPair: user,
          recipientDhPubkey: SimplePublicKey(
            base64Decode(wrong.publicKey),
            type: KeyPairType.x25519,
          ),
          frameId: 'frame-wrong',
          aadTarget: channel,
          plaintext: 'never render this',
        );
        final codec = DeviceDmCodec(
          keys: DeviceDmKeyProvider(agentStore),
          deviceId: 'device-1',
        );

        final error = await _throwing<MailDecodeException>(
          () => codec.decode(
            _mail(
              msgId: 'frame-wrong',
              channel: channel,
              ciphertext: ciphertext,
            ),
          ),
        );

        expect(error.toString(), isNot(contains('never render this')));
        expect(error.toString(), isNot(contains(wrong.privateKey)));
      },
    );
  });

  group('DeviceDmReplyRoute', () {
    test(
      'normalizes a bare user id and survives the opaque address round-trip',
      () async {
        final store = MemoryDeviceDmKeyStore();
        final agent = await DeviceDmKeyProvider(
          store,
        ).loadOrCreate(agentAddress);
        final user = await hubGenerateX25519KeyPair();
        final userPub = await user.extractPublicKey();
        final codec = DeviceDmCodec(
          keys: DeviceDmKeyProvider(store),
          deviceId: 'device-1',
        );
        final decoded = await codec.decode(
          _mail(
            msgId: 'frame-route',
            channel: channel,
            ciphertext: await hubSealFanet1(
              senderDhKeyPair: user,
              recipientDhPubkey: SimplePublicKey(
                base64Decode(agent.publicKey),
                type: KeyPairType.x25519,
              ),
              frameId: 'frame-route',
              aadTarget: channel,
              plaintext: jsonEncode({
                'text': 'hello',
                'sessionId': 'session-1',
                'threading': 1,
              }),
            ),
          ),
        );
        final mail = InboundMail(
          envelope: _mail(
            msgId: 'frame-route',
            channel: channel,
            from: 'user-1',
            ciphertext: 'not-used-by-route',
          ),
          text: 'hello',
          sessionId: decoded.sessionId,
          senderPubkey: decoded.senderPubkey,
          threaded: decoded.threaded,
        );

        final route = DeviceDmReplyRoute.fromMail(
          mail,
          currentAgentAddress: agentAddress,
        );
        final address = route.toAddress();
        final restored = DeviceDmReplyRoute.parse(address);

        expect(address, startsWith('network-dm:v1:'));
        expect(route.replyRecipient, 'user:user-1');
        expect(restored, route);
        expect(restored.hashCode, route.hashCode);
        expect(restored.sessionId, 'session-1');
        expect(restored.threaded, isTrue);
        expect(restored.senderPubkey, base64Encode(userPub.bytes));
      },
    );

    test('parse rejects malformed addresses without echoing their payload', () {
      expect(
        () => DeviceDmReplyRoute.parse('network-dm:v1:not-base64!'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.toString(),
            'safe message',
            isNot(contains('not-base64')),
          ),
        ),
      );
      expect(
        () => DeviceDmReplyRoute.parse('main'),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'sendDeviceDmReply seals with the minted frame id and existing key',
      () async {
        final server = FakeDeviceServer();
        server.seedDevice('device-1');
        final store = MemoryDeviceDmKeyStore();
        final provider = DeviceDmKeyProvider(store);
        final agent = await provider.loadOrCreate(agentAddress);
        final user = await hubGenerateX25519KeyPair();
        final userPub = await user.extractPublicKey();
        final upstream = ConnectorUpstreamClient(
          url: Uri.parse('wss://fake/ws'),
          transport: server.transport,
          ticketProvider: () async => 'ticket',
          deviceId: 'device-1',
          deviceToken: 'token',
          backoff: (_) => const Duration(milliseconds: 10),
        );
        final registry = await _registry();
        final connector = MachineConnector(
          registry: registry,
          upstream: upstream,
          idFactory: () => 'reply-frame-1',
        );
        await connector.start();
        await _waitUntil(() => connector.isConnected);
        addTearDown(() async {
          await connector.stop();
          connector.dispose();
          registry.dispose();
        });
        final route = DeviceDmReplyRoute(
          network: 'personal-1',
          channel: channel,
          replyRecipient: 'user:user-1',
          agentAddress: agentAddress,
          sessionId: 'session-1',
          senderPubkey: base64Encode(userPub.bytes),
          threaded: true,
        );

        final msgId = await sendDeviceDmReply(
          connector: connector,
          keys: provider,
          route: route,
          reply: 'accepted, awaiting steering',
        );
        await _waitUntil(() => server.persistedMail.isNotEmpty);

        final sent = server.persistedMail.single;
        expect(msgId, 'reply-frame-1');
        expect(sent.msgId, msgId);
        expect(sent.from, agentAddress);
        expect(sent.to, 'user:user-1');
        final opened = hubTryOpenFanet1(sent.ciphertext!);
        expect(opened, isNotNull);
        expect(base64Encode(opened!.senderPubkey.bytes), agent.publicKey);
        final plaintext = await hubDecryptPayloadWithKeyPair(
          recipientDhKeyPair: user,
          senderDhPubkey: opened.senderPubkey,
          frameId: msgId,
          aadTarget: channel,
          ciphertextB64: opened.ciphertextB64,
        );
        expect(jsonDecode(plaintext), {
          'text': 'accepted, awaiting steering',
          'sessionId': 'session-1',
        });
        final missingKeyRoute = DeviceDmReplyRoute(
          network: route.network,
          channel: route.channel,
          replyRecipient: route.replyRecipient,
          agentAddress: 'missing@device-1',
          sessionId: route.sessionId,
          senderPubkey: route.senderPubkey,
          threaded: route.threaded,
        );
        await expectLater(
          () => sendDeviceDmReply(
            connector: connector,
            keys: provider,
            route: missingKeyRoute,
            reply: 'must not send',
          ),
          throwsA(isA<StateError>()),
        );
        expect(server.persistedMail, hasLength(1));
      },
    );
  });

  test('shared channel parser and text wrappers preserve legacy behavior', () {
    expect(parseDeviceDmChannelId(channel), (
      userId: 'user-1',
      agentName: 'main',
      deviceId: 'device-1',
    ));
    expect(parseDeviceDmChannelId('dm:user::main@device-1'), isNull);
    expect(parseDeviceDmChannelId('channel-1'), isNull);
    expect(unwrapDeviceDmText('raw assistant text'), (
      text: 'raw assistant text',
      sessionId: null,
      threaded: false,
    ));
    expect(unwrapDeviceDmText('{not-json').text, '{not-json');
    expect(
      wrapDeviceDmText('reply', sessionId: 'session-1', threaded: true),
      jsonEncode({'text': 'reply', 'sessionId': 'session-1'}),
    );
    expect(
      wrapDeviceDmText('reply', sessionId: null, threaded: false),
      'reply',
    );
  });

  test(
    'route validation rejects incomplete mail and missing opaque fields',
    () {
      final incomplete = InboundMail(
        envelope: _mail(
          msgId: 'plain',
          channel: channel,
          ciphertext: 'ciphertext',
        ),
        text: 'not decoded',
      );
      expect(
        () => DeviceDmReplyRoute.fromMail(
          incomplete,
          currentAgentAddress: agentAddress,
        ),
        throwsA(isA<StateError>()),
      );
      final missingFields = base64UrlEncode(
        utf8.encode('{}'),
      ).replaceAll('=', '');
      expect(
        () => DeviceDmReplyRoute.parse(
          '$deviceDmReplyAddressPrefix$missingFields',
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );
}

NetworkEnvelope _mail({
  required String msgId,
  required String channel,
  required String ciphertext,
  String from = 'user:user-1',
  String to = 'main@device-1',
}) => NetworkEnvelope(
  kind: NetworkEnvelopeKind.mail,
  msgId: msgId,
  network: 'personal-1',
  channel: channel,
  from: from,
  to: to,
  ts: '2026-11-15T10:00:00.000Z',
  ciphertext: ciphertext,
);

Future<DeviceRegistry> _registry() async =>
    DeviceRegistry()..configureNetwork('personal-1', NetworkKind.personal);

Future<T> _throwing<T>(Future<void> Function() body) async {
  try {
    await body();
  } on Object catch (error) {
    expect(error, isA<T>());
    return error as T;
  }
  fail('expected $T');
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition not met within 2s');
}

final class _ThrowingKeyStore implements DeviceDmKeyStore {
  @override
  Future<Map<String, String>> readDmPrivateKeys() async {
    throw StateError('store temporarily unavailable');
  }

  @override
  Future<void> writeDmPrivateKeys(Map<String, String> keys) async {}
}
