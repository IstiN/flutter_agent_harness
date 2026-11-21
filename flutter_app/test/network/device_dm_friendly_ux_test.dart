// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/network/channel_chat_service.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/network_chat_page.dart';
import 'package:fa_ui/fa_ui.dart' show FaChatDeliveryStatus;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _dmChannel =
    'dm:user:u-1:vladimir-klyshevich@8e208041337a00000000000000000000000000000000000000000000000000000000';

Future<NetworkSession> _sessionWithMessages() async {
  final wallet = await KeyWallet.load(MemoryWalletBackend());
  await wallet.createIfMissing(displayName: 'Me');
  final session = buildSession(
    httpClient: FakeHttpClient(),
    connector: FakeWsConnector(),
    wallet: wallet,
    jwtToken: 'jwt-account',
  );
  session.channels = [
    const Channel(
      id: _dmChannel,
      networkId: 'net1',
      name: 'Duo · vladimir-klyshevich',
    ),
  ];
  final state = session.channelStates.putIfAbsent(_dmChannel, ChannelState.new);
  state.add(
    const ChannelMessage(
      envelopeId: 'foreign-own-1',
      senderId: 'u-1',
      senderPub: '',
      text: null,
      isOwn: true,
    ),
  );
  state.add(
    const ChannelMessage(
      envelopeId: 'foreign-reply-2',
      senderId: 'fa@device',
      senderPub: '',
      text: null,
      isOwn: false,
      senderName: 'vladimir-klyshevich',
    ),
  );
  state.add(
    const ChannelMessage(
      envelopeId: 'just-sent-3',
      senderId: 'u-1',
      senderPub: '',
      text: 'just sent in plaintext',
      isOwn: true,
    ),
  );
  state.historyResolved = true;
  return session;
}

