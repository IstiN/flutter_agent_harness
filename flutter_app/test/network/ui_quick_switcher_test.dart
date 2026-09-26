// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/join_sheet.dart';
import 'package:fa/ui/network/network_home.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Future<NetworkSessionManager> _manager({
  required KeyWallet wallet,
  FakeHttpClient? httpClient,
  String? jwt,
}) async => NetworkSessionManager(
  baseUrl: testBase,
  wallet: wallet,
  httpClient: httpClient ?? FakeHttpClient(),
  wsConnector: FakeWsConnector(),
  jwtToken: jwt,
);

/// A wallet with an identity and two memberships (both resumable).
Future<KeyWallet> _wallet() async {
  final wallet = await KeyWallet.load(MemoryWalletBackend());
  await wallet.createIfMissing(displayName: 'Me');
  await wallet.addNetwork(networkId: 'net1', name: 'fa-team', password: 'pw1');
  await wallet.addNetwork(
    networkId: 'net2',
    name: 'side-project',
    password: 'pw2',
  );
  return wallet;
}

Widget _wrap({
  required NetworkModeController controller,
  required NetworkSessionManager manager,
}) => MaterialApp(
  theme: buildFahTheme(),
  home: NetworkHomePage(controller: controller, manager: manager),
);

/// Runs [body] with [debugDefaultTargetPlatformOverride] set, always
/// restoring it (the post-test invariant check rejects a leaked override).
Future<void> onPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// Presses ⌘+[key] (meta held) and lets dialogs animate in.
Future<void> pressMeta(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  await tester.sendKeyDownEvent(key, platform: 'macos');
  await tester.sendKeyUpEvent(key, platform: 'macos');
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('NetworkQuickSwitcher', () {
    testWidgets(
      '⌘K opens the switcher with create/join/recent rows',
      (tester) => onPlatform(TargetPlatform.macOS, () async {
        final controller = NetworkModeController.inMemory(
          mode: AppMode.network,
        );
        final manager = await _manager(wallet: await _wallet(), jwt: 'jwt-1');

        await tester.pumpWidget(
          _wrap(controller: controller, manager: manager),
        );
        await tester.pump();

        await pressMeta(tester, LogicalKeyboardKey.keyK);

        final dialog = find.byKey(const ValueKey('networkQuickSwitcher'));
        expect(dialog, findsOneWidget);
        Finder row(String text) =>
            find.descendant(of: dialog, matching: find.text(text));
        expect(row('Create a network'), findsOneWidget);
        expect(row('Join a network'), findsOneWidget);
        // Recents in membership order: net1 → ⌘3, net2 → ⌘4.
        expect(row('fa-team'), findsOneWidget);
        expect(row('side-project'), findsOneWidget);
        expect(row('⌘1'), findsOneWidget);
        expect(row('⌘2'), findsOneWidget);
        expect(row('⌘3'), findsOneWidget);
        expect(row('⌘4'), findsOneWidget);
      }),
    );

    testWidgets(
      '⌘K lists the last-used network first (⌘3)',
      (tester) => onPlatform(TargetPlatform.macOS, () async {
        final controller = NetworkModeController.inMemory(
          mode: AppMode.network,
          networkId: 'net2',
        );
        final httpClient = FakeHttpClient()
          ..respond(200, body: joinBodyOk)
          ..respond(200, body: channelsBody)
          ..respond(200, body: membersBody);
        final manager = await _manager(
          wallet: await _wallet(),
          httpClient: httpClient,
        );

        await tester.pumpWidget(
          _wrap(controller: controller, manager: manager),
        );
        await tester.pump();
        // The restored selection silently resumes; wait for the session
        // so the scripted responses stay aligned.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(manager.sessions.containsKey('net2'), isTrue);

        await pressMeta(tester, LogicalKeyboardKey.keyK);

        final dialog = find.byKey(const ValueKey('networkQuickSwitcher'));
        final lastUsed = find.descendant(
          of: dialog,
          matching: find.byKey(const ValueKey('quickSwitcher:net2')),
        );
        expect(lastUsed, findsOneWidget);
        expect(
          find.descendant(of: lastUsed, matching: find.text('⌘3')),
          findsOneWidget,
        );
        final other = find.descendant(
          of: dialog,
          matching: find.byKey(const ValueKey('quickSwitcher:net1')),
        );
        expect(
          find.descendant(of: other, matching: find.text('⌘4')),
          findsOneWidget,
        );
        // Close inside the body: the session's WS heartbeat timer must
        // not outlive the test (fake-async invariant).
        await manager.disconnectAll();
      }),
    );

    testWidgets(
      '⌘2 opens the join sheet',
      (tester) => onPlatform(TargetPlatform.macOS, () async {
        final controller = NetworkModeController.inMemory(
          mode: AppMode.network,
        );
        final manager = await _manager(wallet: await _wallet());

        await tester.pumpWidget(
          _wrap(controller: controller, manager: manager),
        );
        await tester.pump();

        await pressMeta(tester, LogicalKeyboardKey.digit2);

        expect(find.byType(JoinSheet), findsOneWidget);
      }),
    );

    testWidgets(
      '⌘3 switches to the recent network through resume',
      (tester) => onPlatform(TargetPlatform.macOS, () async {
        final controller = NetworkModeController.inMemory(
          mode: AppMode.network,
        );
        final httpClient = FakeHttpClient()
          ..respond(200, body: joinBodyOk)
          ..respond(200, body: channelsBody)
          ..respond(200, body: membersBody);
        final manager = await _manager(
          wallet: await _wallet(),
          httpClient: httpClient,
        );

        await tester.pumpWidget(
          _wrap(controller: controller, manager: manager),
        );
        await tester.pump();

        await pressMeta(tester, LogicalKeyboardKey.digit3);
        await tester.pump();

        expect(controller.networkId, 'net1');
        expect(manager.sessions.containsKey('net1'), isTrue);
        await manager.disconnectAll();
      }),
    );

    testWidgets(
      'tapping a recent row switches the network',
      (tester) => onPlatform(TargetPlatform.macOS, () async {
        final controller = NetworkModeController.inMemory(
          mode: AppMode.network,
        );
        final httpClient = FakeHttpClient()
          ..respond(200, body: joinBodyOk)
          ..respond(200, body: channelsBody)
          ..respond(200, body: membersBody);
        final manager = await _manager(
          wallet: await _wallet(),
          httpClient: httpClient,
        );

        await tester.pumpWidget(
          _wrap(controller: controller, manager: manager),
        );
        await tester.pump();

        await pressMeta(tester, LogicalKeyboardKey.keyK);
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('networkQuickSwitcher')),
            matching: find.byKey(const ValueKey('quickSwitcher:net2')),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(controller.networkId, 'net2');
        expect(manager.sessions.containsKey('net2'), isTrue);
        await manager.disconnectAll();
      }),
    );

    testWidgets(
      'mobile: no shortcut handlers are registered',
      (tester) => onPlatform(TargetPlatform.iOS, () async {
        final controller = NetworkModeController.inMemory(
          mode: AppMode.network,
        );
        final manager = await _manager(wallet: await _wallet());

        await tester.pumpWidget(
          _wrap(controller: controller, manager: manager),
        );
        await tester.pump();

        await pressMeta(tester, LogicalKeyboardKey.keyK);
        expect(
          find.byKey(const ValueKey('networkQuickSwitcher')),
          findsNothing,
        );

        await pressMeta(tester, LogicalKeyboardKey.digit2);
        expect(find.byType(JoinSheet), findsNothing);

        await pressMeta(tester, LogicalKeyboardKey.digit3);
        expect(controller.networkId, isNull);
        expect(manager.sessions, isEmpty);
      }),
    );
  });
}
