// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/network/channel_chat_service.dart';
import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/network/fa_network_ws.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:stream_channel/stream_channel.dart';

// ------------------------------------------------------------------ fakes

class _FakeHttpClient extends http.BaseClient {
  final List<({String method, Uri url, String body})> requests = [];
  final List<http.Response> _responses = [];
  int _index = 0;

  void respond(
    int status, {
    String body = '',
    Map<String, String> headers = const {},
  }) {
    _responses.add(http.Response(body, status, headers: headers));
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    requests.add((
      method: request.method,
      url: request.url,
      body: utf8.decode(bodyBytes),
    ));
    if (_index >= _responses.length) {
      throw StateError('unexpected request: ${request.method} ${request.url}');
    }
    final res = _responses[_index++];
    return http.StreamedResponse(
      Stream<Uint8List>.value(res.bodyBytes),
      res.statusCode,
      headers: res.headers,
      request: request,
    );
  }
}

class _FakeChannel extends StreamChannelMixin<String> {
  final StreamController<String> incoming = StreamController<String>(
    sync: true,
  );
  final StreamController<String> outgoing = StreamController<String>(
    sync: true,
  );
  final List<String> sent = [];

  _FakeChannel() {
    outgoing.stream.listen(sent.add);
  }

  @override
  Stream<String> get stream => incoming.stream;

  @override
  StreamSink<String> get sink => outgoing.sink;

  List<Map<String, Object?>> get sentFrames =>
      sent.map((f) => (jsonDecode(f) as Map).cast<String, Object?>()).toList();

  void serverEvent(String type, Object? payload) =>
      incoming.add(jsonEncode({'type': type, 'payload': payload}));
}

class _FakeConnector implements WsConnector {
  final List<_FakeChannel> channels = [];

  @override
  Future<StreamChannel<String>> connect(
    Uri wsUri,
    Map<String, String> headers,
  ) async {
    final channel = _FakeChannel();
    channels.add(channel);
    return channel;
  }
}

// ----------------------------------------------------------------- helpers

const _codec = EnvelopeCodec();

final _base = Uri.parse('https://network.fa1.dev');

const _joinBody =
    '{"sessionToken":"st-1","identity":{"id":"me-1","class":"guest",'
    '"displayName":"Me"},"network":{"id":"net1","name":"fa-team",'
    '"ownerId":"u1","publicChannels":[]}}';

const _channelsBody =
    '[{"id":"c1","networkId":"net1","name":"general","public":false}]';

const _membersBody =
    '[{"id":"me-1","class":"guest","displayName":"Me","presence":"live"},'
    '{"id":"other-1","class":"member","displayName":"Olya","presence":"offline"}]';

Future<String> _encryptAs({
  required ({String pub, String priv}) sender,
  required String channelPub,
  required String envelopeId,
  required String plaintext,
  String channelName = 'general',
}) async {
  final senderKeyPair = await _codec.keyPairFromPriv(sender.priv);
  return _codec.encrypt(
    senderIdentity: senderKeyPair,
    channelPub: _codec.publicKeyFromB64(channelPub),
    frameId: envelopeId,
    channelName: channelName,
    plaintext: plaintext,
  );
}

Future<KeyWallet> _walletWithChannel({
  required String channelPub,
  required String channelPriv,
}) async {
  final wallet = await KeyWallet.load(MemoryWalletBackend());
  await wallet.createIfMissing(displayName: 'Me');
  await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
  await wallet.addChannelKeys(
    networkId: 'net1',
    channel: 'c1',
    pub: channelPub,
    priv: channelPriv,
  );
  return wallet;
}

NetworkSession _buildSession({
  required _FakeHttpClient httpClient,
  required _FakeConnector connector,
  required KeyWallet wallet,
}) {
  final client = FaNetworkClient(
    baseUrl: _base,
    httpClient: httpClient,
    sessionToken: 'st-1',
  );
  final ws = FaNetworkWs(
    baseUrl: _base,
    connector: connector,
    sessionToken: () => 'st-1',
  );
  return NetworkSession(
    networkId: 'net1',
    identity: const JoinedIdentity(
      id: 'me-1',
      memberClass: MemberClass.guest,
      displayName: 'Me',
    ),
    client: client,
    ws: ws,
    wallet: wallet,
  );
}

