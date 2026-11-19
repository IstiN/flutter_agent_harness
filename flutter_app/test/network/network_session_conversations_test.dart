// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/network/channel_chat_service.dart';
import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/device_dm_session_host.dart';
import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/network_chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/src/network/connector/device_dm_keys.dart';
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/presence_engine.dart'
    show AgentRunState;
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/messaging/hub_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_connector_service_test.dart' as fixture;
import 'fakes.dart';
import 'network_session_dm_test.dart' show FakeDmConnector, dmChannel;

final class _Rig {
  const _Rig(this.session, this.wallet, this.connector);
  final NetworkSession session;
  final KeyWallet wallet;
  final FakeDmConnector connector;
}

final class _ThreadReplyHost implements DeviceDmSessionHost {
  final calls = <({String? sessionId, String text})>[];

  @override
  Future<String?> deliverUserText({
    String? sessionId,
    required String text,
  }) async {
    calls.add((sessionId: sessionId, text: text));
    return 'threaded answer';
  }
}

Future<_Rig> _rig() async {
  final wallet = await KeyWallet.load(MemoryWalletBackend());
  await wallet.createIfMissing(displayName: 'Me');
  final connector = FakeDmConnector();
  final session = buildSession(
    httpClient: FakeHttpClient(),
    connector: FakeWsConnector(),
    wallet: wallet,
    jwtToken: 'jwt-account',
  )..attachDmConnector(connector);
  session.channels = const [
    Channel(id: dmChannel, networkId: 'net1', name: 'Duo · fa'),
  ];
  final state = session.channelStates.putIfAbsent(dmChannel, ChannelState.new);
  state.historyResolved = true;
  addTearDown(session.dispose);
  addTearDown(connector.dmMailController.close);
  return _Rig(session, wallet, connector);
}

ChannelMessage _message(
  String id,
  String text, {
  String? sessionId,
  bool own = true,
}) => ChannelMessage(
  envelopeId: id,
  senderId: own ? 'u-1' : 'fa@dev-1',
  senderPub: '',
  senderName: own ? null : 'fa',
  text: text,
  isOwn: own,
  sessionId: sessionId,
);

