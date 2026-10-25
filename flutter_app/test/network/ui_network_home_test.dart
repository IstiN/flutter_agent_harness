// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

// Widget tests for the narrow network home's silent session resume
// (gh-1848): the post-frame initial `_ensureSession`, the
// controller-listener re-run, the helper's no-op guards (no selection, no
// stored password), and every failure arm's error snack with the picker
// still reachable. `NetworkSessionManager` is a final class, so the failure
// arms run over the REAL manager and its constructor seams: the dry
// FakeHttpClient queue throws StateError from `send` (it propagates raw
// through `FaNetworkClient._request`), a scripted 5xx maps to
// FaNetworkException with the body's error.message, and
// ExplodingHttpClient supplies the catch-all arm. Join attempts are
// counted via the recorded POST requests.

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/channel_rail.dart';
import 'package:fa/ui/network/network_home.dart';
import 'package:fa/ui/network/networks_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Future<KeyWallet> _walletWithPassword() async {
  final wallet = await KeyWallet.load(MemoryWalletBackend());
  await wallet.createIfMissing(displayName: 'Me');
  await wallet.addNetwork(networkId: 'net1', name: 'fa-team', password: 'pw1');
  return wallet;
}

/// The join attempts the home page's `_ensureSession` has driven so far.
int _joinCount(FakeHttpClient httpClient) =>
    httpClient.requests.where((r) => r.method == 'POST').length;

Future<void> _pumpHome(
  WidgetTester tester, {
  required NetworkModeController controller,
  required NetworkSessionManager manager,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(420, 900);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      home: NetworkHomePage(controller: controller, manager: manager),
    ),
  );
}

void main() {
  testWidgets('a restored selection resumes once after the first frame', (
    tester,
  ) async {
    final wallet = await _walletWithPassword();
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

    await _pumpHome(tester, controller: controller, manager: manager);
    await tester.pump(); // the post-frame _ensureSession fires
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(manager.sessions.containsKey('net1'), isTrue);
    expect(find.byType(ChannelRail), findsOneWidget);
    // Exactly one join went out: the post-frame call, not a listener echo.
    expect(_joinCount(httpClient), 1);
    // Close inside the body: the session's WS heartbeat timer must not
    // outlive the test (fake-async invariant).
    await manager.disconnectAll();
  });

  testWidgets('no selected network: the ensure call is a no-op', (
    tester,
  ) async {
    final wallet = await _walletWithPassword();
    final httpClient = FakeHttpClient();
    final manager = NetworkSessionManager(
      baseUrl: testBase,
      wallet: wallet,
      httpClient: httpClient,
      wsConnector: FakeWsConnector(),
    );
    final controller = NetworkModeController.inMemory(mode: AppMode.network);

    await _pumpHome(tester, controller: controller, manager: manager);
    await tester.pump();

    // The picker IS the first screen; nothing was resumed.
    expect(find.byType(NetworksSidebar), findsOneWidget);
    expect(_joinCount(httpClient), 0);
  });

  testWidgets('a membership without a stored password is not resumed', (
    tester,
  ) async {
    final wallet = await KeyWallet.load(MemoryWalletBackend());
    await wallet.createIfMissing(displayName: 'Me');
    await wallet.addNetwork(networkId: 'net1', name: 'fa-team'); // no password
    final httpClient = FakeHttpClient();
    final manager = NetworkSessionManager(
      baseUrl: testBase,
      wallet: wallet,
      httpClient: httpClient,
      wsConnector: FakeWsConnector(),
    );
    final controller = NetworkModeController.inMemory(
      mode: AppMode.network,
      networkId: 'net1',
    );

    await _pumpHome(tester, controller: controller, manager: manager);
    await tester.pump();

    // The helper's password guard returns before the manager is touched —
    // no join, and no "no stored credentials" snack from a resume throw.
    expect(_joinCount(httpClient), 0);
    expect(find.textContaining('no stored credentials'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('a failed resume shows the snack; the picker stays reachable', (
    tester,
  ) async {
    final wallet = await _walletWithPassword();
    // Dry queue: the join POST hits FakeHttpClient's unexpected-request
    // StateError, which rides raw through resume into the widget's arm.
    final manager = NetworkSessionManager(
      baseUrl: testBase,
      wallet: wallet,
      httpClient: FakeHttpClient(),
      wsConnector: FakeWsConnector(),
    );
    final controller = NetworkModeController.inMemory(
      mode: AppMode.network,
      networkId: 'net1',
    );

    await _pumpHome(tester, controller: controller, manager: manager);
    await tester.pump(); // post-frame ensure -> StateError -> snack
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('unexpected request'), findsOneWidget);
    // Still waiting for a session (no crash), and the affordance back to
    // the picker is live.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const ValueKey('networkBack')), findsOneWidget);
  });

  testWidgets('a controller change re-runs the silent resume', (tester) async {
    final wallet = await _walletWithPassword();
    final httpClient = FakeHttpClient()
      ..respond(500, body: resumeRejectedBody); // every join fails 5xx
    final manager = NetworkSessionManager(
      baseUrl: testBase,
      wallet: wallet,
      httpClient: httpClient,
      wsConnector: FakeWsConnector(),
    );
    final controller = NetworkModeController.inMemory(
      mode: AppMode.network,
      networkId: 'net1',
    );

    await _pumpHome(tester, controller: controller, manager: manager);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(_joinCount(httpClient), 1); // the post-frame initial call
    expect(find.text('resume rejected'), findsOneWidget); // e.message

    controller.notifyListeners();
    await tester.pump();

    expect(_joinCount(httpClient), 2); // the listener-triggered re-run
  });

  testWidgets('a non-network error still lands in the snack', (tester) async {
    final wallet = await _walletWithPassword();
    final manager = NetworkSessionManager(
      baseUrl: testBase,
      wallet: wallet,
      httpClient: ExplodingHttpClient(),
      wsConnector: FakeWsConnector(),
    );
    final controller = NetworkModeController.inMemory(
      mode: AppMode.network,
      networkId: 'net1',
    );

    await _pumpHome(tester, controller: controller, manager: manager);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The catch-all arm stringifies the error into the snack ('$e').
    expect(find.textContaining('disk on fire'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
