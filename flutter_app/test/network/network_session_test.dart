import 'dart:convert';

import 'package:fa/network/channel_chat_service.dart';
import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late ({String pub, String priv}) channelKeys;
  late ({String pub, String priv}) otherIdentity;

  setUp(() async {
    channelKeys = await EnvelopeCodec.newX25519KeyPair();
    otherIdentity = await EnvelopeCodec.newX25519KeyPair();
  });

  group('NetworkSession', () {
    test('start loads channels + roster and connects the socket', () async {
      final httpClient = FakeHttpClient()
        ..respond(200, body: channelsBody)
        ..respond(200, body: membersBody);
      final connector = FakeWsConnector();
      final session = buildSession(
        httpClient: httpClient,
        connector: connector,
        wallet: await walletWithChannel(
          channelPub: channelKeys.pub,
          channelPriv: channelKeys.priv,
        ),
      );
      addTearDown(session.close);

      await session.start();
      await pumpEventQueue();

      expect(session.channels.single.id, 'c1');
      expect(session.roster['other-1']?.displayName, 'Olya');
      expect(connector.channels, isNotEmpty);
    });

    test('openChannel decrypts history oldest-first and dedupes', () async {
      final wallet = await walletWithChannel(
        channelPub: channelKeys.pub,
        channelPriv: channelKeys.priv,
      );
      final payloadOld = await encryptAs(
        sender: otherIdentity,
        channelPub: channelKeys.pub,
        envelopeId: 'e-old',
        plaintext: 'привет из прошлого',
      );
      final payloadNew = await encryptAs(
        sender: otherIdentity,
        channelPub: channelKeys.pub,
        envelopeId: 'e-new',
        plaintext: 'свежее',
      );
      final httpClient = FakeHttpClient()
        ..respond(200, body: channelsBody)
        ..respond(200, body: membersBody)
        ..respond(
          200,
          body: jsonEncode({
            // Chat-order contract: pages ascending oldest-first;
            // e-new listed twice (at-least-once).
            'items': [
              {
                'id': 'e-old',
                'channelId': 'c1',
                'senderId': 'other-1',
                'payload': payloadOld,
              },
              {
                'id': 'e-new',
                'channelId': 'c1',
                'senderId': 'other-1',
                'payload': payloadNew,
              },
              {
                'id': 'e-new',
                'channelId': 'c1',
                'senderId': 'other-1',
                'payload': payloadNew,
              },
            ],
            'nextCursor': '',
          }),
        );
      final session = buildSession(
        httpClient: httpClient,
        connector: FakeWsConnector(),
        wallet: wallet,
      );
      addTearDown(session.close);

      await session.start();
      await session.openChannel('c1');

      final messages = session.channelStates['c1']!.messages;
      expect(messages, hasLength(2));
      expect(messages[0].envelopeId, 'e-old');
      expect(messages[0].text, 'привет из прошлого');
      expect(messages[1].envelopeId, 'e-new');
      expect(messages[1].text, 'свежее');
      expect(messages[1].senderPub, isNotEmpty);
      expect(session.channelStates['c1']!.historyAboveCount, 0);
    });

    test('undecryptable history yields a null-text placeholder', () async {
      final wallet = await walletWithChannel(
        channelPub: channelKeys.pub,
        channelPriv: channelKeys.priv,
      );
      final httpClient = FakeHttpClient()
        ..respond(200, body: channelsBody)
        ..respond(200, body: membersBody)
        ..respond(
          200,
          body: jsonEncode({
            'items': [
              {
                'id': 'e-garbage',
                'channelId': 'c1',
                'senderId': 'other-1',
                'payload': base64Encode(utf8.encode('not a fanet1 frame')),
              },
            ],
            'nextCursor': '',
          }),
        );
      final session = buildSession(
        httpClient: httpClient,
        connector: FakeWsConnector(),
        wallet: wallet,
      );
      addTearDown(session.close);

      await session.start();
      await session.openChannel('c1');

      final message = session.channelStates['c1']!.messages.single;
      expect(message.text, isNull);
      expect(message.senderId, 'other-1');
    });

    test('sendText encrypts, appends optimistically, echoes dedupe', () async {
      final wallet = await walletWithChannel(
        channelPub: channelKeys.pub,
        channelPriv: channelKeys.priv,
      );
      final httpClient = FakeHttpClient()
        ..respond(200, body: channelsBody)
        ..respond(200, body: membersBody)
        ..respond(200, body: '{"items":[],"nextCursor":""}');
      final connector = FakeWsConnector();
      final session = buildSession(
        httpClient: httpClient,
        connector: connector,
        wallet: wallet,
      );
      addTearDown(session.close);

      await session.start();
      await session.openChannel('c1');
      await pumpEventQueue();

      await session.sendText('c1', 'hello channel');
      final state = session.channelStates['c1']!;
      expect(state.messages.single.isOwn, isTrue);
      expect(state.messages.single.text, 'hello channel');

      // The outbound frame: envelope.send with the same id, ciphertext payload.
      final frame = connector.channels.single.sentFrames.lastWhere(
        (f) => f['type'] == 'envelope.send',
      );
      expect(frame['channelId'], 'c1');
      expect(frame['id'], state.messages.single.envelopeId);
      expect(frame['senderKey'], wallet.identityPub); // contract senderKey
      final payload = frame['payload']! as String;
      expect(payload, isNot(contains('hello channel'))); // ciphertext only

      // The relayed echo carries the same id → no duplicate bubble, and
      // the ciphertext round-trips through the AAD binding (frame id =
      // envelope id).
      final channel = connector.channels.single;
      channel.serverEvent('envelope', {
        'id': frame['id'],
        'channelId': 'c1',
        'senderId': 'me-1',
        'payload': payload,
      });
      await pumpEventQueue();
      expect(state.messages, hasLength(1));

      // A fresh envelope from another member decrypts into a new bubble.
      final otherPayload = await encryptAs(
        sender: otherIdentity,
        channelPub: channelKeys.pub,
        envelopeId: 'e-other',
        plaintext: 'hi me',
      );
      channel.serverEvent('envelope', {
        'id': 'e-other',
        'channelId': 'c1',
        'senderId': 'other-1',
        'payload': otherPayload,
      });
      await pumpEventQueue();
      expect(state.messages, hasLength(2));
      expect(state.messages.last.text, 'hi me');
    });

    test('presence.changed updates the roster', () async {
      final httpClient = FakeHttpClient()
        ..respond(200, body: channelsBody)
        ..respond(200, body: membersBody);
      final connector = FakeWsConnector();
      final session = buildSession(
        httpClient: httpClient,
        connector: connector,
        wallet: await walletWithChannel(
          channelPub: channelKeys.pub,
          channelPriv: channelKeys.priv,
        ),
      );
      addTearDown(session.close);

      await session.start();
      await pumpEventQueue();
      expect(session.roster['other-1']?.presence, Presence.offline);

      connector.channels.single.serverEvent('presence.changed', {
        'memberId': 'other-1',
        'presence': 'live',
      });
      await pumpEventQueue();
      expect(session.roster['other-1']?.presence, Presence.live);
    });

    test('public showcase channels bypass E2E both ways', () async {
      final wallet = await walletWithChannel(
        channelPub: channelKeys.pub,
        channelPriv: channelKeys.priv,
      );
      const publicChannels =
          '[{"id":"pc1","networkId":"net1","name":"lobby","public":true}]';
      final httpClient = FakeHttpClient()
        ..respond(200, body: publicChannels)
        ..respond(200, body: membersBody)
        ..respond(
          200,
          body:
              '{"items":[{"id":"e-9","channelId":"pc1","senderId":"other-1",'
              '"payload":"aGVsbG8tdmlzaXRvcg=="}],"nextCursor":""}',
        );
      final connector = FakeWsConnector();
      final session = buildSession(
        httpClient: httpClient,
        connector: connector,
        wallet: wallet,
      );
      addTearDown(session.close);

      await session.start();
      await session.openChannel('pc1');
      await pumpEventQueue();

      // base64("hello-visitor") renders as-is — no chankey involved.
      final state = session.channelStates['pc1']!;
      expect(state.messages.single.text, 'hello-visitor');

      // Sending into a public channel writes the raw payload convention.
      await session.sendText('pc1', 'hi all');
      final frame = connector.channels.single.sentFrames.lastWhere(
        (f) => f['type'] == 'envelope.send',
      );
      expect(
        utf8.decode(base64Decode(frame['payload']! as String)),
        contains('"text":"hi all"'),
      );
    });

    test('network.drain rebuilds channels + open-channel history', () async {
      final wallet = await walletWithChannel(
        channelPub: channelKeys.pub,
        channelPriv: channelKeys.priv,
      );
      final httpClient = FakeHttpClient()
        ..respond(200, body: channelsBody) // start
        ..respond(200, body: membersBody) // start
        ..respond(200, body: '{"items":[],"nextCursor":""}') // openChannel
        ..respond(200, body: channelsBody) // drain refresh
        ..respond(200, body: '{"items":[],"nextCursor":""}'); // drain page
      final connector = FakeWsConnector();
      final session = buildSession(
        httpClient: httpClient,
        connector: connector,
        wallet: wallet,
      );
      addTearDown(session.close);

      await session.start();
      await session.openChannel('c1');
      await pumpEventQueue();

      connector.channels.single.serverEvent('network.offline', {
        'reason': 'hub unreachable',
      });
      await pumpEventQueue();
      expect(session.networkOffline, isTrue);

      connector.channels.single.serverEvent('network.drain', {'count': 0});
      await pumpEventQueue();
      expect(session.networkOffline, isFalse);
      // channels refetched + history page re-pulled
      expect(
        httpClient.requests
            .where((r) => r.url.path.contains('/messages'))
            .length,
        2,
      );
    });
  });

  group('NetworkSessionManager', () {
    test('join records membership + password and starts the session', () async {
      final httpClient = FakeHttpClient()
        ..respond(200, body: joinBodyOk)
        ..respond(200, body: channelsBody)
        ..respond(200, body: membersBody);
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: httpClient,
        wsConnector: FakeWsConnector(),
      );

      final session = await manager.join(
        networkId: 'net1',
        password: 'secret-pw',
        displayName: 'Me',
      );
      await pumpEventQueue();

      expect(manager.sessions['net1'], same(session));
      final entry = wallet.networks['net1']!;
      expect(entry.name, 'fa-team');
      expect(entry.password, 'secret-pw');
      expect(entry.memberClass, 'guest');
      // Guest join: displayName went in the body, no auth header.
      final joinRequest = httpClient.requests.first;
      expect(joinRequest.url.path, '/api/networks/net1/join');
      expect(joinRequest.body, contains('secret-pw'));

      await manager.leave('net1');
      expect(manager.sessions, isEmpty);
      expect(wallet.networks, isEmpty);
    });

    test('resume re-joins silently with the wallet password', () async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        password: 'secret-pw',
      );
      final httpClient = FakeHttpClient()
        ..respond(200, body: joinBodyOk)
        ..respond(200, body: channelsBody)
        ..respond(200, body: membersBody);
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: httpClient,
        wsConnector: FakeWsConnector(),
      );

      final session = await manager.resume('net1');
      expect(manager.sessions['net1'], same(session));
      await manager.disconnectAll();
    });

    test('resume without stored credentials throws', () async {
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: await KeyWallet.load(MemoryWalletBackend()),
        httpClient: FakeHttpClient(),
        wsConnector: FakeWsConnector(),
      );
      expect(() => manager.resume('net1'), throwsStateError);
    });
  });

  group('ChannelChatService', () {
    Future<
      ({
        NetworkSession session,
        ChannelChatService chat,
        FakeWsConnector connector,
      })
    >
    buildChat() async {
      final wallet = await walletWithChannel(
        channelPub: channelKeys.pub,
        channelPriv: channelKeys.priv,
      );
      final payload = await encryptAs(
        sender: otherIdentity,
        channelPub: channelKeys.pub,
        envelopeId: 'e-1',
        plaintext: 'from olya',
      );
      final httpClient = FakeHttpClient()
        ..respond(200, body: channelsBody)
        ..respond(200, body: membersBody)
        ..respond(
          200,
          body: jsonEncode({
            'items': [
              {
                'id': 'e-garbage',
                'channelId': 'c1',
                'senderId': 'other-1',
                'payload': base64Encode(utf8.encode('garbage')),
              },
              {
                'id': 'e-1',
                'channelId': 'c1',
                'senderId': 'other-1',
                'payload': payload,
              },
            ],
            'nextCursor': '',
          }),
        );
      final connector = FakeWsConnector();
      final session = buildSession(
        httpClient: httpClient,
        connector: connector,
        wallet: wallet,
      );
      await session.start();
      await session.openChannel('c1');
      final chat = ChannelChatService(session: session, channelId: 'c1');
      return (session: session, chat: chat, connector: connector);
    }

    test(
      'maps members to bubbles: other named, undecryptable placeholder',
      () async {
        final rig = await buildChat();
        addTearDown(rig.session.close);
        expect(rig.chat.messages, hasLength(2));
        // Oldest first: the garbage envelope predates Olya's message.
        expect(rig.chat.messages[0].content, contains('unable to decrypt'));
        expect(rig.chat.messages[1].role, 'assistant');
        expect(rig.chat.messages[1].content, contains('**Olya**'));
        expect(rig.chat.messages[1].content, contains('from olya'));
      },
    );

    test(
      'sendText goes through the session; own message is a user bubble',
      () async {
        final rig = await buildChat();
        addTearDown(rig.session.close);
        await rig.chat.sendText('my own words');
        final last = rig.chat.messages.last;
        expect(last.role, 'user');
        expect(last.content, 'my own words');
      },
    );

    test('history plumbing proxies the channel state', () async {
      final rig = await buildChat();
      addTearDown(rig.session.close);
      expect(rig.chat.historyAboveCount, 0);
      expect(rig.chat.historyLoading, isFalse);
      expect(rig.chat.historyLoadError, isNull);
      expect(rig.chat.isStreaming, isFalse);
      expect(rig.chat.sandboxEnv, isNull);
      expect(rig.chat.pendingSteerTexts, isEmpty);
      await rig.chat.loadOlderHistory(); // no nextCursor → no-op, no crash
    });

    test('notifies listeners when the session changes', () async {
      final rig = await buildChat();
      addTearDown(rig.session.close);
      var notified = 0;
      rig.chat.addListener(() => notified++);
      await rig.chat.sendText('ping');
      expect(notified, greaterThan(0));
    });
  });
}
