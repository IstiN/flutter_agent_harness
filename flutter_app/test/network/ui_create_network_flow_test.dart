// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/create_network_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Widget coverage for [runCreateNetworkFlow] (CRAP descent, #896
/// validation): the flow was 20% covered / CC 8 (CRAP 40.8). These tests
/// walk every branch — cancel, the no-JWT guard, the happy path through
/// create → join → live session, and both snackbar error arms.
void main() {
  group('runCreateNetworkFlow', () {
    Future<NetworkSessionManager> newManager(
      FakeHttpClient http, {
      String? jwt,
    }) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: http,
        wsConnector: FakeWsConnector(),
        jwtToken: jwt,
      );
      addTearDown(manager.disconnectAll);
      return manager;
    }

    Future<void> pumpEntry(
      WidgetTester tester,
      NetworkModeController controller,
      NetworkSessionManager manager,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => runCreateNetworkFlow(
                  context,
                  controller: controller,
                  manager: manager,
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> openDialog(WidgetTester tester) async {
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
    }

    Future<void> fillAndSubmit(
      WidgetTester tester, {
      required String name,
      required String password,
    }) async {
      await tester.enterText(find.byType(TextField).at(0), name);
      await tester.enterText(find.byType(TextField).at(1), password);
      await tester.tap(find.byKey(const ValueKey('createNetworkConfirm')));
      await tester.pumpAndSettle();
    }

    testWidgets('cancel returns before any network call', (tester) async {
      final http = FakeHttpClient();
      final controller = NetworkModeController.inMemory();
      final manager = await newManager(http, jwt: 'jwt-1');
      await pumpEntry(tester, controller, manager);

      await openDialog(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(http.requests, isEmpty);
      expect(controller.networkId, isNull);
    });

    testWidgets(
      'validation errors stay in the dialog; without a JWT the flow stops '
      'at the sign-in snackbar',
      (tester) async {
        final http = FakeHttpClient();
        final controller = NetworkModeController.inMemory();
        final manager = await newManager(http); // no JWT
        await pumpEntry(tester, controller, manager);

        await openDialog(tester);
        // Invalid name + too-short password: inline errors, no submit.
        await fillAndSubmit(tester, name: '!!', password: 'x');
        expect(find.textContaining('Needs 3–64 chars'), findsOneWidget);
        expect(
          find.textContaining('Password must be 8–128 characters'),
          findsOneWidget,
        );
        expect(find.byType(AlertDialog), findsOneWidget);

        // Valid input submits, but a JWT-less manager never round-trips a
        // management call — the sign-in nudge shows instead.
        await fillAndSubmit(tester, name: 'My Net', password: 'hunter2xx');
        expect(find.text('Sign in to create a network'), findsOneWidget);
        expect(http.requests, isEmpty);
        expect(controller.networkId, isNull);
      },
    );

    testWidgets('happy path: create → join → live session → enterNetwork', (
      tester,
    ) async {
      final http = FakeHttpClient()
        // POST /api/networks (management, JWT)
        ..respond(
          201,
          body:
              '{"network":{"id":"net9","name":"my-net","ownerId":"me-1",'
              '"publicChannels":[]},"joinCredentials":{"networkId":"net9",'
              '"password":"pw-net9"}}',
        )
        // POST /api/networks/net9/join
        ..respond(
          200,
          body:
              '{"sessionToken":"st-9","identity":{"id":"me-1",'
              '"class":"owner","displayName":"Me"},"network":{"id":"net9",'
              '"name":"my-net","ownerId":"me-1","publicChannels":[]}}',
        )
        // session.start(): channels + members
        ..respond(200, body: '[]')
        ..respond(
          200,
          body:
              '[{"id":"me-1","class":"owner","displayName":"Me",'
              '"presence":"live"}]',
        );
      final controller = NetworkModeController.inMemory();
      final manager = await newManager(http, jwt: 'jwt-1');
      await pumpEntry(tester, controller, manager);

      await openDialog(tester);
      await fillAndSubmit(tester, name: 'My Net', password: 'hunter2xx');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // The display name folded to a slug on the wire.
      final create = http.requests.first;
      expect(create.method, 'POST');
      expect(create.url.path, '/api/networks');
      expect(create.body, contains('"name":"my-net"'));
      expect(create.headers['authorization'], 'Bearer jwt-1');
      // Joined with the one-time credentials and entered.
      expect(manager.sessions['net9'], isNotNull);
      expect(manager.wallet.networks['net9'], isNotNull);
      expect(controller.networkId, 'net9');
      expect(controller.mode, AppMode.network);
    });

    testWidgets('a server rejection surfaces as a snackbar', (tester) async {
      final http = FakeHttpClient()
        ..respond(
          401,
          body: '{"error":{"code":"unauthorized","message":"bad token"}}',
        );
      final controller = NetworkModeController.inMemory();
      final manager = await newManager(http, jwt: 'jwt-1');
      await pumpEntry(tester, controller, manager);

      await openDialog(tester);
      await fillAndSubmit(tester, name: 'My Net', password: 'hunter2xx');

      expect(find.textContaining('bad token'), findsOneWidget);
      expect(manager.sessions, isEmpty);
      expect(controller.networkId, isNull);
    });

    testWidgets('a malformed response surfaces the generic error', (
      tester,
    ) async {
      final http = FakeHttpClient()..respond(201, body: 'not json');
      final controller = NetworkModeController.inMemory();
      final manager = await newManager(http, jwt: 'jwt-1');
      await pumpEntry(tester, controller, manager);

      await openDialog(tester);
      await fillAndSubmit(tester, name: 'My Net', password: 'hunter2xx');

      expect(find.textContaining('FormatException'), findsOneWidget);
      expect(manager.sessions, isEmpty);
    });
  });
}
