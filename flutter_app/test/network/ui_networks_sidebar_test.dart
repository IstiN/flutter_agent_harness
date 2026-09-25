// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/join_sheet.dart';
import 'package:fa/ui/network/networks_sidebar.dart';
import 'package:fa/ui/widgets/session_search_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

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
    testWidgets('header mirrors the sessions list: small-caps NETWORKS '
        'label + circle-outline + button', (tester) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = await _manager(wallet: wallet);

      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: manager)),
      );
      await tester.pump();

      final label = tester.widget<Text>(find.text('NETWORKS'));
      expect(label.style?.fontSize, 12);
      expect(label.style?.fontWeight, FontWeight.bold);
      expect(label.style?.letterSpacing, 0.5);

      final join = tester.widget<IconButton>(
        find.byKey(const ValueKey('joinNetworkButton')),
      );
      expect(join.icon, isA<Icon>());
      expect((join.icon as Icon).icon, Icons.add_circle_outline);
      expect(join.iconSize, 20);

      // The search field is the sessions list's SessionSearchField.
      expect(find.byType(SessionSearchField), findsOneWidget);
      expect(find.text('Search networks'), findsOneWidget);
    });

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
      // The shared search field debounces the query by 150 ms.
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('fa-team'), findsNothing);
      expect(find.text('side-project'), findsOneWidget);
    });

    testWidgets('membership rows are single-row tiles (dot + name)', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = await _manager(wallet: wallet);

      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: manager)),
      );
      await tester.pump();

      final tile = find.byKey(const ValueKey('membership:net1'));
      expect(tile, findsOneWidget);
      expect(
        find.descendant(of: tile, matching: find.byType(InkWell)),
        findsOneWidget,
      );
      // No card chrome, no subtitle line — just the name.
      expect(
        find.descendant(of: tile, matching: find.text('fa-team')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: tile,
          matching: find.textContaining('net1', findRichText: true),
        ),
        // The name Text is the only text in the row.
        findsNothing,
      );
    });

    testWidgets('empty state: Join your first network + secondary Sign in', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = await _manager(wallet: wallet);

      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: manager)),
      );
      await tester.pump();

      expect(find.text('Join your first network'), findsOneWidget);
      expect(find.byKey(const ValueKey('emptyStateSignIn')), findsOneWidget);
    });

    testWidgets('empty state hides the secondary Sign in when signed in', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = await _manager(wallet: wallet, jwt: 'jwt-1');

      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: manager)),
      );
      await tester.pump();

      expect(find.text('Join your first network'), findsOneWidget);
      expect(find.byKey(const ValueKey('emptyStateSignIn')), findsNothing);
    });

    testWidgets('account row: guest sees Sign in, signed-in sees the '
        'account + Sign out', (tester) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
      final controller = NetworkModeController.inMemory(mode: AppMode.network);

      final guest = await _manager(wallet: wallet);
      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: guest)),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('signInRow')), findsOneWidget);
      expect(find.byKey(const ValueKey('signOutButton')), findsNothing);

      // A JWT injected at construction has no login → the 'Account'
      // fallback label.
      final authed = await _manager(wallet: wallet, jwt: 'jwt-1');
      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: authed)),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('signInRow')), findsNothing);
      expect(find.byKey(const ValueKey('accountLabel')), findsOneWidget);
      expect(find.text('Account'), findsOneWidget);
      expect(find.byKey(const ValueKey('signOutButton')), findsOneWidget);

      // Sign out drops back to the guest row and hides the create gate.
      await tester.tap(find.byKey(const ValueKey('signOutButton')));
      await tester.pump();
      expect(authed.hasJwt, isFalse);
      expect(find.byKey(const ValueKey('signInRow')), findsOneWidget);
      expect(find.byKey(const ValueKey('createNetworkButton')), findsNothing);
    });

    testWidgets('sign-in through the sidebar row stores the JWT in memory', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final httpClient = FakeHttpClient()
        ..respond(200, body: '{"token":"jwt-1"}');
      final manager = await _manager(wallet: wallet, httpClient: httpClient);

      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: manager)),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('signInRow')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(
        find.byKey(const ValueKey('signInLogin')),
        'alice',
      );
      await tester.enterText(
        find.byKey(const ValueKey('signInPassword')),
        'pw',
      );
      await tester.tap(find.byKey(const ValueKey('signInSubmit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(manager.hasJwt, isTrue);
      expect(manager.accountLogin, 'alice');
      // The account row now shows the login and the create gate opens.
      expect(find.text('alice'), findsOneWidget);
      expect(find.byKey(const ValueKey('createNetworkButton')), findsOneWidget);
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

    testWidgets('public directory: 404 (not deployed) hides the section', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = await _manager(wallet: wallet);

      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: manager)),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('publicNetworksSection')), findsNothing);
    });

    testWidgets('public directory: 200 lists networks with a Join button '
        'that prefills the sheet', (tester) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final httpClient = FakeHttpClient()
        ..publicNetworksResponse = http.Response(
          '{"items":[{"id":"pub-1","name":"open-hub","publicChannels":3,'
          '"memberCount":42},{"id":"pub-2","name":"agents-lab",'
          '"publicChannels":1,"memberCount":5}],"nextCursor":""}',
          200,
        );
      final manager = await _manager(wallet: wallet, httpClient: httpClient);

      await tester.pumpWidget(
        _wrap(NetworksSidebar(controller: controller, manager: manager)),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('PUBLIC NETWORKS'), findsOneWidget);
      expect(find.text('open-hub'), findsOneWidget);
      expect(find.text('42 members'), findsOneWidget);
      expect(find.text('agents-lab'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('publicJoin:pub-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(JoinSheet), findsOneWidget);
      // The id is prefilled; the password field is the autofocus target.
      expect(find.text('pub-1'), findsOneWidget);
      final passwordField = tester
          .widgetList<TextField>(find.byType(TextField))
          .firstWhere((f) => f.obscureText);
      expect(passwordField.autofocus, isTrue);
    });

    testWidgets('a join re-probes the public directory', (tester) async {
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

      int probes() => httpClient.requests
          .where((r) => r.url.path == '/api/networks/public')
          .length;
      expect(probes(), 1);

      // Joining a NEW network mutates the wallet → the sidebar re-probes
      // the directory (the pull-to-refresh equivalent).
      await manager.join(networkId: 'net2', password: 'pw2');
      await tester.pump();
      await tester.pump();

      expect(probes(), 2);
      await manager.disconnectAll();
    });
  });
}
