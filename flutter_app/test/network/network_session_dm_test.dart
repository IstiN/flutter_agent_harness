import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:fa/network/channel_chat_service.dart';
import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/ui/network/network_chat_page.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show AgentRunState, NetworkEnvelope, NetworkEnvelopeKind;
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
  Future<String> Function()? accountUserIdHandler;

  @override
  Stream<NetworkEnvelope> get dmMail => dmMailController.stream;

  @override
  Future<String> accountUserId() =>
      accountUserIdHandler?.call() ?? Future<String>.value('u-1');

  @override
  String? agentDmPub({required String deviceId, required String agentName}) =>
      peerDmPub;

  /// The DM working-banner state: null (hidden) unless a test seeds it.
  AgentRunState? peerRunState;

  @override
  AgentRunState? agentRunState(
    String agentAddress, {
    required String networkId,
  }) => peerRunState;

  @override
  Stream<NetworkEnvelope> get rosterFrames => const Stream.empty();

  @override
  Stream<NetworkEnvelope> get presenceFrames => const Stream.empty();

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

NetworkEnvelope _dmMail({
  String msgId = 'dm-device-1',
  String? channel = dmChannel,
  String? ciphertext = 'not-a-fanet1-frame',
  String? from = 'fa@dev-1',
  String ts = '2026-11-14T10:00:00.000Z',
}) => NetworkEnvelope(
  kind: NetworkEnvelopeKind.mail,
  msgId: msgId,
  network: 'personal',
  channel: channel,
  from: from,
  to: 'user:u-1',
  ts: ts,
  ciphertext: ciphertext,
);

