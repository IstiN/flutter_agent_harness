// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/network_chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  group('NetworkChatPage', () {
    late ({String pub, String priv}) channelKeys;
    late ({String pub, String priv}) otherIdentity;

    setUp(() async {
      channelKeys = await EnvelopeCodec.newX25519KeyPair();
      otherIdentity = await EnvelopeCodec.newX25519KeyPair();
    });

    Future<
      ({
        NetworkSession session,
        FakeNetworkChannel channel,
        NetworkSessionManager manager,
      })
    >
    pumpChat(WidgetTester tester) async {
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
        ..respond(200, body: channelsBody) // start: channels
        ..respond(200, body: membersBody) // start: members
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
      addTearDown(session.close);
      await session.start();
      final controller = NetworkModeController.inMemory(
        mode: AppMode.network,
        networkId: 'net1',
        channelId: 'c1',
      );
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: FakeHttpClient(),
        wsConnector: FakeWsConnector(),
      );
      manager.sessions['net1'] = session;
      addTearDown(manager.disconnectAll);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          home: Scaffold(
            body: NetworkChatPage(controller: controller, manager: manager),
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      return (
        session: session,
        channel: connector.channels.single,
        manager: manager,
      );
    }

    testWidgets('renders the decrypted history as bubbles', (tester) async {
      final rig = await pumpChat(tester);
      expect(find.textContaining('from olya'), findsWidgets);
      expect(find.textContaining('Olya'), findsWidgets);
      // Close inside the body: the WS heartbeat timer must not outlive
      // the test (fake-async invariant).
      await rig.session.close();
    });

    testWidgets('the composer hint names the channel; sending goes to the '
        'socket as ciphertext', (tester) async {
      final rig = await pumpChat(tester);

      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Message general',
      );
      expect(field, findsOneWidget);

      await tester.enterText(field, 'hello channel');
      await tester.tap(find.byKey(const ValueKey('channelSend')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // Optimistic own bubble in the channel state + ciphertext on the wire.
      final messages = rig.session.channelStates['c1']!.messages;
      expect(messages.last.text, 'hello channel');
      expect(messages.last.isOwn, isTrue);
      final frame = rig.channel.sentFrames.lastWhere(
        (f) => f['type'] == 'envelope.send',
      );
      expect(frame['channelId'], 'c1');
      expect(frame['payload']! as String, isNot(contains('hello channel')));
      await rig.session.close();
    });

    testWidgets('network.offline shows the reconnecting banner', (
      tester,
    ) async {
      final rig = await pumpChat(tester);
      expect(find.textContaining('Reconnecting'), findsNothing);

      rig.channel.serverEvent('network.offline', {'reason': 'hub down'});
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(
        find.textContaining('Reconnecting — messages will send when back'),
        findsOneWidget,
      );
      await rig.session.close();
    });
  });
}
