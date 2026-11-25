// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// One upstream per app process (contract §10: ONE device socket per
// deviceId — a second dial evicts the first). The wide shell claims the
// per-process connector (DeviceConnectorService.claimShared); a standalone
// NetworkHomePage — no injected connector, the path that used to construct
// a SECOND DeviceConnectorService — must reuse it. Observable through the
// picker's NetworksSidebar.deviceConnector and DeviceConnectorService.sharedFor.

import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/network_home.dart';
import 'package:fa/ui/network/networks_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Keychain-free token store for the shell-owned connector.
final class _NopTokenStore implements DeviceTokenStore {
  @override
  Future<void> clear() async {}

  @override
  Future<Map<String, String>> readDmPrivateKeys() async => const {};

  @override
  Future<DeviceCredentials?> read() async => null;

  @override
  Future<void> write(DeviceCredentials credentials) async {}

  @override
  Future<void> writeDmPrivateKeys(Map<String, String> keys) async {}
}

Future<NetworkSessionManager> _manager() async => NetworkSessionManager(
  baseUrl: testBase,
  wallet: await KeyWallet.load(MemoryWalletBackend()),
  httpClient: FakeHttpClient(),
  wsConnector: FakeWsConnector(),
);

Widget _app(Widget home) => MaterialApp(theme: buildFahTheme(), home: home);

Widget _page(NetworkSessionManager manager) => NetworkHomePage(
  controller: NetworkModeController.inMemory(mode: AppMode.network),
  manager: manager,
);

List<DeviceConnectorService?> _pickerConnectors(WidgetTester tester) => [
  for (final sidebar in tester.widgetList<NetworksSidebar>(
    find.byType(NetworksSidebar),
  ))
    sidebar.deviceConnector,
];

void main() {
  testWidgets('a standalone NetworkHomePage reuses the shell-claimed connector '
      'instead of owning a second one', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 900);
    addTearDown(tester.view.reset);
    final manager = await _manager();
    addTearDown(manager.disconnectAll);
    // The wide shell's app-scope ownership (boot): claimed, not started
    // here (signed-out start is a no-op anyway).
    final shell = DeviceConnectorService.claimShared(
      manager,
      () => DeviceConnectorService(
        sessionManager: manager,
        tokenStore: _NopTokenStore(),
      ),
    );
    addTearDown(shell.release);

    await tester.pumpWidget(_app(_page(manager)));
    await tester.pump();

    expect(_pickerConnectors(tester).single, same(shell));
    expect(DeviceConnectorService.sharedFor(manager), same(shell));

    // The page going away must not dispose the shell's connector.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(DeviceConnectorService.sharedFor(manager), same(shell));
  });

  testWidgets(
    'two standalone pages in one process share ONE connector, released '
    'when the last page goes away',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(420, 900);
      addTearDown(tester.view.reset);
      final manager = await _manager();
      addTearDown(manager.disconnectAll);

      await tester.pumpWidget(
        _app(
          Column(
            children: [
              Expanded(child: _page(manager)),
              Expanded(child: _page(manager)),
            ],
          ),
        ),
      );
      await tester.pump();

      final connectors = _pickerConnectors(tester);
      expect(connectors, hasLength(2));
      final first = connectors.first;
      expect(first, isNotNull);
      expect(connectors.last, same(first));
      expect(DeviceConnectorService.sharedFor(manager), same(first));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(
        DeviceConnectorService.sharedFor(manager),
        isNull,
        reason: 'the last owner releases the connector',
      );
    },
  );
}
