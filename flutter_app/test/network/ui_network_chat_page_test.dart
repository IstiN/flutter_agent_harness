// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/network/showcase_viewer.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/network_chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fakes.dart';

import 'package:fa/ui/network/add_agent_dialog.dart';

/// Holds only the channel-list response. The concurrent history request is
/// allowed to finish first, reproducing restored-session first-open timing.
final class _HoldChannelsHttpClient extends FakeHttpClient {
  final Completer<void> channelsReady = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await super.send(request);
    if (request.url.path == '/api/networks/net1/channels') {
      await channelsReady.future;
    }
    return response;
  }
}

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
        FakeHttpClient httpClient,
      })
    >
    pumpChat(
      WidgetTester tester, {
      String channelId = 'c1',
      String? channelName = 'general',
    }) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
      await wallet.addChannelKeys(
        networkId: 'net1',
        channel: channelId,
        pub: channelKeys.pub,
        priv: channelKeys.priv,
      );
      final payload = await encryptAs(
        sender: otherIdentity,
        channelPub: channelKeys.pub,
        envelopeId: 'e-1',
        plaintext: 'from olya',
        aadTarget: channelName ?? channelId,
      );
      final httpClient = FakeHttpClient()
        ..respond(
          200,
          body: jsonEncode([
            {
              'id': channelId,
              'networkId': 'net1',
              'name': ?channelName,
              'public': false,
            },
          ]),
        ) // start: channels
        ..respond(200, body: membersBody) // start: members
        ..respond(
          200,
          body: jsonEncode({
            'items': [
              {
                'id': 'e-1',
                'channelId': channelId,
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
        channelId: channelId,
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
        httpClient: httpClient,
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

    testWidgets('hub-originated envelope renders the envelope senderName '
        '(fa_network#2)', (tester) async {
      final rig = await pumpChat(tester);
      final payload = await encryptAs(
        sender: otherIdentity,
        channelPub: channelKeys.pub,
        envelopeId: 'e-dap',
        plaintext: 'hello from dap',
        aadTarget: 'c1',
      );
      rig.channel.serverEvent('envelope', {
        'id': 'e-dap',
        'channelId': 'c1',
        // A hub agent id — deliberately NOT in the fa_network roster.
        'senderId': '05de571e0cea983f',
        'senderName': 'fa-agent',
        'payload': payload,
      });
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.textContaining('hello from dap'), findsWidgets);
      expect(find.textContaining('fa-agent'), findsWidgets);
      await rig.session.close();
    });

    testWidgets('unnamed title and composer use the short label; rename '
        'updates both live', (tester) async {
      const id =
          '0123456789abcdef0123456789abcdef'
          '0123456789abcdef0123456789abcdef';
      final rig = await pumpChat(tester, channelId: id, channelName: null);
      const fallback = '01234567…';

      expect(find.text(id), findsNothing);
      expect(find.text(fallback), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.hintText == 'Message $fallback',
        ),
        findsOneWidget,
      );

      rig.httpClient.respond(
        200,
        body: jsonEncode({
          'id': id,
          'networkId': 'net1',
          'name': 'ops',
          'public': false,
        }),
      );
      await rig.session.renameChannel(id, 'ops');
      await tester.pump();

      expect(find.text(fallback), findsNothing);
      expect(find.text('ops'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.hintText == 'Message ops',
        ),
        findsOneWidget,
      );
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
      // The shared ChatComposer chrome: the filled send button carries
      // the localized send tooltip (the 'composerTrailingSend' key only
      // exists in the one-action swap slot).
      await tester.tap(find.byTooltip('Send'));
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

    testWidgets('mention menu accepts the highlighted option with Tab', (
      tester,
    ) async {
      final rig = await pumpChat(tester);
      rig.session.roster.addAll({
        'agent-kb': const Member(
          id: 'agent-kb',
          memberClass: MemberClass.agent,
          displayName: 'kb-agent',
          presence: Presence.live,
        ),
        'agent-helper': const Member(
          id: 'agent-helper',
          memberClass: MemberClass.agent,
          displayName: 'kb-helper',
          presence: Presence.offline,
        ),
      });
      rig.session.notifyListeners();
      await tester.pump();
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Message general',
      );
      await tester.enterText(field, '@');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('mentionOption:agent-kb')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, '@kb-agent ');
      expect(
        find.byKey(const ValueKey('mentionOption:agent-kb')),
        findsNothing,
      );
      await rig.session.close();
    });

    testWidgets('mention menu navigates with arrows and accepts with Enter', (
      tester,
    ) async {
      final rig = await pumpChat(tester);
      rig.session.roster.addAll({
        'agent-kb': const Member(
          id: 'agent-kb',
          memberClass: MemberClass.agent,
          displayName: 'kb-agent',
          presence: Presence.live,
        ),
        'agent-helper': const Member(
          id: 'agent-helper',
          memberClass: MemberClass.agent,
          displayName: 'kb-helper',
          presence: Presence.live,
        ),
      });
      rig.session.notifyListeners();
      await tester.pump();
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Message general',
      );
      await tester.enterText(field, '@kb');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, '@kb-helper ');
      await rig.session.close();
    });

    testWidgets('plain Enter sends the draft', (tester) async {
      final rig = await pumpChat(tester);
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Message general',
      );
      await tester.enterText(field, 'sent with enter');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        rig.session.channelStates['c1']!.messages.last.text,
        'sent with enter',
      );
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      await rig.session.close();
    });

    testWidgets('Shift+Enter does not send; it stays editable text', (
      tester,
    ) async {
      final rig = await pumpChat(tester);
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Message general',
      );
      await tester.enterText(field, 'kept in the composer');
      await tester.sendKeyEvent(
        LogicalKeyboardKey.enter,
        modifiers: ModifierKey.shiftModifier,
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      // The draft is not sent and the field keeps its content (the
      // newline insertion itself belongs to the text input layer).
      expect(tester.widget<TextField>(field).controller!.text, isNot(isEmpty));
      expect(
        tester.widget<TextField>(field).controller!.text,
        contains('kept in the composer'),
      );
      expect(
        rig.channel.sentFrames.where((f) => f['type'] == 'envelope.send'),
        isEmpty,
      );
      await rig.session.close();
    });

    testWidgets('Escape dismisses the mention menu without inserting', (
      tester,
    ) async {
      final rig = await pumpChat(tester);
      rig.session.roster.addAll({
        'agent-kb': const Member(
          id: 'agent-kb',
          memberClass: MemberClass.agent,
          displayName: 'kb-agent',
          presence: Presence.live,
        ),
      });
      rig.session.notifyListeners();
      await tester.pump();
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Message general',
      );
      await tester.enterText(field, '@kb');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('mentionOption:agent-kb')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('mentionOption:agent-kb')),
        findsNothing,
      );
      expect(tester.widget<TextField>(field).controller!.text, '@kb');
      await rig.session.close();
    });

    testWidgets('mention autocomplete filters, inserts the literal name, and '
        'resolves its member id on send', (tester) async {
      final rig = await pumpChat(tester);
      rig.session.roster.addAll({
        'agent-kb': const Member(
          id: 'agent-kb',
          memberClass: MemberClass.agent,
          displayName: 'kb-agent',
          presence: Presence.live,
        ),
        'agent-helper': const Member(
          id: 'agent-helper',
          memberClass: MemberClass.agent,
          displayName: 'kb-helper',
          presence: Presence.offline,
        ),
        'agent-other': const Member(
          id: 'agent-other',
          memberClass: MemberClass.agent,
          displayName: 'other-agent',
          presence: Presence.live,
        ),
      });
      rig.session.notifyListeners();
      await tester.pump();

      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Message general',
      );
      await tester.enterText(field, 'hello @kb');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.byKey(const ValueKey('mentionOption:agent-kb')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mentionOption:agent-helper')),
        findsOneWidget,
      );
      expect(find.text('other-agent'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('mentionOption:agent-kb')));
      await tester.pump();
      expect(
        tester.widget<TextField>(field).controller!.text,
        'hello @kb-agent ',
      );

      await tester.enterText(field, 'hello @kb-agent please review');
      await tester.tap(find.byTooltip('Send'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(
        rig.session.channelStates['c1']!.messages.last.text,
        'hello @kb-agent please review',
      );
      final frame = rig.channel.sentFrames.lastWhere(
        (f) => f['type'] == 'envelope.send',
      );
      expect(frame['mentions'], equals(['agent-kb']));
      await rig.session.close();
    });

    testWidgets(
      'private channels expose Add agent in the header (AC-B17 entry)',
      (tester) async {
        final rig = await pumpChat(tester);
        expect(find.byKey(const ValueKey('channelAddAgent')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('channelAddAgent')));
        await tester.pumpAndSettle();
        expect(find.byType(AddAgentDialog), findsOneWidget);
        await rig.session.close();
      },
    );

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

      // The banner offers manual recovery: it restarts the socket and
      // reloads the channels + roster snapshot through the session.
      final before = rig.httpClient.requests.length;
      rig.httpClient
        ..respond(200, body: channelsBody)
        ..respond(200, body: membersBody);
      await tester.tap(find.byTooltip('Reconnect now'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(rig.httpClient.requests, hasLength(before + 2));
      // A healthy fresh socket clears the sticky flag even though the
      // server replays no historical drain to this new connection.
      expect(find.textContaining('Reconnecting'), findsNothing);
      await rig.session.close();
    });

    testWidgets(
      'first open waits for public-channel decoding and never shows the '
      'raw payload',
      (tester) async {
        final payload = encodePublicChannelText('first-open plaintext');
        final httpClient = _HoldChannelsHttpClient()
          ..respond(
            200,
            body:
                '[{"id":"pc1","networkId":"net1","name":"public",'
                '"public":true}]',
          )
          // start() is holding the channel response, so the concurrently
          // opened history consumes this response before members is asked.
          ..respond(
            200,
            body: jsonEncode({
              'items': [
                {
                  'id': 'e-public',
                  'channelId': 'pc1',
                  'senderId': 'hub-agent',
                  'senderName': 'public-agent',
                  'payload': payload,
                },
              ],
              'nextCursor': '',
            }),
          )
          ..respond(200, body: membersBody);
        final wallet = await walletWithChannel(
          channelPub: channelKeys.pub,
          channelPriv: channelKeys.priv,
        );
        final session = buildSession(
          httpClient: httpClient,
          connector: FakeWsConnector(),
          wallet: wallet,
        );
        addTearDown(session.close);
        final controller = NetworkModeController.inMemory(
          mode: AppMode.network,
          networkId: 'net1',
          channelId: 'pc1',
        );
        final manager = NetworkSessionManager(
          baseUrl: testBase,
          wallet: wallet,
          httpClient: FakeHttpClient(),
          wsConnector: FakeWsConnector(),
        );
        manager.sessions['net1'] = session;
        addTearDown(manager.disconnectAll);

        // The manager publishes the session before start() completes. Open
        // the page in that window, with history winning the metadata race.
        unawaited(session.start());
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
        expect(session.channels, isEmpty);
        expect(
          httpClient.requests.map((r) => r.url.path),
          contains('/api/channels/pc1/messages'),
        );
        expect(find.textContaining(payload), findsNothing);

        // Metadata becoming ready must drive the decoded bubble by itself —
        // no channel switch or other manual refresh.
        httpClient.channelsReady.complete();
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(find.textContaining('first-open plaintext'), findsOneWidget);
        expect(find.text('public-agent'), findsOneWidget);
        expect(find.textContaining(payload), findsNothing);
        expect(find.textContaining('unable to decrypt'), findsNothing);

        // The established later behavior is unchanged: revisiting the
        // channel reuses its decoded history and senderName.
        await controller.backToChannels();
        await tester.pump();
        await controller.selectChannel('pc1');
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(find.textContaining('first-open plaintext'), findsOneWidget);
        expect(find.text('public-agent'), findsOneWidget);
        expect(find.textContaining(payload), findsNothing);
        await session.close();
      },
    );
  });
}