void main() {
  late ({String pub, String priv}) channelKeys;
  late ({String pub, String priv}) otherIdentity;

  setUp(() async {
    channelKeys = await EnvelopeCodec.newX25519KeyPair();
    otherIdentity = await EnvelopeCodec.newX25519KeyPair();
  });

  group('NetworkSession', () {
    test('start loads channels + roster and connects the socket', () async {
      final httpClient = _FakeHttpClient()
        ..respond(200, body: _channelsBody)
        ..respond(200, body: _membersBody);
      final connector = _FakeConnector();
      final session = _buildSession(
        httpClient: httpClient,
        connector: connector,
        wallet: await _walletWithChannel(
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
      final wallet = await _walletWithChannel(
        channelPub: channelKeys.pub,
        channelPriv: channelKeys.priv,
      );
      final payloadOld = await _encryptAs(
        sender: otherIdentity,
        channelPub: channelKeys.pub,
        envelopeId: 'e-old',
        plaintext: 'привет из прошлого',
      );
      final payloadNew = await _encryptAs(
        sender: otherIdentity,
        channelPub: channelKeys.pub,
        envelopeId: 'e-new',
        plaintext: 'свежее',
      );
      final httpClient = _FakeHttpClient()
        ..respond(200, body: _channelsBody)
        ..respond(200, body: _membersBody)
        ..respond(
          200,
          body: jsonEncode({
            // Server pages newest-first; e-new listed twice (at-least-once).
            'items': [
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
              {
                'id': 'e-old',
                'channelId': 'c1',
                'senderId': 'other-1',
                'payload': payloadOld,
              },
            ],
            'nextCursor': '',
          }),
        );
      final session = _buildSession(
        httpClient: httpClient,
        connector: _FakeConnector(),
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
      final wallet = await _walletWithChannel(
        channelPub: channelKeys.pub,
        channelPriv: channelKeys.priv,
      );
      final httpClient = _FakeHttpClient()
        ..respond(200, body: _channelsBody)
        ..respond(200, body: _membersBody)
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
      final session = _buildSession(
        httpClient: httpClient,
        connector: _FakeConnector(),
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
      final wallet = await _walletWithChannel(
        channelPub: channelKeys.pub,
        channelPriv: channelKeys.priv,
      );
      final httpClient = _FakeHttpClient()
        ..respond(200, body: _channelsBody)
        ..respond(200, body: _membersBody)
        ..respond(200, body: '{"items":[],"nextCursor":""}');
      final connector = _FakeConnector();
      final session = _buildSession(
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
      final otherPayload = await _encryptAs(
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
      final httpClient = _FakeHttpClient()
        ..respond(200, body: _channelsBody)
        ..respond(200, body: _membersBody);
      final connector = _FakeConnector();
      final session = _buildSession(
        httpClient: httpClient,
        connector: connector,
        wallet: await _walletWithChannel(
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

    test('network.drain rebuilds channels + open-channel history', () async {
      final wallet = await _walletWithChannel(
        channelPub: channelKeys.pub,
        channelPriv: channelKeys.priv,
      );
      final httpClient = _FakeHttpClient()
        ..respond(200, body: _channelsBody) // start
        ..respond(200, body: _membersBody) // start
        ..respond(200, body: '{"items":[],"nextCursor":""}') // openChannel
        ..respond(200, body: _channelsBody) // drain refresh
        ..respond(200, body: '{"items":[],"nextCursor":""}'); // drain page
      final connector = _FakeConnector();
      final session = _buildSession(
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
      final httpClient = _FakeHttpClient()
        ..respond(200, body: _joinBody)
        ..respond(200, body: _channelsBody)
        ..respond(200, body: _membersBody);
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final manager = NetworkSessionManager(
        baseUrl: _base,
        wallet: wallet,
        httpClient: httpClient,
        wsConnector: _FakeConnector(),
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
      final httpClient = _FakeHttpClient()
        ..respond(200, body: _joinBody)
        ..respond(200, body: _channelsBody)
        ..respond(200, body: _membersBody);
      final manager = NetworkSessionManager(
        baseUrl: _base,
        wallet: wallet,
        httpClient: httpClient,
        wsConnector: _FakeConnector(),
      );

      final session = await manager.resume('net1');
      expect(manager.sessions['net1'], same(session));
      await manager.disconnectAll();
    });

    test('resume without stored credentials throws', () async {
      final manager = NetworkSessionManager(
        baseUrl: _base,
        wallet: await KeyWallet.load(MemoryWalletBackend()),
        httpClient: _FakeHttpClient(),
        wsConnector: _FakeConnector(),
      );
      expect(() => manager.resume('net1'), throwsStateError);
    });
  });

  group('ChannelChatService', () {
    Future<
      ({
        NetworkSession session,
        ChannelChatService chat,
        _FakeConnector connector,
      })
    >
    buildChat() async {
      final wallet = await _walletWithChannel(
        channelPub: channelKeys.pub,
        channelPriv: channelKeys.priv,
      );
      final payload = await _encryptAs(
        sender: otherIdentity,
        channelPub: channelKeys.pub,
        envelopeId: 'e-1',
        plaintext: 'from olya',
      );
      final httpClient = _FakeHttpClient()
        ..respond(200, body: _channelsBody)
        ..respond(200, body: _membersBody)
        ..respond(
          200,
          body: jsonEncode({
            'items': [
              {
                'id': 'e-1',
                'channelId': 'c1',
                'senderId': 'other-1',
                'payload': payload,
              },
              {
                'id': 'e-garbage',
                'channelId': 'c1',
                'senderId': 'other-1',
                'payload': base64Encode(utf8.encode('garbage')),
              },
            ],
            'nextCursor': '',
          }),
        );
      final connector = _FakeConnector();
      final session = _buildSession(
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
