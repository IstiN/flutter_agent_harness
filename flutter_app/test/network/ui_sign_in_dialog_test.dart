// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/sign_in_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Future<NetworkSessionManager> _manager(FakeHttpClient httpClient) async =>
    NetworkSessionManager(
      baseUrl: testBase,
      wallet: await KeyWallet.load(MemoryWalletBackend()),
      httpClient: httpClient,
      wsConnector: FakeWsConnector(),
    );

Widget _launcher(NetworkSessionManager manager) => MaterialApp(
  theme: buildFahTheme(),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => showSignInDialog(context, manager: manager),
        child: const Text('open'), // l10n:ignore
      ),
    ),
  ),
);

Future<void> _openDialog(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _submit(
  WidgetTester tester, {
  required String login,
  required String password,
}) async {
  await tester.enterText(find.byKey(const ValueKey('signInLogin')), login);
  await tester.enterText(
    find.byKey(const ValueKey('signInPassword')),
    password,
  );
  await tester.tap(find.byKey(const ValueKey('signInSubmit')));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('SignInDialog', () {
    testWidgets('success: the manager holds the JWT + login in memory and '
        'the dialog closes', (tester) async {
      final httpClient = FakeHttpClient()
        ..respond(200, body: '{"token":"jwt-1"}');
      final manager = await _manager(httpClient);

      await tester.pumpWidget(_launcher(manager));
      await _openDialog(tester);

      expect(find.byType(SignInDialog), findsOneWidget);
      expect(find.text('Sign in'), findsNWidgets(2)); // title + button

      await _submit(tester, login: 'bob', password: 'pw');

      expect(manager.hasJwt, isTrue);
      expect(manager.accountLogin, 'bob');
      expect(find.byType(SignInDialog), findsNothing);
    });

    testWidgets('failure: the server error message shows, no JWT stored', (
      tester,
    ) async {
      final httpClient = FakeHttpClient()
        ..respond(
          401,
          body:
              '{"error":{"code":"unauthorized",'
              '"message":"invalid login or password"}}',
        );
      final manager = await _manager(httpClient);

      await tester.pumpWidget(_launcher(manager));
      await _openDialog(tester);

      await _submit(tester, login: 'bob', password: 'wrong');

      expect(find.byKey(const ValueKey('signInError')), findsOneWidget);
      expect(find.text('invalid login or password'), findsOneWidget);
      expect(manager.hasJwt, isFalse);
      expect(find.byType(SignInDialog), findsOneWidget);
    });
  });
}
