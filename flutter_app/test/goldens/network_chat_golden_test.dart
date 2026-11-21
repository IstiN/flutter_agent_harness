@TestOn('vm')
library;

import 'dart:convert';

import 'package:fa/network/device_display.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/network/showcase_viewer.dart';
import 'package:fa/ui/network/network_chat_page.dart';
import 'package:fa/ui/widgets/fah_wallpaper.dart';
import 'package:fa_ui/fa_ui.dart'
    show FaVisualDirection, buildFaTheme, debugFaGlassAlwaysFake;
import 'package:flutter/material.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart' show Chat;
import 'package:flutter_test/flutter_test.dart';

import '../network/fakes.dart';
import 'golden_test_helper.dart';

Future<void> _pumpChannel(
  WidgetTester tester, {
  required Size size,
  required Brightness brightness,
}) async {
  final wallet = await KeyWallet.load(MemoryWalletBackend());
  await wallet.createIfMissing(displayName: 'Golden User');
  await wallet.addNetwork(
    networkId: 'net1',
    name: 'fa-team',
    memberClass: 'owner',
  );
  final httpClient = FakeHttpClient()
    ..respond(
      200,
      body: '[{"id":"c1","networkId":"net1","name":"general","public":true}]',
    )
    ..respond(200, body: membersBody)
    ..respond(
      200,
      body: jsonEncode({
        'items': [
          {
            'id': 'e-1',
            'channelId': 'c1',
            'senderId': 'other-1',
            'payload': encodePublicChannelText(
              'The channel uses the same wallpaper as a Local session.',
            ),
          },
          {
            'id': 'e-2',
            'channelId': 'c1',
            'senderId': 'me-1',
            'payload': encodePublicChannelText(
              'Only the short header controls float above the transcript.',
            ),
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
  final manager = NetworkSessionManager(
    baseUrl: testBase,
    wallet: wallet,
    httpClient: FakeHttpClient(),
    wsConnector: FakeWsConnector(),
  )..sessions['net1'] = session;
  addTearDown(manager.disconnectAll);
  final controller = NetworkModeController.inMemory(
    mode: AppMode.network,
    networkId: 'net1',
    channelId: 'c1',
  );

  await pumpGolden(
    tester,
    NetworkChatPage(
      controller: controller,
      manager: manager,
      showAppBar: true,
      showChannelHeader: false,
      projectLabel: 'fa-team',
    ),
    size: size,
    theme: buildFaTheme(
      direction: FaVisualDirection.glass,
      brightness: brightness,
    ),
    wrap: (child) => Scaffold(body: child),
  );
  for (var index = 0; index < 6; index++) {
    await tester.pump(const Duration(milliseconds: 20));
  }

  expect(find.byType(FahWallpaper), findsOneWidget);
  expect(
    find.text('The channel uses the same wallpaper as a Local session.'),
    findsOneWidget,
  );
  final chat = tester.widget<Chat>(find.byType(Chat));
  expect(chat.backgroundColor, Colors.transparent);
  final brightnessSuffix = brightness == Brightness.light ? '_light' : '';
  final chatFinder = find.byKey(const ValueKey('channelChat:c1'));
  final transcriptFinder = find.byKey(const ValueKey('faChatTranscriptList'));
  final headerFinder = find.byKey(const ValueKey('faChatFloatingHeader'));
  final connectedChatRect = tester.getRect(chatFinder);
  final connectedTranscriptRect = tester.getRect(transcriptFinder);
  final connectedHeaderRect = tester.getRect(headerFinder);
  await expectGolden(
    tester,
    'network_channel_${size.width.toInt()}$brightnessSuffix',
  );

  connector.channels.single.serverEvent('network.offline', {
    'reason': 'hub down',
  });
  for (var index = 0; index < 6; index++) {
    await tester.pump(const Duration(milliseconds: 20));
  }

  expect(
    find.byKey(const ValueKey('networkReconnectingBanner')),
    findsOneWidget,
  );
  expect(tester.getRect(chatFinder), connectedChatRect);
  expect(tester.getRect(transcriptFinder), connectedTranscriptRect);
  expect(tester.getRect(headerFinder), connectedHeaderRect);
  expect(
    tester.getRect(find.byKey(const ValueKey('networkReconnectingBanner'))).top,
    greaterThanOrEqualTo(connectedHeaderRect.bottom),
  );
  await expectGolden(
    tester,
    'network_channel_reconnecting_${size.width.toInt()}$brightnessSuffix',
  );
  await session.close();
}

Future<void> _pumpDm(
  WidgetTester tester,
  Size size, {
  String? projectPath,
  bool queueRetryFixture = false,
}) async {
  const channelId = 'dm:user:u-1:main@01a15985f6c37e9eb16b203817f2a9c2';
  const sessionId = '01a15985-f6c3-7e9e-b16b-203817f2a9c2';
  final wallet = await KeyWallet.load(MemoryWalletBackend());
  await wallet.createIfMissing(displayName: 'Golden User');
  final session = buildSession(
    httpClient: FakeHttpClient(),
    connector: FakeWsConnector(),
    wallet: wallet,
  );
  session.channels = const [
    Channel(id: channelId, networkId: 'net1', name: 'mymac · main'),
  ];
  final sessionLabel = deviceSessionDisplayTitle(
    id: sessionId,
    path: projectPath,
  );
  session.selectDmSession(
    channelId,
    sessionId,
    // The fallback case deliberately exercises a legacy raw title. The
    // folder case mirrors Devices handing over its cwd-derived title.
    title: projectPath == null ? 'mymac · $sessionId' : 'mymac · $sessionLabel',
  );
  final state = session.channelStates.putIfAbsent(channelId, ChannelState.new);
  state.add(
    ChannelMessage(
      envelopeId: 'dm-own',
      senderId: 'u-1',
      senderPub: '',
      text: 'Please review the mobile device list.',
      isOwn: true,
      createdAt: DateTime.utc(2025, 12, 1, 9, 30),
      sessionId: sessionId,
    ),
  );
  if (queueRetryFixture) {
    for (var index = 0; index < 3; index++) {
      state.add(
        ChannelMessage(
          envelopeId: 'dm-queued-$index',
          senderId: 'main@mymac',
          senderPub: '',
          senderName: 'mymac',
          text: 'queued / not listening',
          isOwn: false,
          createdAt: DateTime.utc(2025, 12, 1, 9, 31),
          sessionId: sessionId,
          replyTo: 'dm-own',
        ),
      );
    }
  } else {
    state.add(
      ChannelMessage(
        envelopeId: 'dm-reply',
        senderId: 'main@mymac',
        senderPub: '',
        senderName: sessionId,
        text: 'The phone now shows one named device per row.',
        isOwn: false,
        createdAt: DateTime.utc(2025, 12, 1, 9, 31),
        sessionId: sessionId,
      ),
    );
  }
  state.historyResolved = true;
  final manager = NetworkSessionManager(
    baseUrl: testBase,
    wallet: wallet,
    httpClient: FakeHttpClient(),
    wsConnector: FakeWsConnector(),
  )..sessions['net1'] = session;
  addTearDown(manager.disconnectAll);
  final controller = NetworkModeController.inMemory(
    mode: AppMode.network,
    networkId: 'net1',
    channelId: channelId,
  );

  await pumpGolden(
    tester,
    NetworkChatPage(
      controller: controller,
      manager: manager,
      showAppBar: true,
      showChannelHeader: false,
    ),
    size: size,
    theme: buildFaTheme(
      direction: FaVisualDirection.glass,
      brightness: Brightness.dark,
    ),
    wrap: (child) => Scaffold(body: child),
  );
  for (var index = 0; index < 6; index++) {
    await tester.pump(const Duration(milliseconds: 20));
  }

  final expectedTitle = 'mymac · $sessionLabel';
  expect(find.text(expectedTitle), findsWidgets);
  expect(find.textContaining(sessionId), findsNothing);
  expect(
    find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Message $expectedTitle',
    ),
    findsOneWidget,
  );
  if (queueRetryFixture) {
    expect(find.textContaining('queued / not listening'), findsNothing);
    expect(find.textContaining('accepted, awaiting steering'), findsNothing);
    expect(find.byKey(const ValueKey('chatDelivery-queued')), findsOneWidget);
    await expectGolden(tester, 'network_dm_queue_${size.width.toInt()}');

    state.add(
      ChannelMessage(
        envelopeId: 'dm-accepted',
        senderId: 'main@mymac',
        senderPub: '',
        senderName: sessionId,
        text: 'accepted, awaiting steering',
        isOwn: false,
        createdAt: DateTime.utc(2025, 12, 1, 9, 32),
        sessionId: sessionId,
        replyTo: 'dm-own',
      ),
    );
    session.notifyDmChanged();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatDelivery-queued')), findsNothing);
    expect(find.byKey(const ValueKey('chatDelivery-accepted')), findsOneWidget);
    expect(find.textContaining('accepted, awaiting steering'), findsNothing);
    await expectGolden(tester, 'network_dm_accepted_${size.width.toInt()}');
  } else if (projectPath == null) {
    expect(find.textContaining('CLI · 01a15985…a9c2'), findsOneWidget);
    await expectGolden(tester, 'network_dm_${size.width.toInt()}');
  } else {
    await expectGolden(tester, 'network_dm_folder_${size.width.toInt()}');
  }
  await session.close();
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    debugFaGlassAlwaysFake = true;
  });
  tearDownAll(() => debugFaGlassAlwaysFake = false);

  for (final size in const [goldenSizePhone, goldenSizeDesktop]) {
    testWidgets(
      'DM session title and short hint ${size.width.toInt()}',
      (tester) => _pumpDm(tester, size),
    );
    testWidgets(
      'DM folder title and short hint ${size.width.toInt()}',
      (tester) => _pumpDm(tester, size, projectPath: '/work/flutter_agent'),
    );
    testWidgets(
      'DM queue retries render one state ${size.width.toInt()}',
      (tester) => _pumpDm(tester, size, queueRetryFixture: true),
    );
  }

  for (final size in const [Size(390, 844), Size(1280, 800)]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'channel chat ${size.width.toInt()} ${brightness.name}',
        (tester) => _pumpChannel(tester, size: size, brightness: brightness),
      );
    }
  }
}
