// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/join_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Pumps a host with an "open" button that shows the join sheet (wide
/// dialog path), returning the manager for assertions.
Future<({NetworkModeController controller, NetworkSessionManager manager})>
_pumpHost(
  WidgetTester tester, {
  required FakeHttpClient httpClient,
  required KeyWallet wallet,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  final controller = NetworkModeController.inMemory(mode: AppMode.network);
  final manager = NetworkSessionManager(
    baseUrl: testBase,
    wallet: wallet,
    httpClient: httpClient,
    wsConnector: FakeWsConnector(),
  );
  addTearDown(manager.disconnectAll);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showJoinSheet(
              context,
              controller: controller,
              manager: manager,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byType(JoinSheet), findsOneWidget);
  return (controller: controller, manager: manager);
}

void main() {
  group('JoinSheet', () {
    testWidgets('guest flow: join records the wallet entry and enters the '
        'network', (tester) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final httpClient = FakeHttpClient()
        ..respond(200, body: joinBodyOk)
        ..respond(200, body: channelsBody)
        ..respond(200, body: membersBody);
      final rig = await _pumpHost(
        tester,
        httpClient: httpClient,
        wallet: wallet,
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Network id'),
        'net1',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Password'),
        'secret-pw',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Display name'),
        'Me',
      );
      await tester.tap(find.text('Join'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Joined: the wallet holds the membership + password, the sheet
      // popped, and the controller entered the network.
      expect(wallet.networks['net1']?.name, 'fa-team');
      expect(wallet.networks['net1']?.password, 'secret-pw');
      expect(wallet.hasIdentity, isTrue);
      expect(rig.controller.mode, AppMode.network);
      expect(rig.controller.networkId, 'net1');
      expect(rig.manager.sessions.containsKey('net1'), isTrue);
      expect(find.byType(JoinSheet), findsNothing);
      // Close inside the body: the joined session's WS heartbeat timer
      // must not outlive the test (fake-async invariant).
      await rig.manager.disconnectAll();
    });

    testWidgets('invalid_credentials shows an inline error with Retry-After', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final httpClient = FakeHttpClient()
        ..respond(
          403,
          body:
              '{"error":{"code":"invalid_credentials",'
              '"message":"wrong password"}}',
          headers: const {'retry-after': '17'},
        );
      final rig = await _pumpHost(
        tester,
        httpClient: httpClient,
        wallet: wallet,
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Network id'),
        'net1',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Password'),
        'nope',
      );
      await tester.tap(find.text('Join'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The sheet stays open, nothing is enrolled, and the inline error
      // carries the Retry-After hint.
      expect(find.byType(JoinSheet), findsOneWidget);
      expect(wallet.networks, isEmpty);
      expect(rig.controller.networkId, isNull);
      final error = tester.widget<Text>(
        find.byKey(const ValueKey('joinError')),
      );
      expect(error.data, contains('Invalid credentials'));
      expect(error.data, contains('17'));
    });

    testWidgets('a pasted join link prefills id + password', (tester) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await _pumpHost(tester, httpClient: FakeHttpClient(), wallet: wallet);

      await tester.enterText(
        find.widgetWithText(TextField, 'Join link'),
        'https://network.fa1.dev/join?network=net9#pw=link-secret',
      );
      await tester.tap(find.text('Fill'));
      await tester.pump();

      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Network id'))
            .controller
            ?.text,
        'net9',
      );
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Password'))
            .controller
            ?.text,
        'link-secret',
      );
    });
  });
}
