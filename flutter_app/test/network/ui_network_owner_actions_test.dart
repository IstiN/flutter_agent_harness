// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/create_network_dialog.dart';
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
  group('NetworksSidebar owner delete', () {
    testWidgets('owner rows show the delete menu; member rows do not', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        memberClass: 'owner',
      );
      await wallet.addNetwork(networkId: 'net2', name: 'side-project');
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = await _manager(wallet: wallet);

      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: manager)),
      );
      await tester.pump();

      final ownerRow = find.byKey(const ValueKey('membership:net1'));
      final memberRow = find.byKey(const ValueKey('membership:net2'));
      expect(
        find.descendant(
          of: ownerRow,
          matching: find.byKey(const ValueKey('networkRowMenu')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: memberRow,
          matching: find.byKey(const ValueKey('networkRowMenu')),
        ),
        findsNothing,
      );
    });

    testWidgets('delete flow: menu → confirm → DELETE + membership gone', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        memberClass: 'owner',
      );
      final httpClient = FakeHttpClient()..respond(204);
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = await _manager(
        wallet: wallet,
        httpClient: httpClient,
        jwt: 'jwt-1',
      );

      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: manager)),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('networkRowMenu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete network…'));
      await tester.pumpAndSettle();

      // The confirmation dialog names the network and the consequences.
      expect(find.text('Delete this network?'), findsOneWidget);
      expect(find.textContaining('fa-team'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('confirmDeleteNetwork')));
      await tester.pumpAndSettle();

      final deletes = httpClient.requests
          .where((r) => r.method == 'DELETE')
          .toList();
      expect(deletes, hasLength(1));
      expect(deletes.single.url.path, '/api/networks/net1');
      expect(deletes.single.headers['authorization'], 'Bearer jwt-1');
      expect(wallet.networks['net1'], isNull);
      expect(find.text('fa-team'), findsNothing);
      expect(find.text('Network deleted'), findsOneWidget);
    });

    testWidgets('delete cancel keeps the membership and sends nothing', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        memberClass: 'owner',
      );
      final httpClient = FakeHttpClient();
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = await _manager(
        wallet: wallet,
        httpClient: httpClient,
        jwt: 'jwt-1',
      );

      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: manager)),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('networkRowMenu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete network…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(httpClient.requests.where((r) => r.method == 'DELETE'), isEmpty);
      expect(wallet.networks['net1'], isNotNull);
    });
  });

  group('CreateNetworkDialog', () {
    Future<void> pumpDialog(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          home: const Scaffold(body: CreateNetworkDialog()),
        ),
      );
      await tester.pump();
    }

    testWidgets('validates the server rules inline: slug name + 8-char '
        'password, public checkbox rides along', (tester) async {
      await pumpDialog(tester);

      // Slug violation + short password → inline errors, dialog stays open.
      await tester.enterText(find.byType(TextField).first, 'My Net!');
      await tester.enterText(find.byType(TextField).at(1), 'short');
      await tester.tap(find.byKey(const ValueKey('createNetworkConfirm')));
      await tester.pump();
      expect(
        find.textContaining('lowercase letters, digits, hyphens'),
        findsWidgets,
      );
      expect(find.text('Password must be 8–128 characters'), findsOneWidget);

      // Valid input + the public checkbox → the dialog closes with the
      // full record.
      await tester.enterText(find.byType(TextField).first, 'my-net');
      await tester.enterText(find.byType(TextField).at(1), 'supersecret1');
      await tester.tap(find.byKey(const ValueKey('createNetworkPublic')));
      await tester.pump();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('createNetworkPublic')),
            )
            .value,
        isTrue,
      );
    });
  });
}