void main() {
  test(
    'two sessions and the legacy bucket hold independent DM threads',
    () async {
      final rig = await _rig();
      final state = rig.session.channelStates[dmChannel]!;
      state
        ..add(_message('one-user', 'one question', sessionId: 'one'))
        ..add(_message('one-reply', 'one answer', sessionId: 'one', own: false))
        ..add(_message('two-user', 'two question', sessionId: 'two'))
        ..add(_message('legacy', 'device general'));

      final one = ChannelChatService(
        session: rig.session,
        channelId: dmChannel,
        dmSessionId: 'one',
      );
      final two = ChannelChatService(
        session: rig.session,
        channelId: dmChannel,
        dmSessionId: 'two',
      );
      final general = ChannelChatService(
        session: rig.session,
        channelId: dmChannel,
      );
      addTearDown(one.dispose);
      addTearDown(two.dispose);
      addTearDown(general.dispose);

      expect(one.messages.map((row) => row.content), [
        'one question',
        contains('one answer'),
      ]);
      expect(two.messages.single.content, 'two question');
      expect(general.messages.single.content, 'device general');
      expect(two.transcriptMarkdown(), isNot(contains('one question')));
    },
  );

  test('wrapped own and agent history rows retain their session id', () async {
    final rig = await _rig();
    final userPub = SimplePublicKey(
      base64Decode(rig.wallet.identityPub!),
      type: KeyPairType.x25519,
    );
    final agentKeys = await X25519().newKeyPair();
    final agentPub = await agentKeys.extractPublicKey();
    rig.connector.peerDmPub = base64Encode(agentPub.bytes);
    final reply = await hubSealFanet1(
      senderDhKeyPair: agentKeys,
      recipientDhPubkey: userPub,
      frameId: 'reply-one',
      aadTarget: dmChannel,
      plaintext: jsonEncode({'text': 'answer', 'sessionId': 'one'}),
    );
    final own = await hubSealFanet1(
      senderDhKeyPair: await rig.wallet.identityKeyPair(),
      recipientDhPubkey: agentPub,
      frameId: 'own-two',
      aadTarget: dmChannel,
      plaintext: jsonEncode({
        'text': 'question',
        'sessionId': 'two',
        'threading': 1,
      }),
    );

    final decodedReply = await rig.session.decodeDmEnvelope(
      Envelope(
        id: 'reply-one',
        channelId: dmChannel,
        senderId: 'fa@dev-1',
        payload: reply,
      ),
    );
    final decodedOwn = await rig.session.decodeDmEnvelope(
      Envelope(
        id: 'own-two',
        channelId: dmChannel,
        senderId: 'u-1',
        payload: own,
      ),
    );
    expect(decodedReply.text, 'answer');
    expect(decodedReply.sessionId, 'one');
    expect(decodedOwn.text, 'question');
    expect(decodedOwn.sessionId, 'two');
  });

  test('thread-capable agent replies retain the routed session id', () async {
    const codec = EnvelopeCodec();
    final host = _ThreadReplyHost();
    final tokens = fixture.enrolledTokens();
    final http = FakeHttpClient()
      ..respond(
        200,
        body:
            '{"deviceId":"dev-1","deviceToken":"dt-secret",'
            '"personalNetwork":{"id":"net-personal"}}',
      )
      ..respond(200, body: '{"ticket":"tk-thread-reply"}')
      ..respond(200, body: '{"ticket":"tk-thread-reply-send"}');
    final (service, _, _, transport, _) = await fixture.buildService(
      httpClient: http,
      tokenStore: tokens,
      dmSessionHost: host,
      idFactory: () => 'thread-reply-frame',
    );
    addTearDown(service.dispose);
    await service.start();
    await fixture.pumpUntilOnline(service);
    final user = await EnvelopeCodec.newX25519KeyPair();
    final userKeyPair = await codec.keyPairFromPriv(user.priv);
    final local = await DeviceDmKeyProvider(tokens).loadOrCreate('fa@dev-1');
    const channel = 'dm:user:remote-user:fa@dev-1';
    final ciphertext = await codec.encrypt(
      senderIdentity: userKeyPair,
      channelPub: codec.publicKeyFromB64(local.publicKey),
      frameId: 'thread-request-frame',
      aadTarget: channel,
      plaintext: jsonEncode({
        'text': 'question for two',
        'sessionId': 'two',
        'threading': 1,
      }),
    );
    transport.sockets.first.serverSends(
      NetworkEnvelope(
        kind: NetworkEnvelopeKind.mail,
        msgId: 'thread-request-frame',
        network: 'net-personal',
        channel: channel,
        from: 'user:remote-user',
        to: 'fa@dev-1',
        ts: '2026-11-12T10:00:00.000Z',
        ciphertext: ciphertext,
      ),
    );
    for (var i = 0; i < 200 && host.calls.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    for (var i = 0; i < 200; i++) {
      if (transport.sockets.first.sent.any(
        (frame) =>
            frame.kind == NetworkEnvelopeKind.mail &&
            frame.msgId == 'thread-reply-frame',
      )) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(service.lastStartError, isNull);
    expect(service.phase, DeviceConnectorPhase.online);
    expect(host.calls.single, (sessionId: 'two', text: 'question for two'));
    final reply = transport.sockets.first.sent.singleWhere(
      (frame) =>
          frame.kind == NetworkEnvelopeKind.mail &&
          frame.msgId == 'thread-reply-frame',
    );
    final opened = await codec.decrypt(
      channelKeyPair: userKeyPair,
      frameId: reply.msgId,
      aadTarget: channel,
      payloadB64: reply.ciphertext!,
    );
    expect(jsonDecode(opened.plaintext), {
      'text': 'threaded answer',
      'sessionId': 'two',
      'replyTo': 'thread-request-frame',
    });
  });

  testWidgets('switching rows swaps messages synchronously and sends to the '
      'selected session under its human title', (tester) async {
    final rig = await _rig();
    final state = rig.session.channelStates[dmChannel]!;
    state
      ..add(_message('one-user', 'first session only', sessionId: 'one'))
      ..add(_message('two-user', 'second session only', sessionId: 'two'))
      ..add(_message('legacy', 'legacy general only'));
    final manager = NetworkSessionManager(
      baseUrl: testBase,
      wallet: await KeyWallet.load(MemoryWalletBackend()),
      httpClient: FakeHttpClient(),
      wsConnector: FakeWsConnector(),
    );
    manager.sessions['net1'] = rig.session;
    addTearDown(manager.disconnectAll);
    final controller = NetworkModeController.inMemory(
      mode: AppMode.network,
      networkId: 'net1',
      channelId: dmChannel,
    );
    rig.session.selectDmSession(dmChannel, 'one', title: 'Hero One');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: NetworkChatPage(
            controller: controller,
            manager: manager,
            showAppBar: true,
            showChannelHeader: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Hero One'), findsWidgets);
    expect(find.textContaining('first session only'), findsOneWidget);
    expect(find.textContaining('second session only'), findsNothing);
    expect(find.textContaining('legacy general only'), findsNothing);

    rig.session.selectDmSession(dmChannel, 'two', title: 'Hero Two');
    await tester.pump();
    expect(find.text('Hero Two'), findsWidgets);
    expect(find.text('Hero One'), findsNothing);
    expect(find.textContaining('second session only'), findsOneWidget);
    expect(find.textContaining('first session only'), findsNothing);

    await rig.session.sendText(dmChannel, 'route to second');
    await tester.pump();
    expect(rig.connector.sent.single.sessionId, 'two');
    expect(rig.connector.sent.single.text, 'route to second');
    expect(
      state.messages.any(
        (message) =>
            message.text == 'route to second' && message.sessionId == 'two',
      ),
      isTrue,
    );

    rig.session.selectDmSession(dmChannel, null);
    await tester.pump();
    expect(find.textContaining('legacy general only'), findsOneWidget);
    expect(find.textContaining('route to second'), findsNothing);
    await rig.session.close();
  });

  testWidgets('the DM working banner shows while the peer agent is busy', (
    tester,
  ) async {
    final rig = await _rig();
    rig.connector.peerRunState = AgentRunState.busy;
    rig.session.channelStates[dmChannel]!.add(
      _message('one-user', 'first session only', sessionId: 'one'),
    );
    rig.session.selectDmSession(dmChannel, 'one', title: 'Hero One');
    final manager = NetworkSessionManager(
      baseUrl: testBase,
      wallet: await KeyWallet.load(MemoryWalletBackend()),
      httpClient: FakeHttpClient(),
      wsConnector: FakeWsConnector(),
    );
    manager.sessions['net1'] = rig.session;
    addTearDown(manager.disconnectAll);
    final controller = NetworkModeController.inMemory(
      mode: AppMode.network,
      networkId: 'net1',
      channelId: dmChannel,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: NetworkChatPage(
            controller: controller,
            manager: manager,
            showAppBar: true,
            showChannelHeader: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('dmAgentWorkingBanner')),
      findsOneWidget,
    );
    await rig.session.close();
  });
}
