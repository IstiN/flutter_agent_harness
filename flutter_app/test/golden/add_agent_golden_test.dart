// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by an MIT license that can be found
// in the LICENSE file.

/// Goldens for the Add-an-agent network dialog (issue #1913): the narrow
/// phone layout (Wrap-of-chips selectors, stacked enroll controls) and the
/// wide desktop layout (SegmentedButtons), in both themes. Fakes mirror
/// `test/network/ui_add_agent_dialog_test.dart`.
library;

import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/add_agent_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../network/fakes.dart';
import 'golden_test_helper.dart';

/// Pumps a chat-less host that opens the dialog over a private channel
/// (the red warning hint) with a management JWT (the enroll form), then
/// settles the entry animation.
Future<void> _pumpAddAgent(
  WidgetTester tester, {
  required Size size,
  required bool dark,
}) async {
  final channelKeys = await EnvelopeCodec.newX25519KeyPair();
  final wallet = await KeyWallet.load(MemoryWalletBackend());
  await wallet.createIfMissing(displayName: 'Me');
  await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
  await wallet.addChannelKeys(
    networkId: 'net1',
    channel: 'c1',
    pub: channelKeys.pub,
    priv: channelKeys.priv,
  );
  await pumpGolden(
    tester,
    Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AddAgentDialog(
                wallet: wallet,
                manager: NetworkSessionManager(
                  baseUrl: testBase,
                  wallet: wallet,
                  httpClient: FakeHttpClient(),
                  wsConnector: FakeWsConnector(),
                  jwtToken: 'jwt',
                ),
                networkId: 'net1',
                channel: const Channel(
                  id: 'c1',
                  networkId: 'net1',
                  name: 'general',
                  isPublic: false,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
    theme: dark ? buildFahTheme() : buildFahThemeLight(),
    size: size,
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(ensureGoldenFonts);

  testWidgets('narrow phone, light theme', (tester) async {
    await _pumpAddAgent(tester, size: goldenSizePhone, dark: false);
    await expectGolden(tester, 'add_agent_narrow_light');
  });

  testWidgets('narrow phone, dark theme', (tester) async {
    await _pumpAddAgent(tester, size: goldenSizePhone, dark: true);
    await expectGolden(tester, 'add_agent_narrow_dark');
  });

  testWidgets('wide desktop, light theme', (tester) async {
    await _pumpAddAgent(tester, size: goldenSizeDesktop, dark: false);
    await expectGolden(tester, 'add_agent_wide_light');
  });

  testWidgets('wide desktop, dark theme', (tester) async {
    await _pumpAddAgent(tester, size: goldenSizeDesktop, dark: true);
    await expectGolden(tester, 'add_agent_wide_dark');
  });
}
