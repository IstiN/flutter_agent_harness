// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_panel.dart';
import 'package:fa/ui/chats/network_inbox_adapter.dart';
import 'package:fa/ui/chats/networks_list_panel.dart';
import 'package:fa/ui/network/channel_rail.dart';
import 'package:fa/ui/network/join_sheet.dart';
import 'package:fa/ui/network/network_center.dart';
import 'package:fa/ui/network/network_chat_page.dart';
import 'package:fa/ui/network/sign_in_dialog.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show
        Agent,
        AssistantMessage,
        AssistantMessageEventStream,
        DoneEvent,
        ExecutionEnv,
        MemoryExecutionEnv,
        Model,
        StopReason,
        TextContent,
        ToolRegistry,
        Usage;
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

AgentService _fakeLocalService(ExecutionEnv env) {
  return AgentService(
    agent: Agent(
      model: Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test',
        baseUrl: 'https://example.com',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'You are Fa.',
      streamFunction: (model, context, {cancelToken}) {
        final stream = AssistantMessageEventStream();
        stream.push(
          DoneEvent(
            reason: StopReason.stop,
            message: AssistantMessage(
              content: const [TextContent(text: 'ok')],
              api: model.api,
              provider: model.provider,
              model: model.id,
              usage: Usage.zero,
              stopReason: StopReason.stop,
              timestamp: DateTime.utc(2026),
            ),
          ),
        );
        stream.end();
        return stream;
      },
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: '/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
}

/// Pumps the current wide messenger surface with an injected aggregate inbox.
Future<FlutterSessionManager> _pumpWideHome(
  WidgetTester tester, {
  required NetworkModeController controller,
  required NetworkSessionManager manager,
  NetworkInboxAdapter? networkInboxAdapter,
  Size surface = const Size(1280, 800),
  bool withLocalSession = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = surface;
  addTearDown(tester.view.reset);
  final env = MemoryExecutionEnv();
  final sessions = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
  if (withLocalSession) {
    sessions.addSession(
      'local-session',
      _fakeLocalService(env)
        ..messages.add(FahChatMessage(role: 'user', content: 'Real content')),
    );
    sessions.addSession('empty-placeholder', _fakeLocalService(env));
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      home: WideLayoutShell(
        manager: sessions,
        networkMode: controller,
        networkSessions: manager,
        networkInboxAdapter:
            networkInboxAdapter ?? FixtureNetworkInboxAdapter(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return sessions;
}

/// Pumps the legacy detail pane itself, without recreating the removed shell
/// Networks section. Its ensureNetworkSession behavior remains under test.
Future<void> _pumpNetworkCenter(
  WidgetTester tester, {
  required NetworkModeController controller,
  required NetworkSessionManager manager,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      home: Scaffold(
        body: NetworkCenterPane(controller: controller, manager: manager),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _openNetworkManagement(WidgetTester tester) async {
  // The identity globe opens the NETWORKS panel; management lives behind
  // the panel header's gear.
  await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-network')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byKey(const ValueKey('chatNetworksList')), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('chatNetworksManage')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byKey(const ValueKey('chatNetworksCreateJoin')), findsOneWidget);
}

void main() {
  group('Wide network management and detail-pane session resume', () {
    testWidgets('the unified Chats list opens network management and the '
        'create/join sheet without a Networks rail', (tester) async {
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: await KeyWallet.load(MemoryWalletBackend()),
        httpClient: FakeHttpClient(),
        wsConnector: FakeWsConnector(),
        jwtToken: 'jwt-1',
      );
      addTearDown(manager.disconnectAll);
      await _pumpWideHome(tester, controller: controller, manager: manager);

      expect(find.byType(WideLayoutShell), findsOneWidget);
      expect(find.byType(ChatListPanel), findsOneWidget);
      expect(find.byType(NetworkCenterPane), findsNothing);
      expect(find.byKey(const ValueKey('networkCenterJoin')), findsNothing);

      await _openNetworkManagement(tester);
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('Networks'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('chatNetworksCreateJoin')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(JoinSheet), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(JoinSheet), findsNothing);
    });

    testWidgets('Networks lives in Apps instead of the secondary sidebar nav', (
      tester,
    ) async {
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: await KeyWallet.load(MemoryWalletBackend()),
        httpClient: FakeHttpClient(),
        wsConnector: FakeWsConnector(),
        jwtToken: 'jwt-1',
      );
      addTearDown(manager.disconnectAll);
      await _pumpWideHome(tester, controller: controller, manager: manager);

      await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
      await tester.pumpAndSettle();
      // The Apps surface owns the Networks entry; the rail's identity
      // row (same label) is a filter menu trigger, not a nav duplicate.
      final appsSurface = find.byType(AppLauncherScreen);
      final networksCard = find.descendant(
        of: appsSurface,
        matching: find.text('Networks'),
      );
      expect(networksCard, findsOneWidget);
      await tester.ensureVisible(networksCard);
      await tester.tap(networksCard);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('chatNetworksCreateJoin')),
        findsOneWidget,
      );
    });

    testWidgets('guest network management keeps join available and offers '
        'sign-in instead of the old create affordance', (tester) async {
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: await KeyWallet.load(MemoryWalletBackend()),
        httpClient: FakeHttpClient(),
        wsConnector: FakeWsConnector(),
      );
      addTearDown(manager.disconnectAll);
      await _pumpWideHome(tester, controller: controller, manager: manager);

      await _openNetworkManagement(tester);
      expect(find.byKey(const ValueKey('chatNetworksSignIn')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('chatNetworksCreateJoin')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('networkCenterCreate')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('chatNetworksSignIn')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(SignInDialog), findsOneWidget);
    });

    testWidgets(
      'signed-in network management shows the account and signs out',
      (tester) async {
        final wallet = await KeyWallet.load(MemoryWalletBackend());
        await wallet.saveAccount(
          WalletAccount(
            provider: 'google',
            login: 'alice@example.test',
            displayName: 'Alice Example',
            accessToken: 'access-token',
            refreshToken: 'refresh-token',
            accessExpiresAt: DateTime.utc(2030),
          ),
        );
        final controller = NetworkModeController.inMemory(
          mode: AppMode.network,
        );
        final manager = NetworkSessionManager(
          baseUrl: testBase,
          wallet: wallet,
          httpClient: FakeHttpClient(),
          wsConnector: FakeWsConnector(),
          jwtToken: 'access-token',
        );
        addTearDown(manager.disconnectAll);
        await _pumpWideHome(tester, controller: controller, manager: manager);

        await _openNetworkManagement(tester);
        expect(find.byKey(const ValueKey('accountLabel')), findsOneWidget);
        expect(find.text('Alice Example'), findsOneWidget);
        expect(find.byKey(const ValueKey('signOutButton')), findsOneWidget);
        expect(find.byKey(const ValueKey('chatNetworksSignIn')), findsNothing);

        await tester.tap(find.byKey(const ValueKey('signOutButton')));
        await tester.pump();
        await tester.pump();
        expect(wallet.account, isNull);
        expect(manager.hasJwt, isFalse);
        expect(find.byKey(const ValueKey('accountLabel')), findsNothing);
        expect(find.byKey(const ValueKey('signOutButton')), findsNothing);
        expect(
          find.byKey(const ValueKey('chatNetworksSignIn')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('chatNetworksCreateJoin')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'an expired stored account keeps re-auth and sign out visible',
      (tester) async {
        final wallet = await KeyWallet.load(MemoryWalletBackend());
        await wallet.saveAccount(
          WalletAccount(
            provider: 'github',
            login: 'bob@example.test',
            displayName: '',
            accessToken: 'expired-access',
            refreshToken: 'expired-refresh',
            accessExpiresAt: DateTime.utc(2026, 2, 1, 11),
            refreshExpiresAt: DateTime.utc(2026, 2, 1, 12),
          ),
        );
        final controller = NetworkModeController.inMemory(
          mode: AppMode.network,
        );
        final manager = NetworkSessionManager(
          baseUrl: testBase,
          wallet: wallet,
          httpClient: FakeHttpClient(),
          wsConnector: FakeWsConnector(),
          jwtToken: 'expired-access',
          clock: () => DateTime.utc(2026, 2, 1, 13),
        );
        addTearDown(manager.disconnectAll);
        await manager.restoreAccount();
        expect(manager.sessionExpired, isTrue);
        await _pumpWideHome(tester, controller: controller, manager: manager);

        await _openNetworkManagement(tester);
        expect(find.text('bob@example.test'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('sessionExpiredNote')),
          findsOneWidget,
        );
        expect(find.text('Session expired — sign in again.'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('chatNetworksSignIn')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('signOutButton')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('chatNetworksSignIn')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(SignInDialog), findsOneWidget);
      },
    );

    testWidgets('a stored network password resumes without a prompt', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        password: 'secret-pw',
      );
      final httpClient = FakeHttpClient()
        ..respond(200, body: joinBodyOk)
        ..respond(200, body: channelsBody)
        ..respond(200, body: membersBody);
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: httpClient,
        wsConnector: FakeWsConnector(),
      );
      addTearDown(manager.disconnectAll);
      await _pumpWideHome(tester, controller: controller, manager: manager);

      await _openNetworkManagement(tester);
      final dialogContext = tester.element(find.byType(Dialog));
      final dialog = tester.widget<Dialog>(find.byType(Dialog));
      expect(dialog.backgroundColor, FahColors.of(dialogContext).panel);
      expect(dialog.surfaceTintColor, Colors.transparent);
      final membership = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'fa-team'),
      );
      final leading = membership.leading! as Icon;
      expect(leading.icon, Icons.public);
      expect(leading.size, 22);
      expect(leading.color, Theme.of(dialogContext).colorScheme.primary);

      await tester.tap(find.widgetWithText(ListTile, 'fa-team'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(JoinSheet), findsNothing);
      expect(controller.networkId, 'net1');
      expect(manager.sessions.containsKey('net1'), isTrue);
      await manager.disconnectAll();
    });

    testWidgets(
      'a missing password is explained once and stored after unlock',
      (tester) async {
        final backend = MemoryWalletBackend();
        final wallet = await KeyWallet.load(backend);
        await wallet.createIfMissing(displayName: 'Me');
        await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
        final httpClient = FakeHttpClient()
          ..respond(200, body: joinBodyOk)
          ..respond(200, body: channelsBody)
          ..respond(200, body: membersBody)
          ..respond(200, body: joinBodyOk)
          ..respond(200, body: channelsBody)
          ..respond(200, body: membersBody);
        final controller = NetworkModeController.inMemory(
          mode: AppMode.network,
          networkId: 'net1',
        );
        final manager = NetworkSessionManager(
          baseUrl: testBase,
          wallet: wallet,
          httpClient: httpClient,
          wsConnector: FakeWsConnector(),
          jwtToken: 'jwt-1',
        );
        addTearDown(manager.disconnectAll);
        await _pumpWideHome(tester, controller: controller, manager: manager);

        await _openNetworkManagement(tester);
        await tester.tap(find.widgetWithText(ListTile, 'fa-team'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byType(JoinSheet), findsOneWidget);
        expect(
          find.byKey(const ValueKey('networkNeedsPasswordExplanation')),
          findsOneWidget,
        );
        expect(find.textContaining('join once'), findsOneWidget);
        final joinFields = tester.widgetList<TextField>(
          find.descendant(
            of: find.byType(JoinSheet),
            matching: find.byType(TextField),
          ),
        );
        expect(
          joinFields.any((field) => field.controller?.text == 'net1'),
          isTrue,
        );

        await tester.enterText(
          find.widgetWithText(TextField, 'Password'),
          'secret-pw',
        );
        await tester.tap(find.text('Join'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(JoinSheet), findsNothing);
        expect(wallet.networks['net1']?.password, 'secret-pw');
        final persisted = await KeyWallet.load(backend);
        expect(persisted.networks['net1']?.password, 'secret-pw');
        expect(manager.sessions.containsKey('net1'), isTrue);

        await manager.disconnectAll();
        await _openNetworkManagement(tester);
        await tester.tap(find.widgetWithText(ListTile, 'fa-team'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(JoinSheet), findsNothing);
        expect(manager.sessions.containsKey('net1'), isTrue);
        expect(
          httpClient.requests.where(
            (r) => r.url.path == '/api/networks/net1/join',
          ),
          hasLength(2),
        );
        await manager.disconnectAll();
      },
    );

    testWidgets('the injected aggregate inbox renders network conversations '
        'inside the unified Chats list', (tester) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
      final controller = NetworkModeController.inMemory(
        mode: AppMode.network,
        networkId: 'net1',
      );
      final httpClient = FakeHttpClient();
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: httpClient,
        wsConnector: FakeWsConnector(),
        jwtToken: 'jwt-1',
      );
      addTearDown(manager.disconnectAll);
      final inbox = FixtureNetworkInboxAdapter(
        items: [
          NetworkInboxItem(
            kind: ChatListEntryKind.networkChannel,
            networkId: 'net1',
            id: 'c1',
            title: 'general',
            lastActivity: DateTime.utc(2026, 8, 1, 12),
            unreadCount: 2,
          ),
        ],
      );

      await _pumpWideHome(
        tester,
        controller: controller,
        manager: manager,
        networkInboxAdapter: inbox,
      );
      await tester.pump();

      expect(find.byType(WideLayoutShell), findsOneWidget);
      expect(find.byType(ChatListPanel), findsOneWidget);
      expect(find.text('general'), findsOneWidget);
      expect(inbox.fetchCount, 1);
      expect(httpClient.requests, isEmpty);
      expect(find.byType(NetworkCenterPane), findsNothing);
      expect(find.byType(ChannelRail), findsNothing);
      expect(find.byKey(const ValueKey('membership:net1')), findsNothing);
    });

    for (final surface in [const Size(1280, 800), const Size(390, 844)]) {
      testWidgets('tapping a public-network channel opens shared chat at '
          '${surface.width.toInt()}px', (tester) async {
        final wallet = await KeyWallet.load(MemoryWalletBackend());
        await wallet.addNetwork(networkId: 'net1', name: 'epam-public');
        final httpClient = FakeHttpClient()
          ..respond(
            200,
            body:
                '[{"id":"c1","networkId":"net1","name":"general","public":true}]',
          )
          ..respond(200, body: membersBody)
          ..respond(200, body: '{"items":[],"nextCursor":""}');
        final session = buildSession(
          httpClient: httpClient,
          connector: FakeWsConnector(),
          wallet: wallet,
        );
        await session.start();
        final manager = NetworkSessionManager(
          baseUrl: testBase,
          wallet: wallet,
          httpClient: FakeHttpClient(),
          wsConnector: FakeWsConnector(),
        )..sessions['net1'] = session;
        addTearDown(manager.disconnectAll);
        final controller = NetworkModeController.inMemory();
        final localSessions = await _pumpWideHome(
          tester,
          controller: controller,
          manager: manager,
          surface: surface,
          withLocalSession: surface.width >= 700,
          networkInboxAdapter: FixtureNetworkInboxAdapter(
            items: [
              NetworkInboxItem(
                kind: ChatListEntryKind.networkChannel,
                networkId: 'net1',
                id: 'c1',
                title: 'general',
                lastActivity: DateTime.utc(2026, 8, 1, 12),
              ),
            ],
          ),
        );

        if (surface.width >= 700) {
          expect(
            find.byKey(const ValueKey('chatRow-local:local-session')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('chatRow-local:empty-placeholder')),
            findsNothing,
          );
        }

        await tester.tap(find.text('general'));
        for (var index = 0; index < 6; index++) {
          await tester.pump(const Duration(milliseconds: 20));
        }

        expect(controller.networkId, 'net1');
        expect(controller.channelId, 'c1');
        expect(find.byKey(const ValueKey('networkChannelRoute')), findsNothing);
        final page = tester.widget<NetworkChatPage>(
          find.byType(NetworkChatPage),
        );
        expect(page.showAppBar, isTrue);
        expect(page.showChannelHeader, isFalse);
        expect(page.projectLabel, 'epam-public');
        final chat = tester.widget<FaChatScreen>(
          find.byKey(const ValueKey('channelChat:c1')),
        );
        expect(chat.showAppBar, isTrue);
        expect(chat.features.copyTranscript, isTrue);
        expect(find.widgetWithText(Dialog, 'Networks'), findsNothing);
        expect(find.byType(JoinSheet), findsNothing);
        final chatContext = tester.element(find.byType(NetworkChatPage));
        if (surface.width >= 700) {
          expect(Navigator.canPop(chatContext), isFalse);
          await tester.tap(
            find.byKey(const ValueKey('chatRow-local:local-session')),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(localSessions.activeId, 'local-session');
          expect(find.byType(NetworkChatPage), findsNothing);
          expect(find.byType(ChatScreen), findsOneWidget);

          await tester.tap(find.text('general'));
          for (var index = 0; index < 6; index++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(find.byType(ChatScreen), findsNothing);
          expect(find.byType(NetworkChatPage), findsOneWidget);

          await tester.tap(
            find.byKey(const ValueKey('faChatHeaderProjectLabel')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('channelDetailsSheet')),
            findsOneWidget,
          );
          expect(find.widgetWithText(Dialog, 'Networks'), findsNothing);
          Navigator.of(
            tester.element(find.byKey(const ValueKey('channelDetailsSheet'))),
          ).pop();
          await tester.pumpAndSettle();
        } else {
          expect(Navigator.canPop(chatContext), isTrue);
          await tester.pageBack();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(NetworkChatPage), findsNothing);
          expect(find.byType(ChatListPanel), findsOneWidget);
        }
        await manager.disconnectAll();
        await tester.pump();
      });
    }

    testWidgets('the networks surface channel tap keeps the surface and '
        'selects the channel row', (tester) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.addNetwork(networkId: 'net1', name: 'epam-public');
      final httpClient = FakeHttpClient()
        ..respond(
          200,
          body:
              '[{"id":"c1","networkId":"net1","name":"general","public":true}]',
        )
        ..respond(200, body: membersBody)
        ..respond(200, body: '{"items":[],"nextCursor":""}');
      final session = buildSession(
        httpClient: httpClient,
        connector: FakeWsConnector(),
        wallet: wallet,
      );
      await session.start();
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: FakeHttpClient(),
        wsConnector: FakeWsConnector(),
      )..sessions['net1'] = session;
      addTearDown(manager.disconnectAll);
      final controller = NetworkModeController.inMemory();
      final inbox = FixtureNetworkInboxAdapter(
        items: [
          NetworkInboxItem(
            kind: ChatListEntryKind.networkChannel,
            networkId: 'net1',
            id: 'c1',
            title: 'general',
            lastActivity: DateTime.utc(2026, 8, 1, 12),
            unreadCount: 2,
          ),
        ],
      );
      await _pumpWideHome(
        tester,
        controller: controller,
        manager: manager,
        networkInboxAdapter: inbox,
      );
      await tester.pump();

      // The rail's Network destination swaps the sidebar to the networks
      // surface; drill into the network (level-1 row), then tap the
      // channel ROW.
      await tester.tap(
        find.byKey(const ValueKey('messengerPrimaryNav-network')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const ValueKey('networkRow-net1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('networkRow-net1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.byKey(const ValueKey('chatNetworkChannel-c1')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('chatNetworkChannel-c1')));
      for (var index = 0; index < 6; index++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(controller.networkId, 'net1');
      expect(controller.channelId, 'c1');
      // The surface STAYS open (Telegram drill-down): the strip + the
      // channels list keep their place and ONLY the content pane swaps to
      // the channel's messages — no All-home swap.
      expect(find.byType(ChatNetworksPanel), findsOneWidget);
      expect(find.byType(ChatListPanel), findsNothing);
      expect(find.byType(NetworkChatPage), findsOneWidget);
      expect(find.byKey(const ValueKey('networksStrip')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('chatNetworkChannel-c1')),
        findsOneWidget,
      );
      // The tapped channel row paints the accent selection tint (the
      // chat-row selection anatomy).
      final tokens = FaDesignTokens.of(
        tester.element(find.byType(ChatNetworksPanel)),
      );
      final rowMaterial = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(const ValueKey('chatNetworkChannel-c1')),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(rowMaterial.color, tokens.accent);
      // The tap also clears the row's unread count (the chat-list row
      // path marks the entry opened; the surface tap is the same open).
      expect(inbox.readCalls.any((call) => call.channelId == 'c1'), isTrue);

      // The back chevrons still own the surface explicitly: channels →
      // strip (the chat stays open), then strip → the chats home, where
      // the channel row is selected.
      await tester.tap(find.byKey(const ValueKey('chatChannelsBack')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(ChatNetworksPanel), findsOneWidget);
      expect(find.byKey(const ValueKey('networksList')), findsOneWidget);
      expect(find.byType(NetworkChatPage), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chatNetworksBack')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(ChatNetworksPanel), findsNothing);
      expect(find.byType(ChatListPanel), findsOneWidget);
      expect(find.byType(NetworkChatPage), findsOneWidget);
      final panel = tester.widget<ChatListPanel>(find.byType(ChatListPanel));
      expect(
        panel.selectedEntryId,
        ChatEntryId.network(
          ChatListEntryKind.networkChannel,
          networkId: 'net1',
          id: 'c1',
        ),
      );
      await manager.disconnectAll();
      await tester.pump();
    });

    testWidgets('a restored selection silently resumes the session', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        password: 'pw1',
      );
      final httpClient = FakeHttpClient()
        ..respond(200, body: joinBodyOk) // resume: join
        ..respond(200, body: channelsBody) // start: channels
        ..respond(200, body: membersBody); // start: members
      final controller = NetworkModeController.inMemory(
        mode: AppMode.network,
        networkId: 'net1',
      );
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: httpClient,
        wsConnector: FakeWsConnector(),
      );
      addTearDown(manager.disconnectAll);

      await _pumpNetworkCenter(
        tester,
        controller: controller,
        manager: manager,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(manager.sessions.containsKey('net1'), isTrue);
      // The session is fully started (channels landed) — closing it now
      // cannot race the WS connect (connect() re-arms _manualClose).
      expect(manager.sessions['net1']!.channels, isNotEmpty);
      expect(find.byType(ChannelRail), findsOneWidget);
      // Close inside the body: the session's WS heartbeat timer must not
      // outlive the test (fake-async invariant).
      await manager.disconnectAll();
    });

    // ── _ensureSession failure arms (gh-1848): NetworkSessionManager is a
    // final class, so the arms run over the REAL manager and its seams —
    // the dry FakeHttpClient queue throws StateError from `send`, a
    // scripted 5xx maps to FaNetworkException (error.message), and
    // ExplodingHttpClient feeds the catch-all arm. The success arm is the
    // "restored selection" test above.
    testWidgets('a failed silent resume surfaces the snack, pane stays '
        'alive', (tester) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        password: 'pw1',
      );
      final controller = NetworkModeController.inMemory(
        mode: AppMode.network,
        networkId: 'net1',
      );
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: FakeHttpClient(), // dry queue -> StateError from send
        wsConnector: FakeWsConnector(),
      );
      addTearDown(manager.disconnectAll);

      await _pumpNetworkCenter(
        tester,
        controller: controller,
        manager: manager,
      );
      await tester.pump(); // post-frame ensure -> StateError -> snack
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.textContaining('unexpected request'), findsOneWidget);
      // The detail pane is still alive and waiting (no crash, no takeover).
      expect(find.byType(NetworkCenterPane), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('a controller change re-runs the silent resume', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        password: 'pw1',
      );
      final controller = NetworkModeController.inMemory(
        mode: AppMode.network,
        networkId: 'net1',
      );
      final httpClient = FakeHttpClient()
        ..respond(500, body: resumeRejectedBody); // every join fails 5xx
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: httpClient,
        wsConnector: FakeWsConnector(),
      );
      addTearDown(manager.disconnectAll);

      await _pumpNetworkCenter(
        tester,
        controller: controller,
        manager: manager,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(
        httpClient.requests.where((r) => r.method == 'POST').length,
        1, // the post-frame initial call
      );
      expect(find.text('resume rejected'), findsOneWidget); // e.message

      controller.notifyListeners();
      await tester.pump();

      expect(
        httpClient.requests.where((r) => r.method == 'POST').length,
        2, // the listener-triggered re-run
      );
    });

    testWidgets('a non-network resume error still lands in the snack', (
      tester,
    ) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        password: 'pw1',
      );
      final controller = NetworkModeController.inMemory(
        mode: AppMode.network,
        networkId: 'net1',
      );
      final manager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: ExplodingHttpClient(),
        wsConnector: FakeWsConnector(),
      );
      addTearDown(manager.disconnectAll);

      await _pumpNetworkCenter(
        tester,
        controller: controller,
        manager: manager,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.textContaining('disk on fire'), findsOneWidget);
      expect(find.byType(NetworkCenterPane), findsOneWidget);
    });
  });
}
