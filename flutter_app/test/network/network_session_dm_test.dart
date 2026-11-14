import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_session.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show NetworkEnvelope, NetworkEnvelopeKind;
// The fanet1 DM primitives are pure Dart in the messaging core.
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/messaging/hub_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const dmChannel = 'dm:user:u-1:fa@dev-1';

final class FakeDmConnector implements DeviceConnectorService {
  final dmMailController = StreamController<NetworkEnvelope>.broadcast();
  final sent =
      <({String deviceId, String agentName, String? sessionId, String text})>[];
  String? peerDmPub;

  @override
  Stream<NetworkEnvelope> get dmMail => dmMailController.stream;

  @override
  Future<String> accountUserId() async => 'u-1';

  @override
  String? agentDmPub({required String deviceId, required String agentName}) =>
      peerDmPub;

  @override
  Future<String> sendDmToAgent({
    required String deviceId,
    required String agentName,
    String? sessionId,
    required String text,
  }) async {
    sent.add((
      deviceId: deviceId,
      agentName: agentName,
      sessionId: sessionId,
      text: text,
    ));
    return 'dm-msg-1';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('parseDmChannelId', () {
    test('parses the virtual channel id and rejects malformed shapes', () {
      final parts = parseDmChannelId(dmChannel)!;
      expect(parts.userId, 'u-1');
      expect(parts.agentName, 'fa');
      expect(parts.deviceId, 'dev-1');
      expect(parseDmChannelId('c1'), isNull);
      expect(parseDmChannelId('dm:user:u-1'), isNull);
      expect(parseDmChannelId('dm:user:u-1:fa'), isNull);
      expect(parseDmChannelId('dm:user::fa@dev-1'), isNull);
    });
  });

  group('NetworkSession DM channels', () {
    late FakeHttpClient httpClient;
    late FakeWsConnector wsConnector;
    late FakeDmConnector dmConnector;
    late KeyWallet wallet;
    late ({String pub, String priv}) channelKeys;

    setUp(() async {
      httpClient = FakeHttpClient();
      wsConnector = FakeWsConnector();
      dmConnector = FakeDmConnector();
      channelKeys = await EnvelopeCodec.newX25519KeyPair();
      addTearDown(dmConnector.dmMailController.close);
    });

    Future<SimplePublicKey> identityPub() async => SimplePublicKey(
      base64Decode(wallet.identityPub!),
      type: KeyPairType.x25519,
    );

    Future<NetworkSession> session() async {
      wallet = await walletWithChannel(
        channelPub: channelKeys.pub,
        channelPriv: channelKeys.priv,
      );
      final s = buildSession(
        httpClient: httpClient,
        connector: wsConnector,
        wallet: wallet,
      );
      s.attachDmConnector(dmConnector);
      addTearDown(s.dispose);
      return s;
    }

    test(
      'openChannel adds synthetic metadata and resolves empty history',
      () async {
        httpClient.respond(200, body: '{"items":[],"nextCursor":""}');
        final s = await session();
        await s.openChannel(dmChannel);
        expect(s.channels.any((c) => c.id == dmChannel), isTrue);
        expect(s.channelStates[dmChannel]!.historyResolved, isTrue);
        expect(s.channelStates[dmChannel]!.messages, isEmpty);
      },
    );

    test(
      'sendText routes through the connector and appends own message',
      () async {
        final s = await session();
        s.dmSessionTargets[dmChannel] = 'sess-1';
        await s.sendText(dmChannel, 'hello agent');
        expect(dmConnector.sent.single.deviceId, 'dev-1');
        expect(dmConnector.sent.single.agentName, 'fa');
        expect(dmConnector.sent.single.sessionId, 'sess-1');
        expect(dmConnector.sent.single.text, 'hello agent');
        final message = s.channelStates[dmChannel]!.messages.single;
        expect(message.envelopeId, 'dm-msg-1');
        expect(message.text, 'hello agent');
        expect(message.isOwn, isTrue);
      },
    );

    test('history rows decrypt: agent reply and own wrapped text', () async {
      final s = await session();
      final userPub = await identityPub();
      final agentKeys = await X25519().newKeyPair();
      final agentPub = await agentKeys.extractPublicKey();
      dmConnector.peerDmPub = base64Encode(agentPub.bytes);

      // Agent → user frame (sealed to the user's identity pub).
      final reply = await hubSealFanet1(
        senderDhKeyPair: agentKeys,
        recipientDhPubkey: userPub,
        frameId: 'dm-a1',
        aadTarget: dmChannel,
        plaintext: 'pong from agent',
      );
      // User → agent own frame (sealed to the agent's dmPub, sender id
      // is the account user id — the server canonical form).
      final own = await hubSealFanet1(
        senderDhKeyPair: await wallet.identityKeyPair(),
        recipientDhPubkey: agentPub,
        frameId: 'dm-u1',
        aadTarget: dmChannel,
        plaintext: jsonEncode({'text': 'ping', 'sessionId': 'sess-1'}),
      );
      httpClient.respond(
        200,
        body: jsonEncode({
          'items': [
            {
              'id': 'dm-u1',
              'channelId': dmChannel,
              'senderId': 'u-1',
              'payload': own,
              'createdAt': '2026-11-14T10:00:00.000Z',
            },
            {
              'id': 'dm-a1',
              'channelId': dmChannel,
              'senderId': 'fa@dev-1',
              'payload': reply,
              'createdAt': '2026-11-14T10:00:01.000Z',
            },
          ],
          'nextCursor': '',
        }),
      );
      await s.openChannel(dmChannel);
      final messages = s.channelStates[dmChannel]!.messages;
      expect(messages, hasLength(2));
      expect(messages[0].text, 'ping');
      expect(messages[0].isOwn, isTrue);
      expect(messages[1].text, 'pong from agent');
      expect(messages[1].isOwn, isFalse);
      expect(messages[1].senderName, 'fa');
    });

    test('live connector dmMail appends into the open channel store', () async {
      httpClient.respond(200, body: '{"items":[],"nextCursor":""}');
      final s = await session();
      await s.openChannel(dmChannel);
      final userPub = await identityPub();
      final agentKeys = await X25519().newKeyPair();
      final sealed = await hubSealFanet1(
        senderDhKeyPair: agentKeys,
        recipientDhPubkey: userPub,
        frameId: 'dm-live-1',
        aadTarget: dmChannel,
        plaintext: 'live reply',
      );
      dmConnector.dmMailController.add(
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.mail,
          msgId: 'dm-live-1',
          network: 'personal',
          channel: dmChannel,
          from: 'fa@dev-1',
          to: 'user:u-1',
          ts: '2026-11-14T10:00:00.000Z',
          ciphertext: sealed,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final messages = s.channelStates[dmChannel]!.messages;
      expect(messages.single.text, 'live reply');
      expect(messages.single.isOwn, isFalse);
      // Dedup by msgId: the same frame again appends nothing.
      dmConnector.dmMailController.add(
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.mail,
          msgId: 'dm-live-1',
          network: 'personal',
          channel: dmChannel,
          from: 'fa@dev-1',
          to: 'user:u-1',
          ts: '2026-11-14T10:00:00.000Z',
          ciphertext: sealed,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(s.channelStates[dmChannel]!.messages, hasLength(1));
    });
  });
}
