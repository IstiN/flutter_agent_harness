// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/main.dart' show faHomeScreen;
import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/channel_rail.dart';
import 'package:fa/ui/network/create_network_dialog.dart';
import 'package:fa/ui/network/join_sheet.dart';
import 'package:fa/ui/network/network_center.dart';
import 'package:fa/ui/network/network_home.dart';
import 'package:fa/ui/network/networks_sidebar.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show MemoryExecutionEnv;
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// One private + one public channel on net1.
const _twoChannelsBody =
    '[{"id":"c1","networkId":"net1","name":"general","public":false},'
    '{"id":"c2","networkId":"net1","name":"launch","public":true}]';

/// A 5xx join whose body the client maps into the FaNetworkException's
/// message — the text the silent-resume snack renders (gh-1848).
const _resumeRejectedBody =
    '{"error":{"code":"http_5xx","message":"resume rejected"}}';

/// Pumps the wide [faHomeScreen] (1280×800) wired for network mode.
Future<void> _pumpWideHome(
  WidgetTester tester, {
  required NetworkModeController controller,
  required NetworkSessionManager manager,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  final sessions = FlutterSessionManager(
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      home: Builder(
        builder: (context) => faHomeScreen(
          context: context,
          manager: sessions,
          networkMode: controller,
          networkSessions: manager,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  group('Wide network center (issue #955, inside the shell)', () {
    testWidgets('no network selected → the welcome empty state with the '
        'join/create entry points opens the sheets', (tester) async {
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: await KeyWallet.load(MemoryWalletBackend()),
        httpClient: FakeHttpClient(),
        wsConnector: FakeWsConnector(),
        jwtToken: 'jwt-1',
      );
      addTearDown(manager.disconnectAll);
      await _pumpWideHome(tester, controller: controller, manager: manager);

      expect(find.byType(WideLayoutShell), findsOneWidget);
      expect(find.byType(NetworkHomePage), findsNothing);
      expect(find.byType(NetworkCenterPane), findsOneWidget);
      expect(find.text('Welcome to Fa networks'), findsOneWidget);

      // Join a network → the join sheet (a dialog on wide).
      await tester.tap(find.byKey(const ValueKey('networkCenterJoin')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(JoinSheet), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(JoinSheet), findsNothing);

      // Create network (JWT set) → the create dialog.
      await tester.tap(find.byKey(const ValueKey('networkCenterCreate')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(CreateNetworkDialog), findsOneWidget);
    });

    testWidgets('the create button hides without a JWT (guest)', (
      tester,
    ) async {
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: await KeyWallet.load(MemoryWalletBackend()),
        httpClient: FakeHttpClient(),
        wsConnector: FakeWsConnector(),
      );
      addTearDown(manager.disconnectAll);
      await _pumpWideHome(tester, controller: controller, manager: manager);

      expect(find.byKey(const ValueKey('networkCenterJoin')), findsOneWidget);
      expect(find.byKey(const ValueKey('networkCenterCreate')), findsNothing);
    });

    testWidgets('a selected network renders the channel rail + the '
        'select-a-channel pane in the center', (tester) async {
      final channelKeys = await EnvelopeCodec.newX25519KeyPair();
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        memberClass: 'member',
        password: 'secret-pw',
      );
      await wallet.addChannelKeys(
        networkId: 'net1',
        channel: 'c1',
        pub: channelKeys.pub,
        priv: channelKeys.priv,
      );
      final httpClient = FakeHttpClient()
        ..respond(200, body: _twoChannelsBody) // start: channels
        ..respond(200, body: membersBody); // start: members
      final session = buildSession(
        httpClient: httpClient,
        connector: FakeWsConnector(),
        wallet: wallet,
      );
      await session.start();
      addTearDown(session.close);
      final controller = NetworkModeController.inMemory(
        mode: AppMode.network,
        networkId: 'net1',
      );
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: FakeHttpClient(),
        wsConnector: FakeWsConnector(),
      );
      manager.sessions['net1'] = session;
      manager.notifyListeners();
      addTearDown(manager.disconnectAll);

      await _pumpWideHome(tester, controller: controller, manager: manager);

      expect(find.byType(WideLayoutShell), findsOneWidget);
      expect(find.byType(NetworkCenterPane), findsOneWidget);
      expect(find.byType(ChannelRail), findsOneWidget);
      expect(find.text('Select a channel'), findsOneWidget);
      // The sidebar shows the memberships, with net1 selected.
      expect(find.byType(NetworksSidebar), findsOneWidget);
      expect(find.byKey(const ValueKey('membership:net1')), findsOneWidget);
      // Close inside the body: the session's WS heartbeat timer must not
      // outlive the test (fake-async invariant).
      await manager.disconnectAll();
    });

    testWidgets('a restored selection silently resumes the session', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        password: 'pw1',
      );
      final httpClient = FakeHttpClient()
        ..respond(200, body: joinBodyOk) // resume: join
        ..respond(200, body: channelsBody) // start: channels
        ..respond(200, body: membersBody); // start: members
      final controller = NetworkModeController.inMemory(
        mode: AppMode.network,
        networkId: 'net1',
      );
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: httpClient,
        wsConnector: FakeWsConnector(),
      );
      addTearDown(manager.disconnectAll);

      await _pumpWideHome(tester, controller: controller, manager: manager);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(manager.sessions.containsKey('net1'), isTrue);
      // The session is fully started (channels landed) — closing it now
      // cannot race the WS connect (connect() re-arms _manualClose).
      expect(manager.sessions['net1']!.channels, isNotEmpty);
      expect(find.byType(ChannelRail), findsOneWidget);
      // Close inside the body: the session's WS heartbeat timer must not
      // outlive the test (fake-async invariant).
      await manager.disconnectAll();
    });

    // ── _ensureSession failure arms (gh-1848): NetworkSessionManager is a
    // final class, so the arms run over the REAL manager and its seams —
    // the dry FakeHttpClient queue throws StateError from `send`, a
    // scripted 5xx maps to FaNetworkException (error.message), and
    // ExplodingHttpClient feeds the catch-all arm. The success arm is the
    // "restored selection" test above.
    testWidgets('a failed silent resume surfaces the snack, pane stays '
        'alive', (tester) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        password: 'pw1',
      );
      final controller = NetworkModeController.inMemory(
        mode: AppMode.network,
        networkId: 'net1',
      );
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: FakeHttpClient(), // dry queue -> StateError from send
        wsConnector: FakeWsConnector(),
      );
      addTearDown(manager.disconnectAll);

      await _pumpWideHome(tester, controller: controller, manager: manager);
      await tester.pump(); // post-frame ensure -> StateError -> snack
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.textContaining('unexpected request'), findsOneWidget);
      // The pane is still alive and waiting (no crash, no takeover) and
      // the sidebar picker stays reachable beside it.
      expect(find.byType(NetworkCenterPane), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(NetworksSidebar), findsOneWidget);
    });

    testWidgets('a controller change re-runs the silent resume', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        password: 'pw1',
      );
      final controller = NetworkModeController.inMemory(
        mode: AppMode.network,
        networkId: 'net1',
      );
      final httpClient = FakeHttpClient()
        ..respond(500, body: _resumeRejectedBody); // every join fails 5xx
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: httpClient,
        wsConnector: FakeWsConnector(),
      );
      addTearDown(manager.disconnectAll);

      await _pumpWideHome(tester, controller: controller, manager: manager);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(
        httpClient.requests.where((r) => r.method == 'POST').length,
        1, // the post-frame initial call
      );
      expect(find.text('resume rejected'), findsOneWidget); // e.message

      controller.notifyListeners();
      await tester.pump();

      expect(
        httpClient.requests.where((r) => r.method == 'POST').length,
        2, // the listener-triggered re-run
      );
    });

    testWidgets('a non-network resume error still lands in the snack', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        password: 'pw1',
      );
      final controller = NetworkModeController.inMemory(
        mode: AppMode.network,
        networkId: 'net1',
      );
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: ExplodingHttpClient(),
        wsConnector: FakeWsConnector(),
      );
      addTearDown(manager.disconnectAll);

      await _pumpWideHome(tester, controller: controller, manager: manager);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.textContaining('disk on fire'), findsOneWidget);
      expect(find.byType(NetworkCenterPane), findsOneWidget);
    });
  });
}