void main() {
  dmAgentBannerTransitionTests();
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

    test('peer label keeps the routing id out of composer/title text', () {
      // Raw device ids are never shown: the generic localized fallback
      // replaces them; a real roster label wins.
      expect(dmChannelPeerLabel(dmChannel), 'Device · fa');
      expect(
        dmChannelPeerLabel(dmChannel, deviceLabel: 'dev-1'),
        'Device · fa',
      );
      expect(dmChannelPeerLabel(dmChannel, deviceLabel: 'Duo'), 'Duo · fa');
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

    test('just-sent own text survives an undecryptable history echo', () async {
      final s = await session();
      await s.sendText(dmChannel, 'hello agent');
      // Simulate the account-WS echo before the peer roster key is available.
      final decoded = await s.decodeDmEnvelope(
        Envelope(
          id: 'dm-msg-1',
          channelId: dmChannel,
          senderId: 'u-1',
          payload: 'not-a-fanet1-frame',
        ),
      );
      expect(decoded.text, 'hello agent');
      expect(decoded.isOwn, isTrue);
      final chat = ChannelChatService(session: s, channelId: dmChannel);
      addTearDown(chat.dispose);
      expect(chat.messages.single.content, 'hello agent');
      expect(chat.messages.single.content, isNot(contains('Encrypted')));
    });

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

    test('roster eviction mid-chat keeps agent replies classified', () async {
      // No peerDmPub seeded: the roster evicted the peer entry, so
      // agentDmPub resolves null — the reported degradation trigger.
      final s = await session();
      final userPub = await identityPub();
      final agentKeys = await X25519().newKeyPair();
      final agentPub = await agentKeys.extractPublicKey();
      // The live backend rewrites ANY authenticated sender to the bare
      // account uid — including the agent's — so both rows arrive with
      // MY sender id; only the frame's seal pubkey tells them apart.
      final reply = await hubSealFanet1(
        senderDhKeyPair: agentKeys,
        recipientDhPubkey: userPub,
        frameId: 'dm-a1',
        aadTarget: dmChannel,
        plaintext: 'pong after eviction',
      );
      final own = await hubSealFanet1(
        senderDhKeyPair: await wallet.identityKeyPair(),
        recipientDhPubkey: agentPub,
        frameId: 'dm-u1',
        aadTarget: dmChannel,
        plaintext: jsonEncode({'text': 'ping'}),
      );

      final decodedReply = await s.decodeDmEnvelope(
        Envelope(
          id: 'dm-a1',
          channelId: dmChannel,
          senderId: 'u-1',
          payload: reply,
        ),
      );
      expect(decodedReply.isOwn, isFalse);
      expect(decodedReply.text, 'pong after eviction');
      expect(decodedReply.senderName, 'fa');
      // Same rewritten sender id, but sealed with MY identity: stays own.
      final decodedOwn = await s.decodeDmEnvelope(
        Envelope(
          id: 'dm-u1',
          channelId: dmChannel,
          senderId: 'u-1',
          payload: own,
        ),
      );
      expect(decodedOwn.isOwn, isTrue);
    });

    test(
      'another device gets an honest placeholder in both directions',
      () async {
        await session();
        final originPub = await identityPub();
        final agentKeys = await X25519().newKeyPair();
        final agentPub = await agentKeys.extractPublicKey();
        dmConnector.peerDmPub = base64Encode(agentPub.bytes);
        final own = await hubSealFanet1(
          senderDhKeyPair: await wallet.identityKeyPair(),
          recipientDhPubkey: agentPub,
          frameId: 'dm-u1',
          aadTarget: dmChannel,
          plaintext: jsonEncode({'text': 'from Duo'}),
        );
        final reply = await hubSealFanet1(
          senderDhKeyPair: agentKeys,
          recipientDhPubkey: originPub,
          frameId: 'dm-a1',
          aadTarget: dmChannel,
          plaintext: 'reply to Duo',
        );
        // A second wallet models macOS: same account, different X25519 identity.
        final foreign = await session();
        expect(wallet.identityPub, isNot(base64Encode(originPub.bytes)));
        httpClient.respond(
          200,
          body: jsonEncode({
            'items': [
              {
                'id': 'dm-u1',
                'channelId': dmChannel,
                'senderId': 'u-1',
                'payload': own,
              },
              {
                'id': 'dm-a1',
                'channelId': dmChannel,
                'senderId': 'fa@dev-1',
                'payload': reply,
              },
            ],
            'nextCursor': '',
          }),
        );
        await foreign.openChannel(dmChannel);
        final stored = foreign.channelStates[dmChannel]!.messages;
        expect(stored, hasLength(2));
        expect(stored.map((message) => message.text), [isNull, isNull]);
        // Multi-device contract (PR review r1): the cross-device echo is
        // the same ACCOUNT user on another wallet — an own-shaped
        // placeholder, never projected as an assistant row — while the
        // undecryptable agent reply stays agent-shaped.
        expect(stored.map((message) => message.isOwn), [isTrue, isFalse]);
        expect(stored[1].senderName, 'fa');

        final chat = ChannelChatService(
          session: foreign,
          channelId: dmChannel,
          dmUndecryptablePlaceholder: () => 'Encrypted on another device',
        );
        addTearDown(chat.dispose);
        expect(
          chat.messages.map((message) => message.content),
          everyElement(contains('Encrypted on another device')),
        );
        expect(
          chat.messages.map((message) => message.content),
          everyElement(isNot(contains('unable to decrypt'))),
        );
        expect(chat.transcriptMarkdown(), isNot(contains('undecryptable')));
      },
    );

    test(
      'live device mail ignores incomplete and unopened envelopes',
      () async {
        final s = await session();
        var accountLookups = 0;
        dmConnector.accountUserIdHandler = () async {
          accountLookups++;
          return 'u-1';
        };

        // No open ChannelState means there is nowhere to append the decode.
        dmConnector.dmMailController.add(_dmMail());
        await pumpEventQueue();
        expect(accountLookups, 0);

        final state = s.channelStates.putIfAbsent(dmChannel, ChannelState.new);
        var notifications = 0;
        s.addListener(() => notifications++);
        dmConnector.dmMailController.add(
          _dmMail(msgId: 'missing-channel', channel: null),
        );
        dmConnector.dmMailController.add(
          _dmMail(msgId: 'missing-ciphertext', ciphertext: null),
        );
        await pumpEventQueue();

        expect(accountLookups, 0);
        expect(state.messages, isEmpty);
        expect(state.seen, isEmpty);
        expect(notifications, 0);
      },
    );

    test('live device mail decrypts, appends, and notifies', () async {
      final s = await session();
      final state = s.channelStates.putIfAbsent(dmChannel, ChannelState.new);
      final sealed = await hubSealFanet1(
        senderDhKeyPair: await X25519().newKeyPair(),
        recipientDhPubkey: await identityPub(),
        frameId: 'dm-device-live',
        aadTarget: dmChannel,
        plaintext: jsonEncode({'text': 'device reply', 'sessionId': 'two'}),
      );
      var notifications = 0;
      s.addListener(() => notifications++);

      dmConnector.dmMailController.add(
        _dmMail(msgId: 'dm-device-live', ciphertext: sealed),
      );
      await pumpEventQueue();

      final message = state.messages.single;
      expect(message.text, 'device reply');
      expect(message.sessionId, 'two');
      expect(message.isOwn, isFalse);
      expect(message.createdAt, DateTime.utc(2026, 11, 14, 10));
      expect(state.seen, contains('dm-device-live'));
      expect(notifications, 1);
    });

    test('live device decode does not append into a replaced state', () async {
      final s = await session();
      final original = s.channelStates.putIfAbsent(dmChannel, ChannelState.new);
      final accountId = Completer<String>();
      var accountLookups = 0;
      dmConnector.accountUserIdHandler = () {
        accountLookups++;
        return accountId.future;
      };
      var notifications = 0;
      s.addListener(() => notifications++);

      dmConnector.dmMailController.add(_dmMail(msgId: 'dm-stale-state'));
      for (var i = 0; i < 20 && accountLookups == 0; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(accountLookups, 1);
      final replacement = ChannelState();
      s.channelStates[dmChannel] = replacement;
      accountId.complete('u-1');
      await pumpEventQueue();

      expect(original.messages, isEmpty);
      expect(replacement.messages, isEmpty);
      expect(replacement.seen, isEmpty);
      expect(notifications, 0);
    });

    test(
      'live device decode errors are contained without a placeholder',
      () async {
        final s = await session();
        final state = s.channelStates.putIfAbsent(dmChannel, ChannelState.new);
        dmConnector.accountUserIdHandler = () async {
          throw StateError('connector disconnected');
        };
        var notifications = 0;
        s.addListener(() => notifications++);

        dmConnector.dmMailController.add(_dmMail(msgId: 'dm-decode-error'));
        await pumpEventQueue();

        expect(state.messages, isEmpty);
        expect(state.seen, isEmpty);
        expect(notifications, 0);
      },
    );

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

void dmAgentBannerTransitionTests() {
  const address = 'fa@dev-b';
  const networkId = 'net-personal';
  FakeDmConnector busyConnector() =>
      FakeDmConnector()..peerRunState = AgentRunState.busy;
  group('dmRefreshedAgentRunState (CRAP-decomposed banner transition)', () {
    test('changed + new state when the state changed', () {
      final next = dmRefreshedAgentRunState(
        connector: busyConnector(),
        address: address,
        networkId: networkId,
        current: null,
        mounted: true,
      );
      expect(next.changed, isTrue);
      expect(next.state, AgentRunState.busy);
    });

    test('busy -> agent GONE clears the banner (review #2196 r1)', () {
      final next = dmRefreshedAgentRunState(
        connector: FakeDmConnector(), // peerRunState null = agent absent
        address: address,
        networkId: networkId,
        current: AgentRunState.busy,
        mounted: true,
      );
      expect(next.changed, isTrue);
      expect(next.state, isNull);
    });

    test('unchanged when unmounted, unbound, or same state', () {
      final c = busyConnector();
      final unchanged = dmRefreshedAgentRunState(
        connector: c,
        address: address,
        networkId: networkId,
        current: AgentRunState.busy,
        mounted: true,
      );
      expect(unchanged.changed, isFalse);
      expect(unchanged.state, AgentRunState.busy);
      expect(
        dmRefreshedAgentRunState(
          connector: c,
          address: address,
          networkId: networkId,
          current: null,
          mounted: false,
        ).changed,
        isFalse,
      );
      expect(
        dmRefreshedAgentRunState(
          connector: null,
          address: address,
          networkId: networkId,
          current: null,
          mounted: true,
        ).changed,
        isFalse,
      );
      expect(
        dmRefreshedAgentRunState(
          connector: c,
          address: null,
          networkId: networkId,
          current: null,
          mounted: true,
        ).changed,
        isFalse,
      );
      expect(
        dmRefreshedAgentRunState(
          connector: FakeDmConnector(),
          address: address,
          networkId: networkId,
          current: null,
          mounted: true,
        ).changed,
        isFalse,
        reason: 'agent absent and already hidden → nothing to change',
      );
    });
  });
}
