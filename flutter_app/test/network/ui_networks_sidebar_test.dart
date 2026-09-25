// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/join_sheet.dart';
import 'package:fa/ui/network/networks_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Future<NetworkSessionManager> _manager({
  required KeyWallet wallet,
  FakeHttpClient? httpClient,
  String? jwt,
}) async => NetworkSessionManager(
  baseUrl: testBase,
  wallet: wallet,
  httpClient: httpClient ?? FakeHttpClient(),
  wsConnector: FakeWsConnector(),
  jwtToken: jwt,
);

Widget _wrap(Widget child) => MaterialApp(
  theme: buildFahTheme(),
  home: Scaffold(body: SizedBox(width: 320, child: child)),
);

void main() {
  group('NetworksSidebar', () {
    testWidgets('lists memberships and filters by search', (tester) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
      await wallet.addNetwork(networkId: 'net2', name: 'side-project');
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = await _manager(wallet: wallet);

      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: manager)),
      );
      await tester.pump();

      expect(find.text('fa-team'), findsOneWidget);
      expect(find.text('side-project'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'side');
      await tester.pump();

      expect(find.text('fa-team'), findsNothing);
      expect(find.text('side-project'), findsOneWidget);
    });

    testWidgets('no memberships → Join your first network CTA', (tester) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = await _manager(wallet: wallet);

      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: manager)),
      );
      await tester.pump();

      expect(find.text('Join your first network'), findsOneWidget);
    });

    testWidgets('+ Create shows only with a JWT set', (tester) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
      final controller = NetworkModeController.inMemory(mode: AppMode.network);

      final guest = await _manager(wallet: wallet);
      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: guest)),
      );
      expect(find.byKey(const ValueKey('createNetworkButton')), findsNothing);

      final authed = await _manager(wallet: wallet, jwt: 'jwt-1');
      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: authed)),
      );
      expect(find.byKey(const ValueKey('createNetworkButton')), findsOneWidget);
    });

    testWidgets('tapping a membership enters the network and resumes', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        password: 'secret-pw',
      );
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final httpClient = FakeHttpClient()
        ..respond(200, body: joinBodyOk)
        ..respond(200, body: channelsBody)
        ..respond(200, body: membersBody);
      final manager = await _manager(wallet: wallet, httpClient: httpClient);
      addTearDown(manager.disconnectAll);

      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: manager)),
      );
      await tester.pump();

      await tester.tap(find.text('fa-team'));
      await tester.pump();
      await tester.pump();

      expect(controller.networkId, 'net1');
      expect(manager.sessions.containsKey('net1'), isTrue);
      // Close inside the body: the session's WS heartbeat timer must not
      // outlive the test (fake-async invariant).
      await manager.disconnectAll();
    });

    testWidgets('+ Join opens the join sheet', (tester) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = await _manager(wallet: wallet);

      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: manager)),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('joinNetworkButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(JoinSheet), findsOneWidget);
    });
  });
}
