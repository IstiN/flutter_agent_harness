// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/sign_in_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fakes.dart';

const _initiateBody =
    '{"auth_url":"https://accounts.google.com/o/oauth2/auth?state=st-1&'
    'redirect_uri=http%3A%2F%2F127.0.0.1%3A0%2Fcallback",'
    '"state":"st-1","expires_in":600}';

const _exchangeBody =
    '{"accessToken":"at-1","refreshToken":"rt-1","expiresIn":3600,'
    '"refreshExpiresIn":86400,"tokenType":"Bearer"}';

const _profileBody =
    '{"authenticated":true,"id":"u1","email":"a@b.dev","name":"Alice",'
    '"provider":"google"}';

Future<NetworkSessionManager> _manager(
  FakeHttpClient httpClient, {
  Future<Uri> Function(Uri authUrl)? waitForCallback,
}) async => NetworkSessionManager(
  baseUrl: testBase,
  wallet: await KeyWallet.load(MemoryWalletBackend()),
  httpClient: httpClient,
  wsConnector: FakeWsConnector(),
  waitForCallback:
      waitForCallback ??
      ((_) async =>
          Uri.parse('http://127.0.0.1:5555/callback?code=temp-1&state=st-1')),
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

/// Expands the collapsed developer (local dev-login) section.
Future<void> _expandDevSection(WidgetTester tester) async {
  await tester.tap(find.text('Developer (local only)'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _submitDevLogin(
  WidgetTester tester, {
  required String login,
  required String password,
}) async {
  await _expandDevSection(tester);
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

/// Runs [body] as a desktop platform (widget tests default to Android,
/// where the provider buttons are replaced by the mobile note). The
/// override must be reset before the test body ends — the binding's
/// invariant check runs before teardowns.
Future<void> _asDesktop(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  group('SignInDialog', () {
    testWidgets('the provider list renders from the server', (tester) async {
      await _asDesktop(() async {
        final httpClient = FakeHttpClient()
          ..oauthProvidersResponse = http.Response(
            '{"providers":["google","github"]}',
            200,
          );
        final manager = await _manager(httpClient);

        await tester.pumpWidget(_launcher(manager));
        await _openDialog(tester);
        await tester.pump(); // the providers fetch completes

        expect(find.text('Continue with Google'), findsOneWidget);
        expect(find.text('Continue with GitHub'), findsOneWidget);
        expect(find.text('Continue with Apple'), findsNothing);
      });
    });

    testWidgets('a failed providers fetch falls back to the known four', (
      tester,
    ) async {
      await _asDesktop(() async {
        final manager = await _manager(FakeHttpClient()); // 404 out-of-band

        await tester.pumpWidget(_launcher(manager));
        await _openDialog(tester);
        await tester.pump();

        expect(find.text('Continue with Google'), findsOneWidget);
        expect(find.text('Continue with GitHub'), findsOneWidget);
        expect(find.text('Continue with Microsoft'), findsOneWidget);
        expect(find.text('Continue with Apple'), findsOneWidget);
      });
    });

    testWidgets('tapping a provider drives the OAuth flow and closes the '
        'dialog', (tester) async {
      await _asDesktop(() async {
        final httpClient = FakeHttpClient()
          ..respond(200, body: _initiateBody)
          ..respond(200, body: _exchangeBody)
          ..respond(200, body: _profileBody);
        var launched = false;
        final manager = await _manager(
          httpClient,
          waitForCallback: (_) async {
            launched = true;
            return Uri.parse(
              'http://127.0.0.1:5555/callback?code=temp-1&state=st-1',
            );
          },
        );

        await tester.pumpWidget(_launcher(manager));
        await _openDialog(tester);
        await tester.pump();

        await tester.tap(find.text('Continue with Google'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(launched, isTrue);
        expect(manager.hasJwt, isTrue);
        expect(manager.wallet.account?.login, 'a@b.dev');
        expect(manager.wallet.account?.displayName, 'Alice');
        expect(find.byType(SignInDialog), findsNothing);
      });
    });

    testWidgets('a failed exchange surfaces the server error', (tester) async {
      await _asDesktop(() async {
        final httpClient = FakeHttpClient()
          ..respond(200, body: _initiateBody)
          ..respond(
            400,
            body: '{"error":{"code":"invalid_grant","message":"code expired"}}',
          );
        final manager = await _manager(httpClient);

        await tester.pumpWidget(_launcher(manager));
        await _openDialog(tester);
        await tester.pump();

        await tester.tap(find.text('Continue with Google'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byKey(const ValueKey('signInError')), findsOneWidget);
        expect(find.text('code expired'), findsOneWidget);
        expect(manager.hasJwt, isFalse);
        expect(find.byType(SignInDialog), findsOneWidget);
      });
    });

    testWidgets('iOS shows the mobile note instead of provider buttons', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final manager = await _manager(FakeHttpClient());

        await tester.pumpWidget(_launcher(manager));
        await _openDialog(tester);
        await tester.pump();

        expect(find.byKey(const ValueKey('signInMobileNote')), findsOneWidget);
        expect(find.text('Continue with Google'), findsNothing);
        // The developer section still works on mobile.
        expect(find.text('Developer (local only)'), findsOneWidget);
      } finally {
        // Inline reset: the binding's invariant check runs before
        // teardowns, so addTearDown would be too late.
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('dev login success: the manager holds the JWT + login and '
        'the dialog closes', (tester) async {
      await _asDesktop(() async {
        final httpClient = FakeHttpClient()
          ..respond(200, body: '{"token":"jwt-1"}');
        final manager = await _manager(httpClient);

        await tester.pumpWidget(_launcher(manager));
        await _openDialog(tester);

        expect(find.byType(SignInDialog), findsOneWidget);

        await _submitDevLogin(tester, login: 'bob', password: 'pw');

        expect(manager.hasJwt, isTrue);
        expect(manager.accountLogin, 'bob');
        expect(find.byType(SignInDialog), findsNothing);
      });
    });

    testWidgets('dev login failure: the server error message shows, no '
        'JWT stored', (tester) async {
      await _asDesktop(() async {
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

        await _submitDevLogin(tester, login: 'bob', password: 'wrong');

        expect(find.byKey(const ValueKey('signInError')), findsOneWidget);
        expect(find.text('invalid login or password'), findsOneWidget);
        expect(manager.hasJwt, isFalse);
        expect(find.byType(SignInDialog), findsOneWidget);
      });
    });
  });
}
