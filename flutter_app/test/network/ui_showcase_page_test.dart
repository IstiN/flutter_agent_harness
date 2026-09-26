// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/network/showcase_viewer.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/showcase_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  group('ShowcasePage', () {
    Future<NetworkSessionManager> newManager(FakeHttpClient http) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Me');
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: http,
        wsConnector: FakeWsConnector(),
      );
      addTearDown(manager.disconnectAll);
      return manager;
    }

    Future<void> pumpPage(
      WidgetTester tester,
      NetworkModeController controller,
      NetworkSessionManager manager,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          home: Scaffold(
            body: ShowcasePage(controller: controller, manager: manager),
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    testWidgets('no showcase selected renders nothing', (tester) async {
      final controller = NetworkModeController.inMemory();
      final manager = await newManager(FakeHttpClient());

      await pumpPage(tester, controller, manager);

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(ListView), findsNothing);
    });

    testWidgets('a private/unknown network renders the generic 404 note', (
      tester,
    ) async {
      final http = FakeHttpClient()
        ..respond(404, body: '{"error":{"code":"not_found","message":"nf"}}');
      final controller = NetworkModeController.inMemory();
      await controller.viewShowcase('net1');
      final manager = await newManager(http);

      await pumpPage(tester, controller, manager);

      expect(
        find.text('This network is not publicly available'),
        findsOneWidget,
      );
      expect(http.requests.single.url.path, '/api/networks/net1/showcase');
    });

    testWidgets(
      'loads channels, opens one read-only, and the back button leaves',
      (tester) async {
        final http = FakeHttpClient()
          ..respond(
            200,
            body:
                '{"id":"net1","name":"fa-team","channels":['
                '{"id":"pc1","name":"announcements"},'
                '{"id":"pc2"}'
                ']}',
          )
          ..respond(
            200,
            body:
                '{"items":[{"id":"e1","channelId":"pc1","senderId":"olya",'
                '"payload":"${encodePublicChannelText('hello public')}"}],'
                '"nextCursor":""}',
          );
        final controller = NetworkModeController.inMemory();
        await controller.viewShowcase('net1');
        final manager = await newManager(http);

        await pumpPage(tester, controller, manager);

        // Header + channel list (a nameless channel falls back to its id).
        expect(find.text('fa-team'), findsOneWidget);
        expect(find.text('read-only'), findsOneWidget);
        expect(find.text('announcements'), findsOneWidget);
        expect(find.text('pc2'), findsOneWidget);
        expect(find.text('Select a channel'), findsOneWidget);

        // Open the channel: the shared chat shows the decoded public
        // message and the read-only composer note replaces the input.
        await tester.tap(find.text('announcements'));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(find.textContaining('hello public'), findsOneWidget);
        expect(
          find.text(
            'Public showcase — read-only preview. '
            'Join the network to participate.',
          ),
          findsOneWidget,
        );
        expect(http.requests.last.url.path, '/api/channels/pc1/messages');
        // Anonymous by contract: no bearer ever rides a showcase read.
        expect(http.requests.last.headers['authorization'], isNull);

        // Back closes the preview (controller state drops the showcase;
        // the shell rebuilds the page away — the page itself does not
        // listen to the controller).
        await tester.tap(find.byKey(const ValueKey('showcaseBack')));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(controller.showcaseNetworkId, isNull);
      },
    );
  });
}
