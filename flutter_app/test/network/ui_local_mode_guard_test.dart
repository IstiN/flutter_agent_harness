// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/main.dart' show faHomeScreen;
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/channel_rail.dart';
import 'package:fa/ui/network/network_center.dart';
import 'package:fa/ui/network/network_chat_page.dart';
import 'package:fa/ui/network/network_home.dart';
import 'package:fa/ui/network/network_mode_chip.dart';
import 'package:fa/ui/network/networks_sidebar.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/widgets/sidebar_sessions_list.dart';
import 'package:fa/ui/widgets/widget_publication_resume_refresh.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show MemoryExecutionEnv;
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Pumps [faHomeScreen]'s choice at [size] and returns the built widget.
Future<Widget> _homeAt(
  WidgetTester tester,
  Size size, {
  NetworkModeController? networkMode,
  NetworkSessionManager? networkSessions,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final manager = FlutterSessionManager(
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
  );
  late Widget home;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      home: Builder(
        builder: (context) {
          home = faHomeScreen(
            context: context,
            manager: manager,
            networkMode: networkMode,
            networkSessions: networkSessions,
          );
          return home;
        },
      ),
    ),
  );
  await tester.pump();
  return home;
}

Future<NetworkSessionManager> _networkManager({
  KeyWallet? wallet,
  String? jwt,
}) async => NetworkSessionManager(
  baseUrl: testBase,
  wallet: wallet ?? await KeyWallet.load(MemoryWalletBackend()),
  httpClient: FakeHttpClient(),
  wsConnector: FakeWsConnector(),
  jwtToken: jwt,
);

void main() {
  group('AC-N1: local mode structural guard', () {
    testWidgets('no network wiring → the byte-identical classic tree', (
      tester,
    ) async {
      final home = await _homeAt(tester, const Size(390, 844));
      expect(home, isA<WidgetPublicationResumeRefresher>());
      expect(
        (home as WidgetPublicationResumeRefresher).child,
        isA<AppLauncherScreen>(),
      );
      // Not a single network widget in the tree — no gate, no chip.
      expect(find.byType(NetworkHomePage), findsNothing);
      expect(find.byType(NetworkModeChip), findsNothing);
      expect(find.byType(NetworksSidebar), findsNothing);
      expect(find.byType(ChannelRail), findsNothing);
      expect(find.byType(NetworkChatPage), findsNothing);
    });

    testWidgets('wide without network wiring → the classic wide shell', (
      tester,
    ) async {
      final home = await _homeAt(tester, const Size(1280, 800));
      expect(home, isA<WidgetPublicationResumeRefresher>());
      expect(
        (home as WidgetPublicationResumeRefresher).child,
        isA<WideLayoutShell>(),
      );
      expect(find.byType(NetworkHomePage), findsNothing);
      expect(find.byType(NetworkModeChip), findsNothing);
    });

    testWidgets('narrow local mode with wiring → the local surface, no '
        'network surfaces', (tester) async {
      final controller = NetworkModeController.inMemory();
      final manager = await _networkManager();
      final home = await _homeAt(
        tester,
        const Size(390, 844),
        networkMode: controller,
        networkSessions: manager,
      );
      // The gate wraps the local home in a ListenableBuilder; the local
      // surface itself is intact below it.
      expect(find.byType(AppLauncherScreen), findsOneWidget);
      expect(find.byType(NetworkHomePage), findsNothing);
      expect(find.byType(NetworksSidebar), findsNothing);
      expect(find.byType(ChannelRail), findsNothing);
      expect(find.byType(NetworkChatPage), findsNothing);
      expect(home, isA<ListenableBuilder>());
    });

    testWidgets('wide local mode with wiring → no tree swap, the classic '
        'sidebar content stays', (tester) async {
      final controller = NetworkModeController.inMemory();
      final manager = await _networkManager();
      final home = await _homeAt(
        tester,
        const Size(1280, 800),
        networkMode: controller,
        networkSessions: manager,
      );
      // No ListenableBuilder gate on wide — the shell consumes the mode.
      expect(home, isA<WidgetPublicationResumeRefresher>());
      expect(find.byType(WideLayoutShell), findsOneWidget);
      expect(find.byType(SidebarSessionsList), findsOneWidget);
      expect(find.byType(NetworksSidebar), findsNothing);
      expect(find.byType(NetworkCenterPane), findsNothing);
      expect(find.byType(NetworkHomePage), findsNothing);
    });

    testWidgets('wide network mode → the shell swaps the SIDEBAR CONTENT, '
        'not the screen', (tester) async {
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = await _networkManager();
      final home = await _homeAt(
        tester,
        const Size(1280, 800),
        networkMode: controller,
        networkSessions: manager,
      );
      expect(home, isA<WidgetPublicationResumeRefresher>());
      expect(find.byType(WideLayoutShell), findsOneWidget);
      expect(find.byType(NetworkHomePage), findsNothing);
      // The sidebar shows the networks list instead of the sessions list.
      expect(
        find.descendant(
          of: find.byType(WideLayoutShell),
          matching: find.byType(NetworksSidebar),
        ),
        findsOneWidget,
      );
      expect(find.byType(SidebarSessionsList), findsNothing);
      // The center shows the network empty state (no network selected).
      expect(find.byType(NetworkCenterPane), findsOneWidget);
      expect(find.text('Welcome to Fa networks'), findsOneWidget);
      expect(find.byKey(const ValueKey('networkCenterJoin')), findsOneWidget);
    });

    testWidgets('narrow network mode → NetworkHomePage, the networks list '
        'is the first screen (no onboarding gate)', (tester) async {
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      // No identity in the wallet — the picker must still render.
      final manager = await _networkManager();
      addTearDown(manager.disconnectAll);
      await _homeAt(
        tester,
        const Size(390, 844),
        networkMode: controller,
        networkSessions: manager,
      );
      expect(find.byType(NetworkHomePage), findsOneWidget);
      expect(find.byType(AppLauncherScreen), findsNothing);
      expect(
        find.descendant(
          of: find.byType(NetworkHomePage),
          matching: find.byType(NetworksSidebar),
        ),
        findsOneWidget,
      );
      // The onboarding gate is gone — identity is created lazily.
      expect(find.text('Welcome to Fa networks'), findsNothing);
      expect(find.byKey(const ValueKey('identityContinue')), findsNothing);
      // The empty wallet's CTA is visible right away.
      expect(find.byKey(const ValueKey('joinFirstNetwork')), findsOneWidget);
    });
  });
}
