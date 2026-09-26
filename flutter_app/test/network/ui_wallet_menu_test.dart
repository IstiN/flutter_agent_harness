// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/network/wallet_export.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/wallet_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Fast Argon2id for widget tests (the spec default is deliberately slow).
const _fastKdf = WalletKdfParams(memoryKiB: 256, iterations: 1, lanes: 1);

void main() {
  group('WalletMenuButton', () {
    Future<NetworkSessionManager> pumpMenu(WidgetTester tester) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: FakeHttpClient(),
        wsConnector: FakeWsConnector(),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          home: Scaffold(
            body: WalletMenuButton(manager: manager, exportKdf: _fastKdf),
          ),
        ),
      );
      await tester.pump();
      return manager;
    }

    testWidgets('export copies JSON that importWallet re-reads (roundtrip)', (
      tester,
    ) async {
      final clipboard = FakeClipboard()..install(tester);
      final manager = await pumpMenu(tester);

      await tester.tap(find.byKey(const ValueKey('walletMenu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Export wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(
        find.widgetWithText(TextField, 'Passphrase'),
        'hunter2',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Repeat passphrase'),
        'hunter2',
      );
      await tester.tap(find.text('Export'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(clipboard.text, isNotNull);
      final imported = await importWallet(clipboard.text!, 'hunter2');
      expect(imported.identityPub, manager.wallet.identityPub);
      expect(imported.networks['net1']?.name, 'fa-team');
    });

    testWidgets('import failure shows the error and keeps the wallet', (
      tester,
    ) async {
      final manager = await pumpMenu(tester);
      final pubBefore = manager.wallet.identityPub;

      await tester.tap(find.byKey(const ValueKey('walletMenu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Import wallet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(
        find.widgetWithText(TextField, 'Exported wallet JSON'),
        '{"v":1,"kdf":"argon2id"}',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Passphrase'),
        'whatever',
      );
      await tester.tap(find.text('Import'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      // The dialog stays open with the import error; the live wallet is
      // untouched.
      expect(find.text('Import wallet'), findsWidgets);
      expect(manager.wallet.identityPub, pubBefore);
      expect(manager.wallet.networks['net1']?.name, 'fa-team');
    });
  });
}
