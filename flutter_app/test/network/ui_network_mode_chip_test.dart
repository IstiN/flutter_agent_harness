// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/network_mode_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

NetworkSessionManager _manager(KeyWallet wallet) => NetworkSessionManager(
  baseUrl: testBase,
  wallet: wallet,
  httpClient: FakeHttpClient(),
  wsConnector: FakeWsConnector(),
);

Widget _wrap(Widget child) => MaterialApp(
  theme: buildFahTheme(),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('NetworkModeChip', () {
    testWidgets('Network tap without a last network opens the picker', (
      tester,
    ) async {
      final controller = NetworkModeController.inMemory();
      final manager = _manager(await KeyWallet.load(MemoryWalletBackend()));
      await tester.pumpWidget(
        _wrap(NetworkModeChip(controller: controller, manager: manager)),
      );

      expect(controller.mode, AppMode.local);
      await tester.tap(find.text('Network'));
      await tester.pump();

      // backToNetworks(): network mode, no selection.
      expect(controller.mode, AppMode.network);
      expect(controller.networkId, isNull);
    });

    testWidgets('Network tap with a last network re-enters it', (tester) async {
      final controller = NetworkModeController.inMemory(networkId: 'net1');
      final manager = _manager(await KeyWallet.load(MemoryWalletBackend()));
      await tester.pumpWidget(
        _wrap(NetworkModeChip(controller: controller, manager: manager)),
      );

      await tester.tap(find.text('Network'));
      await tester.pump();

      expect(controller.mode, AppMode.network);
      expect(controller.networkId, 'net1');
    });

    testWidgets('Local tap exits and disconnects every session', (
      tester,
    ) async {
      final controller = NetworkModeController.inMemory(
        mode: AppMode.network,
        networkId: 'net1',
        channelId: 'c1',
      );
      final channelKeys = await EnvelopeCodec.newX25519KeyPair();
      final wallet = await walletWithChannel(
        channelPub: channelKeys.pub,
        channelPriv: channelKeys.priv,
      );
      final httpClient = FakeHttpClient()
        ..respond(200, body: channelsBody)
        ..respond(200, body: membersBody);
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: httpClient,
        wsConnector: FakeWsConnector(),
      );
      manager.sessions['net1'] = buildSession(
        httpClient: httpClient,
        connector: FakeWsConnector(),
        wallet: wallet,
      );
      await tester.pumpWidget(
        _wrap(NetworkModeChip(controller: controller, manager: manager)),
      );

      await tester.tap(find.text('Local'));
      await tester.pump();

      expect(controller.mode, AppMode.local);
      expect(controller.networkId, isNull);
      expect(manager.sessions, isEmpty);
    });
  });
}
