import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/envelope_codec.dart';
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
        jwtToken: 'jwt-account',
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
        expect(
          httpClient.requests.single.headers['authorization'],
          'Bearer jwt-account',
        );
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

    test('live network WS reply appends and device echo dedups', () async {
      httpClient
        ..respond(200, body: channelsBody)
        ..respond(200, body: membersBody)
        ..respond(200, body: '{"items":[],"nextCursor":""}');
      final s = await session();
      await s.start();
      await pumpEventQueue();
      await s.openChannel(dmChannel);
      await pumpEventQueue();
      final networkChannel = wsConnector.channels.single;
      expect(
        networkChannel.sentFrames.any(
          (frame) =>
              frame['type'] == 'subscribe' && frame['channelId'] == dmChannel,
        ),
        isTrue,
      );
      final userPub = await identityPub();
      final agentKeys = await X25519().newKeyPair();
      final sealed = await hubSealFanet1(
        senderDhKeyPair: agentKeys,
        recipientDhPubkey: userPub,
        frameId: 'dm-live-1',
        aadTarget: dmChannel,
        plaintext: 'live reply',
      );
      networkChannel.serverEvent('envelope', {
        'id': 'dm-live-1',
        'channelId': dmChannel,
        'senderId': 'fa@dev-1',
        'payload': sealed,
        'createdAt': '2026-11-14T10:00:00.000Z',
      });
      await pumpEventQueue();
      final messages = s.channelStates[dmChannel]!.messages;
      expect(messages.single.text, 'live reply');
      expect(messages.single.isOwn, isFalse);
      // Cross-transport dedup by msgId: the device-WS echo appends nothing.
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

    test(
      'history poll appends unseen replies after outgoing and dedups',
      () async {
        httpClient.respond(200, body: '{"items":[],"nextCursor":""}');
        final s = await session();
        await s.openChannel(dmChannel);
        await s.sendText(dmChannel, 'ping');
        final sealed = await hubSealFanet1(
          senderDhKeyPair: await X25519().newKeyPair(),
          recipientDhPubkey: await identityPub(),
          frameId: 'dm-poll-1',
          aadTarget: dmChannel,
          plaintext: 'polled reply',
        );
        final body = jsonEncode({
          'items': [
            {
              'id': 'dm-poll-1',
              'channelId': dmChannel,
              'senderId': 'fa@dev-1',
              'payload': sealed,
              'createdAt': '2026-11-14T10:00:01.000Z',
            },
          ],
          'nextCursor': '',
        });
        httpClient.respond(200, body: body);
        await s.debugPollDmChannels();
        expect(
          httpClient.requests.last.headers['authorization'],
          'Bearer jwt-account',
        );
        final messages = s.channelStates[dmChannel]!.messages;
        expect(messages.map((message) => message.envelopeId), [
          'dm-msg-1',
          'dm-poll-1',
        ]);
        expect(messages.last.text, 'polled reply');
        expect(messages.last.isOwn, isFalse);

        httpClient.respond(200, body: body);
        await s.debugPollDmChannels();
        expect(s.channelStates[dmChannel]!.messages, hasLength(2));
      },
    );
  });
}