void main() {
  test('restored DM labels never fall back to a raw device id', () {
    expect(dmChannelPeerLabel(_dmChannel), 'Device · vladimir-klyshevich');
    expect(
      dmChannelPeerLabel(_dmChannel, deviceLabel: 'Duo'),
      'Duo · vladimir-klyshevich',
    );
    expect(
      dmChannelPeerLabel(_dmChannel, deviceLabel: 'Duo · vladimir-klyshevich'),
      'Duo · vladimir-klyshevich',
      reason: 'restored labels must not duplicate the agent suffix',
    );
    expect(
      dmChannelPeerLabel(
        _dmChannel,
        deviceLabel:
            '8e208041337a00000000000000000000000000000000000000000000000000000000 · vladimir-klyshevich',
      ),
      'Device · vladimir-klyshevich',
      reason: 'legacy raw-device labels are upgraded, not displayed',
    );
    expect(dmChannelPeerLabel(_dmChannel), isNot(contains('8e208041')));
  });

  test(
    'a roster-opened DM keeps its friendly synthetic channel label',
    () async {
      final session = await _sessionWithMessages();
      addTearDown(session.dispose);
      session.channels = const [];
      session.prepareDmChannel(_dmChannel);
      expect(session.channels.single.name, 'Device · vladimir-klyshevich');
      session.prepareDmChannel(_dmChannel, deviceLabel: 'Duo');
      expect(session.channels.single.name, 'Duo · vladimir-klyshevich');
    },
  );

  test(
    'delivery receipts stay out of the transcript and update their own bubble',
    () async {
      const sessionId = '01a15985-f6c3-7e9e-b16b-203817f2a9c2';
      final state = ChannelState();
      state.add(
        const ChannelMessage(
          envelopeId: 'original-1',
          senderId: 'u-1',
          senderPub: '',
          text: 'сделал',
          isOwn: true,
          sessionId: sessionId,
        ),
      );
      // 1.0.751 receipts have no replyTo: infer the preceding own envelope.
      for (final id in const ['queued-1', 'queued-2']) {
        state.add(
          ChannelMessage(
            envelopeId: id,
            senderId: 'main@device',
            senderPub: '',
            text: 'queued / not listening',
            isOwn: false,
            sessionId: sessionId,
          ),
        );
      }
      // A current peer carries the original id explicitly; it must coalesce
      // with the legacy retries too, while a second user turn gets new state.
      state.add(
        const ChannelMessage(
          envelopeId: 'queued-3',
          senderId: 'main@device',
          senderPub: '',
          text: 'queued / not listening',
          isOwn: false,
          sessionId: sessionId,
          replyTo: 'original-1',
        ),
      );
      state.add(
        const ChannelMessage(
          envelopeId: 'original-2',
          senderId: 'u-1',
          senderPub: '',
          text: 'second turn',
          isOwn: true,
          sessionId: sessionId,
        ),
      );
      state.add(
        const ChannelMessage(
          envelopeId: 'queued-4',
          senderId: 'main@device',
          senderPub: '',
          text: 'queued / not listening',
          isOwn: false,
          sessionId: sessionId,
          replyTo: 'original-2',
        ),
      );
      state.add(
        const ChannelMessage(
          envelopeId: 'accepted-1',
          senderId: 'main@device',
          senderPub: '',
          text: 'accepted, awaiting steering',
          isOwn: false,
          sessionId: sessionId,
          replyTo: 'original-1',
        ),
      );

      expect(
        state.seen,
        containsAll(const ['queued-1', 'queued-2', 'queued-3']),
      );
      expect(state.messages, hasLength(5));
      expect(
        state.messages.where(
          (message) =>
              message.text == 'queued / not listening' ||
              message.text == 'accepted, awaiting steering',
        ),
        hasLength(3),
        reason: 'transport dedup retains one record per state per original',
      );

      final session = buildSession(
        httpClient: FakeHttpClient(),
        connector: FakeWsConnector(),
        wallet: await KeyWallet.load(MemoryWalletBackend()),
      );
      addTearDown(session.dispose);
      session.channelStates[_dmChannel] = state;
      final chat = ChannelChatService(
        session: session,
        channelId: _dmChannel,
        dmSessionId: sessionId,
      );
      addTearDown(chat.dispose);
      expect(chat.messages, hasLength(2));
      expect(chat.messages.every((message) => message.role == 'user'), isTrue);
      expect(chat.messages[0].deliveryStatus, FaChatDeliveryStatus.accepted);
      expect(chat.messages[1].deliveryStatus, FaChatDeliveryStatus.queued);
      expect(
        chat.messages.where(
          (message) =>
              message.content.contains('queued / not listening') ||
              message.content.contains('accepted, awaiting steering'),
        ),
        isEmpty,
      );
    },
  );

  test('raw UUID reply titles use the friendly CLI display chain', () async {
    const sessionId = '01a0ca2d-c767-7e9e-b16b-203817f2a98912';
    final state = ChannelState();
    state.add(
      const ChannelMessage(
        envelopeId: 'reply-1',
        senderId: 'main@device',
        senderPub: '',
        senderName: sessionId,
        text: 'Done',
        isOwn: false,
        sessionId: sessionId,
      ),
    );
    final session = buildSession(
      httpClient: FakeHttpClient(),
      connector: FakeWsConnector(),
      wallet: await KeyWallet.load(MemoryWalletBackend()),
    );
    addTearDown(session.dispose);
    session.channelStates[_dmChannel] = state;
    final chat = ChannelChatService(
      session: session,
      channelId: _dmChannel,
      dmSessionId: sessionId,
    );
    addTearDown(chat.dispose);

    expect(chat.messages.single.content, '**CLI · 01a0ca2d…8912**\n\nDone');
    expect(chat.messages.single.content, isNot(contains(sessionId)));
  });

  test(
    'consecutive foreign-encrypted rows collapse without hiding own text',
    () async {
      final session = await _sessionWithMessages();
      addTearDown(session.dispose);
      final chat = ChannelChatService(
        session: session,
        channelId: _dmChannel,
        dmUndecryptablePlaceholder: () => 'Encrypted on another device',
        dmEncryptedHistoryDivider: () =>
            'Earlier messages are encrypted on other devices',
      );
      addTearDown(chat.dispose);

      expect(chat.messages, hasLength(2));
      expect(chat.messages[0].role, 'widget');
      expect(chat.messages[0].data, 'dmEncryptedHistoryDivider');
      expect(
        chat.messages[0].content,
        'Earlier messages are encrypted on other devices',
      );
      expect(chat.messages[1].role, 'user');
      expect(chat.messages[1].content, 'just sent in plaintext');
    },
  );

  testWidgets('DM header/composer are friendly and encrypted history is one '
      'subtle divider', (tester) async {
    final session = await _sessionWithMessages();
    addTearDown(session.close);
    final manager = NetworkSessionManager(
      baseUrl: testBase,
      wallet: await KeyWallet.load(MemoryWalletBackend()),
      httpClient: FakeHttpClient(),
      wsConnector: FakeWsConnector(),
    );
    manager.sessions['net1'] = session;
    addTearDown(manager.disconnectAll);
    final controller = NetworkModeController.inMemory(
      mode: AppMode.network,
      networkId: 'net1',
      channelId: _dmChannel,
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
            projectLabel: 'personal-f8b4e2a600c4',
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }

    expect(find.text('Duo · vladimir-klyshevich'), findsWidgets);
    expect(find.textContaining('personal-f8b4e2a600c4'), findsNothing);
    expect(find.textContaining('8e208041337a'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Message Duo · vladimir-klyshevich',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('dmEncryptedHistoryDivider')),
      findsOneWidget,
    );
    expect(
      find.text('Earlier messages are encrypted on other devices'),
      findsOneWidget,
    );
    expect(find.textContaining('Encrypted on another device'), findsNothing);
    expect(find.textContaining('just sent in plaintext'), findsOneWidget);
    await session.close();
  });

  testWidgets(
    'DM session id fallback is short in the header and one-line hint',
    (tester) async {
      const sessionId = '01a15985-f6c3-7e9e-b16b-203817f2a9c2';
      final session = await _sessionWithMessages();
      addTearDown(session.close);
      session.selectDmSession(_dmChannel, sessionId, title: 'Duo · $sessionId');
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: await KeyWallet.load(MemoryWalletBackend()),
        httpClient: FakeHttpClient(),
        wsConnector: FakeWsConnector(),
      );
      manager.sessions['net1'] = session;
      addTearDown(manager.disconnectAll);
      final controller = NetworkModeController.inMemory(
        mode: AppMode.network,
        networkId: 'net1',
        channelId: _dmChannel,
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
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }

      expect(find.text('Duo · 01a15985…a9c2'), findsWidgets);
      expect(find.textContaining(sessionId), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.hintText == 'Message Duo · 01a15985…a9c2',
        ),
        findsOneWidget,
      );
      await session.close();
    },
  );
}
