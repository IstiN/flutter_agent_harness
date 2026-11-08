@TestOn('vm')
library;

import 'dart:convert';

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
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
  final session = buildSession(
    httpClient: httpClient,
    connector: FakeWsConnector(),
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
  await expectGolden(
    tester,
    'network_channel_${size.width.toInt()}$brightnessSuffix',
  );
  await session.close();
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    debugFaGlassAlwaysFake = true;
  });
  tearDownAll(() => debugFaGlassAlwaysFake = false);

  for (final size in const [Size(390, 844), Size(1280, 800)]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'channel chat ${size.width.toInt()} ${brightness.name}',
        (tester) => _pumpChannel(tester, size: size, brightness: brightness),
      );
    }
  }
}
