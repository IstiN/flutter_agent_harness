@TestOn('vm')
/// Widget tests for the wide shell's session actions (issue #561): the
/// new-session folder dialog, the persisted-session open degrading on a
/// ghost/transcript-less entry, and the session info dialog contents.
/// Fakes mirror `wide_layout_shell_sidebar_resize_test.dart`.
library;

import 'dart:async';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/apps/widgets_catalog_sheet.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/main.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/activity/activity_surface.dart';
import 'package:fa/ui/apps/messenger_app_panel.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/screens/models_settings_page.dart';
import 'package:fa/ui/widgets/messenger_navigation_controls.dart';
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa/ui/widgets/messenger_nav_rail.dart';
import 'package:fa/ui/widgets/messenger_section_header.dart';
import 'package:fa/ui/widgets/session_search_field.dart';
import 'package:fa/ui/widgets/sidebar_nav_item.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/services/project_mount_env.dart';
import 'package:fa/ui/chats/chat_list_panel.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/chats/local_sessions_panel.dart';
import 'package:fa/ui/chats/networks_list_panel.dart';
import 'package:fa/ui/network/network_chat_page.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa_ui/fa_ui.dart'
    show
        FaChatHost,
        FaDuoControlRail,
        FaIconActionButton,
        FaLogo,
        FaSectionEyebrow,
        ProviderEditorPage,
        ProviderRegistry,
        FaSurface,
        FaVisualDirection,
        buildFaTheme,
        debugFaGlassAlwaysFake,
        pushFaPage;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassIconButton, ProgressiveBlur, ProgressiveBlurDirection;
import 'package:flutter/cupertino.dart' show CupertinoTextField;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'network/fakes.dart';

part 'wide_layout_shell_actions_apps.dart';
part 'wide_layout_shell_actions_rail.dart';
part 'wide_layout_shell_actions_narrow_home.dart';

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

AgentService _fakeService(ExecutionEnv env) {
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
      streamFunction: _singleTextResponse('ok'),
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

/// A live fixture with real conversation content, so the All projection
/// does not classify it as a newly-created empty placeholder.
AgentService _listedService(ExecutionEnv env) => _fakeService(env)
  ..messages.add(FahChatMessage(role: 'user', content: 'Listed conversation'));

final class _CountingLocalChatListSource implements LocalChatListSource {
  int loadCount = 0;

  @override
  Future<List<ChatListEntry>> load() async {
    loadCount++;
    return const [];
  }
}

final class _StaticLocalChatListSource implements LocalChatListSource {
  _StaticLocalChatListSource(this.entries);

  final List<ChatListEntry> entries;

  @override
  Future<List<ChatListEntry>> load() async => entries;
}

Future<NetworkSessionManager> _narrowNetworkManager() async {
  final wallet = await KeyWallet.load(MemoryWalletBackend());
  await wallet.createIfMissing(displayName: 'Me');
  await wallet.addNetwork(networkId: 'net1', name: 'fa-team', password: 'pw-1');
  final manager = NetworkSessionManager(
    baseUrl: testBase,
    wallet: wallet,
    httpClient: FakeHttpClient(),
    wsConnector: FakeWsConnector(),
  );
  final session = buildSession(
    httpClient: FakeHttpClient()
      ..respond(
        200,
        body:
            '[{"id":"c1","networkId":"net1","name":"general",'
            '"public":false}]',
      )
      ..respond(200, body: membersBody)
      ..respond(200, body: '{"items":[],"nextCursor":""}'),
    connector: FakeWsConnector(),
    wallet: wallet,
  );
  await session.start();
  manager.sessions['net1'] = session;
  manager.notifyListeners();
  addTearDown(manager.disconnectAll);
  return manager;
}

Future<void> pumpShell(
  WidgetTester tester, {
  required FlutterSessionManager manager,
  SessionNamesStore? sessionNamesStore,
  ProviderRegistry? registry,
  LocalChatListSource Function()? localChatAdapterFactory,
  Size size = const Size(1280, 800),
  Locale locale = const Locale('en'),
  FaVisualDirection direction = FaVisualDirection.glass,
  Brightness brightness = Brightness.dark,
  bool reducedMotion = false,
  NetworkModeController? networkMode,
  NetworkSessionManager? networkSessions,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFaTheme(direction: direction, brightness: brightness),
      builder: reducedMotion
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
          : null,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) {
          if (localChatAdapterFactory == null &&
              networkMode == null &&
              networkSessions == null) {
            return faHomeScreen(
              context: context,
              manager: manager,
              registry: registry,
              sessionNamesStore: sessionNamesStore,
            );
          }
          return WideLayoutShell(
            manager: manager,
            registry: registry,
            sessionNamesStore: sessionNamesStore,
            localChatAdapterFactory: localChatAdapterFactory,
            networkMode: networkMode,
            networkSessions: networkSessions,
          );
        },
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('ru');
  });
  setUp(() => debugFaGlassAlwaysFake = true);
  tearDown(() => debugFaGlassAlwaysFake = false);

  testWidgets('the new-session action asks for the folder first and '
      'aborts cleanly on dismiss', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', _fakeService(env));

    await pumpShell(tester, manager: manager);
    await tester.tap(find.byKey(const ValueKey('messengerNewButton')));
    await tester.pumpAndSettle();

    // The folder question names the current (Personal) destination.
    expect(find.byType(SimpleDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SimpleDialog),
        matching: find.text('New session — folder'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(SimpleDialog),
        matching: find.text('Personal'),
      ),
      findsOneWidget,
    );

    // Dismissing the barrier (no choice) must not create a session.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
    expect(manager.sessions.length, 1);
  });

  testWidgets('tapping a persisted sidebar row clones and opens its '
      'session', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', _fakeService(env));
    // A header-only session on disk: the sidebar's persisted tail.
    await JsonlSessionRepo(
      fs: env,
      sessionsRoot: '/sessions',
    ).create(const JsonlSessionCreateOptions(cwd: '/tmp', id: 'ghost'));

    await pumpShell(
      tester,
      manager: manager,
      sessionNamesStore: SessionNamesStore.inMemory({'ghost': 'Ghost chat'}),
    );
    await tester.tap(find.text('Ghost chat'));
    await tester.pumpAndSettle();
    // Wind the clock so short deferrals fire before the assertions.
    await tester.pump(const Duration(seconds: 10));

    // The ghost opened as a real (cloned) session.
    expect(manager.sessions.map((s) => s.id), contains('ghost'));

    // Close the opened session: releases the drive-lease heartbeat.
    // (The live session stays — an empty manager would trip the chat
    // screen's fallback.)
    final ghostSession = manager.sessions.firstWhere((s) => s.id == 'ghost');
    await manager.closeSession('ghost');
    // Settle while the tree is still mounted: the session switch asks
    // the chat for a scroll-to-tail post-frame callback.
    await tester.pumpAndSettle();
    // AgentService.dispose cancels its file-watch timers; only the
    // ghost's — the live one is still on screen.
    ghostSession.service.dispose();
    await tester.pumpAndSettle();
  });

  testWidgets('local session click responds immediately while open is gated', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final gate = Completer<void>();
    FlutterSessionManager.debugOpenSessionGate = (_) => gate.future;
    addTearDown(() => FlutterSessionManager.debugOpenSessionGate = null);
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', _fakeService(env));
    await JsonlSessionRepo(
      fs: env,
      sessionsRoot: '/sessions',
    ).create(const JsonlSessionCreateOptions(cwd: '/tmp', id: 'ghost'));

    await pumpShell(
      tester,
      manager: manager,
      sessionNamesStore: SessionNamesStore.inMemory({'ghost': 'Ghost chat'}),
    );
    await tester.tap(find.text('Ghost chat'));
    await tester.pump(const Duration(milliseconds: 30));

    expect(
      find.byKey(const ValueKey('sessionOpeningIndicator')),
      findsOneWidget,
    );
    expect(manager.active?.id, 'fake-session');

    gate.complete();
    await tester.pumpAndSettle();
    expect(manager.active?.id, 'ghost');
    expect(find.byKey(const ValueKey('sessionOpeningIndicator')), findsNothing);

    final opened = manager.sessions.firstWhere((s) => s.id == 'ghost');
    await manager.closeSession('ghost');
    await tester.pumpAndSettle();
    opened.service.dispose();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'local session switch keeps existing transcript visible while open is gated',
    (tester) async {
      final env = MemoryExecutionEnv();
      final gate = Completer<void>();
      FlutterSessionManager.debugOpenSessionGate = (_) => gate.future;
      addTearDown(() => FlutterSessionManager.debugOpenSessionGate = null);
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('fake-session', _listedService(env));
      await JsonlSessionRepo(
        fs: env,
        sessionsRoot: '/sessions',
      ).create(const JsonlSessionCreateOptions(cwd: '/tmp', id: 'ghost'));

      await pumpShell(
        tester,
        manager: manager,
        sessionNamesStore: SessionNamesStore.inMemory({'ghost': 'Ghost chat'}),
      );
      expect(find.text('Listed conversation'), findsWidgets);
      await tester.tap(find.text('Ghost chat'));
      await tester.pump(const Duration(milliseconds: 30));

      expect(manager.active?.id, 'fake-session');
      expect(
        find.byKey(const ValueKey('sessionOpeningIndicator')),
        findsNothing,
      );
      expect(find.text('Listed conversation'), findsWidgets);

      gate.complete();
      await tester.pumpAndSettle();
      final opened = manager.sessions.firstWhere((s) => s.id == 'ghost');
      await manager.closeSession('ghost');
      await tester.pumpAndSettle();
      opened.service.dispose();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('Duo provider details glass dialog opens and closes without '
      'an inherited-element lifecycle failure', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', _fakeService(env));
    tester.view.padding = const FakeViewPadding(right: 84);
    debugFaGlassAlwaysFake = false;

    await pumpShell(
      tester,
      manager: manager,
      size: const Size(1230, 880),
      brightness: Brightness.light,
    );
    unawaited(
      pushFaPage<void>(
        tester.element(find.byType(ChatScreen)),
        const ProviderEditorPage(title: 'Edit provider'),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(ProviderEditorPage), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    Navigator.of(tester.element(find.byType(ProviderEditorPage))).pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(ProviderEditorPage), findsNothing);
  });

  testWidgets('Duo session info dialog opens and closes without an '
      'inherited-element lifecycle failure', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', _fakeService(env));
    tester.view.padding = const FakeViewPadding(right: 84);
    debugFaGlassAlwaysFake = false;

    await pumpShell(
      tester,
      manager: manager,
      size: const Size(1230, 880),
      brightness: Brightness.light,
    );
    await tester.tap(find.byKey(const ValueKey('faChatHeaderTitlePill')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Your mailbox'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('the session info dialog shows the folder state, the '
      'mailbox note and closes', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', _fakeService(env));

    await pumpShell(tester, manager: manager);
    // The centered glass title pill owns the project/session-info action.
    await tester.tap(find.byKey(const ValueKey('faChatHeaderTitlePill')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Session'),
      ),
      findsOneWidget,
    );
    // No folder on the fresh session → the honest Personal note, and the
    // restrict toggle (a folder-only control) stays hidden.
    expect(find.text('Personal (no folder mounted)'), findsOneWidget);
    expect(find.text('Restrict tools to this folder'), findsNothing);
    expect(find.text('Your mailbox'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  wideShellAppsActivityTests();

  wideShellRailHeaderTests();

  testWidgets('the flat chat list survives section switches and collapse', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    ChatListEntry folderEntry(String id) => ChatListEntry(
      id: ChatEntryId.local(id),
      kind: ChatListEntryKind.localAgent,
      title: id,
      preview: 'Preview',
      createdAt: DateTime.utc(2025),
      lastActivity: DateTime.utc(2026),
      folderName: 'project',
      folderPath: '/work/project',
      localMessageCount: 1,
    );
    await pumpShell(
      tester,
      manager: manager,
      localChatAdapterFactory: () => _StaticLocalChatListSource([
        folderEntry('Agent one'),
        folderEntry('Agent two'),
      ]),
    );
    await tester.pumpAndSettle();

    Rect rect(String key) => tester.getRect(find.byKey(ValueKey(key)));
    final searchBefore = rect('messengerSearchField');
    final railBefore = rect('messengerNavRail');
    // The flat home: same-cwd agents are plain rows — no folder
    // destination, no drill-down chrome.
    expect(
      find.byKey(const ValueKey('chatFolder-folder::/work/project')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('chatCurrentFolder')), findsNothing);
    expect(find.text('Agent one'), findsOneWidget);
    expect(rect('messengerSearchField'), searchBefore);
    expect(rect('messengerNavRail'), railBefore);

    for (final section in const ['activity', 'apps']) {
      await tester.tap(find.byKey(ValueKey('messengerPrimaryNav-$section')));
      await tester.pumpAndSettle();
    }
    // Filters are the Chats home: tapping one returns from Apps.
    await tester.tap(find.byKey(const ValueKey('chatFilter-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatCurrentFolder')), findsNothing);
    expect(find.text('Agent one'), findsOneWidget);
    expect(find.text('Agent two'), findsOneWidget);

    final toggle = find.byKey(const ValueKey('wideShellSidebarToggle'));
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.text('Agent one'), findsNothing, reason: 'collapsed sidebar');
    expect(
      find.byKey(const ValueKey('collapsedChatAvatarList')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('collapsedChatAvatar-local:Agent one')),
      findsOneWidget,
    );
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.text('Agent one'), findsOneWidget);
    expect(find.text('Agent two'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'collapsed Activity and Apps stay useful and the brand never jumps',
    (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      final entry = ChatListEntry(
        id: ChatEntryId.local('design-session'),
        kind: ChatListEntryKind.localAgent,
        title: 'design-session',
        createdAt: DateTime.utc(2025),
        lastActivity: DateTime.utc(2026),
        folderPath: '/work/fa',
        localMessageCount: 1,
      );
      await pumpShell(
        tester,
        manager: manager,
        localChatAdapterFactory: () => _StaticLocalChatListSource([entry]),
      );
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('wideShellSidebarToggle'));
      final brand = find.byKey(const ValueKey('wideShellFaBrand'));

      await tester.tap(
        find.byKey(const ValueKey('messengerPrimaryNav-activity')),
      );
      await tester.pumpAndSettle();
      final expandedBrandY = tester.getRect(brand).center.dy;
      expect(
        find.descendant(
          of: find.byType(MessengerSectionHeader),
          matching: find.text('Fa'),
        ),
        findsNothing,
        reason: 'the mark already contains Fa; no duplicate wordmark',
      );
      expect(
        tester
            .widget<FaLogo>(
              find.descendant(of: brand, matching: find.byType(FaLogo)),
            )
            .trailingDot,
        isFalse,
      );
      await tester.tap(toggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      final midFlightRail = find.byKey(
        const ValueKey('collapsedChatAvatarRail'),
      );
      expect(midFlightRail, findsOneWidget);
      for (final pointer in tester.widgetList<IgnorePointer>(
        find.ancestor(of: midFlightRail, matching: find.byType(IgnorePointer)),
      )) {
        expect(pointer.ignoring, isFalse);
      }
      await tester.pumpAndSettle();
      expect(tester.getRect(brand).center.dy, closeTo(expandedBrandY, .001));
      expect(
        tester
            .widget<FaLogo>(
              find.descendant(of: brand, matching: find.byType(FaLogo)),
            )
            .trailingDot,
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('collapsedChatAvatar-local:design-session')),
        findsOneWidget,
      );

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
      await tester.pumpAndSettle();
      final appsBrandY = tester.getRect(brand).center.dy;
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('collapsedAppsList')), findsOneWidget);
      expect(find.byKey(const ValueKey('collapsedAppsMyApps')), findsOneWidget);
      expect(find.byKey(const ValueKey('collapsedAppsStore')), findsOneWidget);
      expect(tester.getRect(brand).center.dy, closeTo(appsBrandY, .001));
      await tester.tap(find.byKey(const ValueKey('collapsedAppsStore')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Local drill state resets on a section switch (owner pass)', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    ChatListEntry folderEntry(String id, String cwd) => ChatListEntry(
      id: ChatEntryId.local(id),
      kind: ChatListEntryKind.localAgent,
      title: id,
      preview: 'Preview of $id',
      createdAt: DateTime.utc(2025),
      lastActivity: DateTime.utc(2026),
      folderPath: cwd,
      localMessageCount: 1,
    );
    await pumpShell(
      tester,
      manager: manager,
      localChatAdapterFactory: () => _StaticLocalChatListSource([
        folderEntry('design-session', '/work/fa'),
        folderEntry('docs-session', '/work/mono'),
      ]),
    );
    await tester.pumpAndSettle();

    // Drill into a folder in the Local section.
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-local')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('localFolderRow-/work/fa')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('localSessionList')), findsOneWidget);
    expect(find.byKey(const ValueKey('localFoldersStrip')), findsOneWidget);

    // A section switch (the Channels filter row selects Chats) must drop
    // the shell-owned drill state along with the networks surface.
    await tester.tap(find.byKey(const ValueKey('chatFilter-channels')));
    await tester.pumpAndSettle();
    expect(find.byType(LocalSessionsPanel), findsNothing);

    // Back to Local: the LEVEL-1 folder list again — no strip, no drilled
    // session list.
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-local')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('localFoldersList')), findsOneWidget);
    expect(find.byKey(const ValueKey('localFoldersStrip')), findsNothing);
    expect(find.byKey(const ValueKey('localSessionList')), findsNothing);
    expect(find.text('design-session'), findsNothing);
    expect(find.text('fa'), findsOneWidget, reason: 'the list row name');
  });

  testWidgets('the Local rail row walks folders → sessions → open → back', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    ChatListEntry folderEntry(String id, String cwd) => ChatListEntry(
      id: ChatEntryId.local(id),
      kind: ChatListEntryKind.localAgent,
      title: id,
      preview: 'Preview of $id',
      createdAt: DateTime.utc(2025),
      lastActivity: DateTime.utc(2026),
      folderPath: cwd,
      localMessageCount: 1,
    );
    await pumpShell(
      tester,
      manager: manager,
      localChatAdapterFactory: () => _StaticLocalChatListSource([
        folderEntry('design-session', '/work/fa'),
        folderEntry('docs-session', '/work/mono'),
      ]),
    );
    await tester.pumpAndSettle();

    // Rail → the Local standard folder list (level 1).
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-local')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('localFoldersList')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('localFolderRow-/work/mono')),
      findsOneWidget,
    );

    // Folder → its avatar strip + Telegram-style session list.
    await tester.tap(find.byKey(const ValueKey('localFolderRow-/work/fa')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('localSessionList')), findsOneWidget);
    expect(find.text('design-session'), findsOneWidget);
    expect(find.text('Preview of design-session'), findsOneWidget);

    // Session row → the existing open flow (the live session's chat).
    await tester.tap(find.byKey(const ValueKey('localSession-design-session')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);

    // Back from the drill-down to the folder list; the drill state stays
    // shell-owned.
    await tester.tap(find.byKey(const ValueKey('localFolderBack')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('localFoldersList')), findsOneWidget);
    expect(find.byKey(const ValueKey('localFoldersStrip')), findsNothing);
    expect(
      find.byKey(const ValueKey('localSession-design-session')),
      findsNothing,
    );
  });

  testWidgets(
    'wide macOS chrome shares the top centerline and collapsed identity',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      const labels = ['Chats', 'Activity', 'Apps'];
      final expectedExpanded = <String, Rect>{};
      final expectedCollapsed = <String, Rect>{};

      void expectSameRect(Rect actual, Rect expected, String reason) {
        expect(actual.left, closeTo(expected.left, .001), reason: reason);
        expect(actual.top, closeTo(expected.top, .001), reason: reason);
        expect(actual.right, closeTo(expected.right, .001), reason: reason);
        expect(actual.bottom, closeTo(expected.bottom, .001), reason: reason);
      }

      for (final direction in FaVisualDirection.values) {
        for (final brightness in Brightness.values) {
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          await pumpShell(
            tester,
            manager: manager,
            direction: direction,
            brightness: brightness,
          );
          await tester.pump(const Duration(milliseconds: 100));
          for (var section = 0; section < labels.length; section++) {
            final label = labels[section];
            if (section > 0) {
              await tester.tap(
                find.byKey(
                  ValueKey('messengerPrimaryNav-${label.toLowerCase()}'),
                ),
              );
              await tester.pumpAndSettle();
            }
            final reason = '$direction $brightness $label';
            expect(
              find.byKey(const ValueKey('macosSidebarTitlebar')),
              findsNothing,
            );
            final collapse = tester.getRect(
              find.byKey(const ValueKey('chatSidebarCollapse')),
            );
            final sidebar = tester.getRect(
              find.byKey(const ValueKey('desktopSidebarContainer')),
            );
            // Apps has no sidebar search (owner call) — skip its
            // centerline measurement, keep the toggle/brand checks.
            if (label != 'Apps') {
              final search = tester.getRect(
                find.byKey(const ValueKey('messengerSearchField')),
              );
              expect(
                search.center.dy,
                closeTo(collapse.center.dy, .001),
                reason: reason,
              );
            }
            final expandedCenter = tester.getRect(
              find.byKey(const ValueKey('glassCenterPanel')),
            );
            expect(collapse.center.dy, closeTo(35, .001), reason: reason);
            // The panel's 8pt gutter contract on BOTH sides: 8pt card
            // margin + 8pt gutter between the toggle's right edge and the
            // panel's right edge (owner call: the open panel's toggle must
            // not hug the panel edge).
            expect(collapse.right, closeTo(sidebar.right - 16, .001));
            final brand = find.byKey(const ValueKey('wideShellFaBrand'));
            final expandedLogo = tester.widget<FaLogo>(
              find.descendant(of: brand, matching: find.byType(FaLogo)),
            );
            expect(expandedLogo.size, 30);
            expect(tester.getSize(brand), const Size(30, 30));

            final previousExpanded = expectedExpanded[label];
            if (previousExpanded == null) {
              expectedExpanded[label] = collapse;
            } else {
              expectSameRect(collapse, previousExpanded, reason);
            }

            await tester.tap(find.byKey(const ValueKey('chatSidebarCollapse')));
            await tester.pumpAndSettle();
            final expand = tester.getRect(
              find.byKey(const ValueKey('chatSidebarExpand')),
            );
            final collapsedSidebar = tester.getRect(
              find.byKey(const ValueKey('desktopSidebarContainer')),
            );
            expect(collapsedSidebar.width, 96, reason: reason);
            final collapsedCenter = tester.getRect(
              find.byKey(const ValueKey('glassCenterPanel')),
            );
            expect(
              collapsedCenter.left,
              collapsedSidebar.right,
              reason: reason,
            );
            expect(
              collapsedCenter.width - expandedCenter.width,
              closeTo(sidebar.width - collapsedSidebar.width, .001),
              reason: '$reason center must not reserve a toggle column',
            );
            expect(
              collapsedCenter.contains(expand.center),
              isTrue,
              reason: '$reason floating toggle=$expand center=$collapsedCenter',
            );
            // The floating toggle's pressable contract: the kit's
            // GlassIconButton in the glass direction (FaIconActionButton
            // delegates there), the flat Material IconButton everywhere else
            // (real glass only in the glass direction).
            final floatingFinder = find.byKey(
              const ValueKey('chatSidebarExpand'),
            );
            if (direction == FaVisualDirection.glass) {
              expect(
                tester.widget<GlassIconButton>(floatingFinder).onPressed,
                isNotNull,
                reason: reason,
              );
            } else {
              expect(
                tester.widget<IconButton>(floatingFinder).onPressed,
                isNotNull,
                reason: reason,
              );
            }
            // ONE style: the toggle renders the shared circular chrome
            // (FaIconActionButton — token fill + hairline) in both states,
            // floating or docked; no per-state glass variant.
            final toggleChrome = tester.widget<FaIconActionButton>(
              find.ancestor(
                of: find.byKey(const ValueKey('chatSidebarExpand')),
                matching: find.byType(FaIconActionButton),
              ),
            );
            expect(
              toggleChrome.diameter,
              FaIconActionButton.defaultDiameter,
              reason: reason,
            );
            expect(expand.center.dy, closeTo(collapse.center.dy, .001));
            expect(
              expand.left,
              closeTo(collapsedSidebar.right + 8, .001),
              reason: reason,
            );
            // Reserve the native traffic-light span even in the compact rail.
            expect(expand.left, greaterThanOrEqualTo(72), reason: reason);
            final previousCollapsed = expectedCollapsed[label];
            if (previousCollapsed == null) {
              expectedCollapsed[label] = expand;
            } else {
              expectSameRect(expand, previousCollapsed, reason);
            }

            final collapsedLogo = tester.widget<FaLogo>(
              find.descendant(of: brand, matching: find.byType(FaLogo)),
            );
            expect(collapsedLogo.size, expandedLogo.size, reason: reason);
            expect(
              collapsedLogo.semanticLabel,
              expandedLogo.semanticLabel,
              reason: reason,
            );
            expect(tester.getSize(brand), const Size(30, 30), reason: reason);
            expect(
              find.descendant(of: brand, matching: find.text('Fa')),
              findsNothing,
            );
            final axis = tester.getCenter(brand).dx;
            // The rail owns navigation now: its rows share ONE axis (the
            // rail's center) while the collapsed brand keeps the sidebar's.
            final railRect = tester.getRect(
              find.byKey(const ValueKey('messengerNavRail')),
            );
            final railAxis = railRect.center.dx;
            expect(railAxis, isNot(closeTo(axis, 1)), reason: reason);
            for (final navKey in const [
              'chatFilter-all',
              'messengerPrimaryNav-local',
              'messengerPrimaryNav-activity',
              'messengerPrimaryNav-apps',
            ]) {
              expect(
                tester.getCenter(find.byKey(ValueKey(navKey))).dx,
                closeTo(railAxis, .001),
                reason: '$reason $navKey axis',
              );
            }
            if (label == 'Chats') {
              expect(
                tester
                    .getCenter(
                      find.byKey(const ValueKey('collapsedChatAvatarRail')),
                    )
                    .dx,
                closeTo(axis, .001),
                reason: '$reason avatar-rail axis',
              );
              expect(
                tester.getRect(find.byType(ChatScreen)).left,
                closeTo(collapsedCenter.left, .001),
                reason: '$reason content extends beneath floating toggle',
              );
            }

            await tester.tap(find.byKey(const ValueKey('chatSidebarExpand')));
            await tester.pumpAndSettle();
          }
        }
      }
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('collapse and expand share one smooth boundary animation', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    await pumpShell(tester, manager: manager);
    await tester.pump(const Duration(milliseconds: 100));

    final sidebarFinder = find.byKey(const ValueKey('desktopSidebarContainer'));
    final toggleFinder = find.byKey(const ValueKey('wideShellSidebarToggle'));
    final centerFinder = find.byKey(const ValueKey('glassCenterPanel'));
    (Rect, Rect, Rect) sample() => (
      tester.getRect(sidebarFinder),
      tester.getRect(toggleFinder),
      tester.getRect(centerFinder),
    );
    void expectSingleActionTree() {
      expect(toggleFinder, findsOneWidget);
      expect(find.byKey(const ValueKey('messengerProfile')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('messengerNewButton')).evaluate().length,
        lessThanOrEqualTo(1),
      );
      expect(tester.takeException(), isNull);
    }

    final expanded = sample();
    expect(expanded.$1.width, 260);
    await tester.pump(const Duration(milliseconds: 100));
    expect(sample().$1, expanded.$1, reason: 'no initial/idle animation');

    final collapsing = <(Rect, Rect, Rect)>[];
    await tester.tap(find.byKey(const ValueKey('chatSidebarCollapse')));
    await tester.pump();
    for (var frame = 0; frame <= 4; frame++) {
      collapsing.add(sample());
      expectSingleActionTree();
      expect(collapsing.last.$2.left, greaterThanOrEqualTo(72));
      expect(collapsing.last.$3.left, collapsing.last.$1.right);
      if (frame < 4) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
    for (var index = 1; index < collapsing.length; index++) {
      final previous = collapsing[index - 1];
      final current = collapsing[index];
      expect(current.$1.width, lessThanOrEqualTo(previous.$1.width + .001));
      expect(current.$2.left, lessThanOrEqualTo(previous.$2.left + .001));
      expect(current.$3.left, lessThanOrEqualTo(previous.$3.left + .001));
      expect(current.$3.width, greaterThanOrEqualTo(previous.$3.width - .001));
    }
    final collapsed = collapsing.last;
    expect(collapsed.$1.width, 96);
    expect(collapsed.$2.left, closeTo(collapsed.$1.right + 8, .001));
    expect(collapsed.$3.contains(collapsed.$2.center), isTrue);
    expect(
      tester.getRect(find.byType(ChatScreen)).left,
      closeTo(collapsed.$3.left, .001),
      reason: 'content continues underneath the floating toggle',
    );

    final expanding = <(Rect, Rect, Rect)>[];
    await tester.tap(find.byKey(const ValueKey('chatSidebarExpand')));
    await tester.pump();
    for (var frame = 0; frame <= 4; frame++) {
      expanding.add(sample());
      expectSingleActionTree();
      expect(expanding.last.$3.left, expanding.last.$1.right);
      if (frame < 4) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
    for (var index = 1; index < expanding.length; index++) {
      final previous = expanding[index - 1];
      final current = expanding[index];
      expect(current.$1.width, greaterThanOrEqualTo(previous.$1.width - .001));
      expect(current.$2.left, greaterThanOrEqualTo(previous.$2.left - .001));
      expect(current.$3.left, greaterThanOrEqualTo(previous.$3.left - .001));
      expect(current.$3.width, lessThanOrEqualTo(previous.$3.width + .001));
    }
    final restored = expanding.last;
    expect(restored.$1.width, 260);
    // The panel's 8pt gutter contract on BOTH sides (8pt card margin +
    // 8pt gutter).
    expect(restored.$2.right, closeTo(restored.$1.right - 16, .001));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'sidebar toggle glass states follow the icon, not the animation',
    (tester) async {
      // Owner rule (FaIconActionButton): on-surface = flat, floating = glass.
      // The docked collapse toggle (panel OPEN, sitting on the glass panel)
      // is FLAT; the floating expand toggle (panel collapsed, no panel under
      // it) carries the glass underlay.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      await pumpShell(tester, manager: manager);
      await tester.pumpAndSettle();

      bool toggleGlass() => tester
          .widget<FaIconActionButton>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('wideShellSidebarToggle')),
                  matching: find.byType(FaIconActionButton),
                )
                .first,
          )
          .glass;

      // Panel OPEN: the collapse icon sits ON the panel — flat, no underlay.
      expect(toggleGlass(), isFalse, reason: 'docked collapse icon is flat');
      expect(find.byKey(const ValueKey('chatSidebarCollapse')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chatSidebarCollapse')));
      await tester.pumpAndSettle();

      // Panel CLOSED: the expand icon floats over the center surface — glass.
      expect(toggleGlass(), isTrue, reason: 'floating expand icon is glass');
      expect(find.byKey(const ValueKey('chatSidebarExpand')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chatSidebarExpand')));
      await tester.pumpAndSettle();

      // Back open: flat again (the flag follows the state, never lags the
      // collapse animation).
      expect(toggleGlass(), isFalse, reason: 're-docked toggle is flat again');
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('compact composer floats 8 above the window in every theme', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));

    for (final direction in FaVisualDirection.values) {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await pumpShell(
          tester,
          manager: manager,
          direction: direction,
          brightness: brightness,
        );
        await tester.pump(const Duration(milliseconds: 100));
        final reason = '$direction $brightness';
        final panel = tester.getRect(
          find.byKey(const ValueKey('glassCenterPanel')),
        );
        final composer = tester.getRect(
          find.byKey(const ValueKey('faChatFloatingComposer')),
        );
        final send = tester.getRect(
          find.byKey(const ValueKey('faChatComposerSendButton')),
        );
        final row = tester.getRect(
          find.byKey(const ValueKey('faChatComposerFieldRow')),
        );
        final fade = tester.getRect(
          find.byKey(const ValueKey('faChatBottomEnvironmentFade')),
        );
        final attach = tester.getRect(
          find.byKey(const ValueKey('faChatComposerAttachButton')),
        );
        expect(composer.bottom, 792, reason: reason);
        expect(composer.bottom, panel.bottom - 8, reason: reason);
        expect(composer.right, panel.right - 8, reason: reason);
        expect(composer.left, panel.left + 8, reason: reason);
        expect(composer.height, 40, reason: reason);
        expect(row.height, 40, reason: reason);
        expect(send.size, const Size(40, 34), reason: reason);
        expect(composer.right - send.right, 4, reason: 'trailing optical air');
        expect(attach.size, const Size.square(36), reason: reason);
        expect(composer.contains(send.center), isTrue, reason: reason);
        expect(composer.contains(attach.center), isTrue, reason: reason);
        expect(fade.bottom, panel.bottom, reason: reason);
        expect(fade.top, lessThan(composer.top), reason: reason);
        expect(fade.bottom, greaterThan(composer.bottom), reason: reason);
      }
    }
  });

  testWidgets('glass stays inside the sidebar panel one-pixel frame', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    await pumpShell(tester, manager: manager);
    await tester.pumpAndSettle();

    final frameFinder = find.byKey(const ValueKey('glassSidebarPanel'));
    final frame = tester.widget<DecoratedBox>(frameFinder);
    expect((frame.decoration as BoxDecoration).border, isA<Border>());
    expect(
      tester
          .widget<Padding>(
            find
                .descendant(of: frameFinder, matching: find.byType(Padding))
                .first,
          )
          .padding,
      const EdgeInsets.all(1),
    );
    final glass = find
        .descendant(of: frameFinder, matching: find.byType(FaSurface))
        .first;
    expect(tester.getRect(glass), tester.getRect(frameFinder).deflate(1));
  });

  testWidgets('All Local and Networks share one compact glass header', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    await pumpShell(tester, manager: manager);
    await tester.pumpAndSettle();

    Rect? contentRow;
    for (final destination in const ['all', 'local', 'network']) {
      if (destination != 'all') {
        await tester.tap(
          find.byKey(ValueKey('messengerPrimaryNav-$destination')),
        );
        await tester.pumpAndSettle();
      }
      final reason = destination;
      final header = find.byType(MessengerSectionHeader);
      expect(header, findsOneWidget, reason: reason);
      final headerRect = tester.getRect(header);
      expect(headerRect.height, 52, reason: reason);
      final glass = tester.getRect(
        find.byKey(const ValueKey('glassSidebarPanel')),
      );
      expect(glass.contains(headerRect.topLeft), isTrue, reason: reason);
      final clip = find
          .ancestor(of: header, matching: find.byType(ClipRRect))
          .first;
      expect(
        tester.getRect(clip),
        glass.deflate(1),
        reason: '$reason header=$headerRect glass=$glass',
      );
      expect(
        headerRect.bottom,
        lessThanOrEqualTo(glass.bottom),
        reason: reason,
      );
      final toggle = tester.getRect(
        find.byKey(const ValueKey('chatSidebarCollapse')),
      );
      expect(glass.contains(toggle.center), isTrue, reason: reason);
      expect(find.byKey(const ValueKey('macosSidebarTitlebar')), findsNothing);
      final primary = tester.getRect(
        find.byKey(
          ValueKey(switch (destination) {
            'all' => 'messengerSearchField',
            'local' => 'localNewButton',
            _ => 'chatNetworksManage',
          }),
        ),
      );
      expect(
        toggle.center.dy,
        closeTo(primary.center.dy, .001),
        reason: reason,
      );
      expect(primary.center.dy, closeTo(35, .001), reason: reason);
      contentRow ??= Rect.fromCenter(
        center: Offset(0, primary.center.dy),
        width: 1,
        height: primary.height,
      );
      expect(primary.center.dy, closeTo(contentRow.center.dy, .001));
      final panel = destination == 'all'
          ? find.byType(ChatListPanel)
          : destination == 'local'
          ? find.byType(LocalSessionsPanel)
          : find.byType(ChatNetworksPanel);
      final surface = tester.widget<ColoredBox>(
        find.descendant(of: panel, matching: find.byType(ColoredBox)).first,
      );
      expect(surface.color, Colors.transparent, reason: reason);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('every messenger destination freezes the approved glass header', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    await pumpShell(tester, manager: manager);
    await tester.pumpAndSettle();

    for (final destination in const [
      'all',
      'local',
      'network',
      'channels',
      'activity',
      'apps',
    ]) {
      if (destination != 'all') {
        await tester.tap(
          find.byKey(
            ValueKey(
              destination == 'channels'
                  ? 'chatFilter-channels'
                  : 'messengerPrimaryNav-$destination',
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      final header = find.byType(MessengerSectionHeader);
      expect(header, findsOneWidget, reason: destination);
      expect(tester.getRect(header).height, 52, reason: destination);
      final blurFinder = destination == 'apps'
          ? find.byKey(const ValueKey('appsChromeUnderlay'))
          : find.descendant(
              of: find.byType(MessengerGlassUnderlay),
              matching: find.byType(ProgressiveBlur),
            );
      expect(blurFinder, findsOneWidget, reason: destination);
      final underlay = find.ancestor(
        of: blurFinder,
        matching: find.byType(MessengerGlassUnderlay),
      );
      expect(underlay, findsOneWidget, reason: destination);
      expect(
        find.descendant(
          of: underlay,
          matching: find.byKey(const ValueKey('messengerRealGlass')),
        ),
        findsNothing,
        reason: '$destination must fade without a bounded glass rectangle',
      );
      final blur = tester.widget<ProgressiveBlur>(blurFinder);
      expect(blur.maxSigma, 8, reason: destination);
      expect(blur.falloff, 3.0, reason: destination);
      expect(
        blur.direction,
        ProgressiveBlurDirection.topToBottom,
        reason: destination,
      );
      final clip = tester.widget<ClipRRect>(
        find.descendant(of: underlay, matching: find.byType(ClipRRect)),
      );
      expect(
        clip.borderRadius,
        const BorderRadius.only(
          topLeft: Radius.circular(14),
          topRight: Radius.circular(14),
        ),
        reason: destination,
      );
      final stackFinder = find
          .ancestor(of: underlay, matching: find.byType(Stack))
          .first;
      final stack = tester.widget<Stack>(stackFinder);
      expect(stack.clipBehavior, Clip.hardEdge, reason: destination);

      final panelRect = tester.getRect(stackFinder);
      final glassRect = tester.getRect(blurFinder);
      expect(glassRect.top, closeTo(panelRect.top, .001), reason: destination);
      expect(
        glassRect.left,
        closeTo(panelRect.left + 2, .001),
        reason: destination,
      );
      expect(
        glassRect.right,
        closeTo(panelRect.right - 3, .001),
        reason: destination,
      );
      expect(
        glassRect.height,
        destination == 'apps' ? 108 : 58,
        reason: destination,
      );
      expect(
        find.byKey(const ValueKey('chatListChromeFade')),
        findsNothing,
        reason: destination,
      );
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('compact search geometry is shared and Apps uses floating chrome', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));

    for (final direction in FaVisualDirection.values) {
      for (final brightness in Brightness.values) {
        await pumpShell(
          tester,
          manager: manager,
          direction: direction,
          brightness: brightness,
          size: const Size(390, 844),
        );
        Rect? expectedSearch;
        Color? expectedFill;
        for (final label in ['Chats', 'Activity', 'Local']) {
          if (label != 'Chats') {
            await tester.tap(
              find.byKey(
                ValueKey('messengerPrimaryNav-${label.toLowerCase()}'),
              ),
            );
            await tester.pumpAndSettle();
          }
          final finder = find.byKey(const ValueKey('messengerSearchField'));
          final reveal = find.byKey(const ValueKey('messengerSearchReveal'));
          expect(finder, findsNothing, reason: '$label starts collapsed');
          expect(reveal, findsOneWidget);
          await tester.tap(reveal);
          await tester.pumpAndSettle();
          expect(finder, findsOneWidget);
          expect(
            find.byKey(const ValueKey('messengerSearchClose')),
            findsOneWidget,
            reason: '$direction/$brightness/$label',
          );
          final rect = tester.getRect(finder);
          // Removing the compact gear must give its width to Search rather
          // than leaving a blank trailing action slot.
          expect(rect.right, 380, reason: '$direction/$brightness/$label');
          expect(
            find.byKey(const ValueKey('narrowSettingsButton')),
            findsNothing,
          );
          final field = tester.widget<CupertinoTextField>(
            find.descendant(
              of: finder,
              matching: find.byType(CupertinoTextField),
            ),
          );
          expect(field.focusNode?.hasFocus, isTrue, reason: '$label reveal');
          if (expectedSearch == null) {
            expectedSearch = rect;
            expectedFill = field.decoration?.color;
          } else {
            expect(
              rect,
              expectedSearch,
              reason:
                  '$direction/$brightness/$label moved the compact search field',
            );
            expect(field.decoration?.color, expectedFill);
          }
          await tester.enterText(finder, 'active query');
          await tester.pump(const Duration(milliseconds: 200));
          field.focusNode?.unfocus();
          await tester.pump();
          expect(finder, findsOneWidget, reason: '$label active query');
          await tester.tap(find.byKey(const ValueKey('messengerSearchClose')));
          await tester.pumpAndSettle();
          expect(finder, findsNothing, reason: '$label close');
          expect(reveal, findsOneWidget, reason: '$label close');
          expect(field.focusNode?.hasFocus, isFalse, reason: '$label close');
        }
        await tester.tap(
          find.byKey(const ValueKey('messengerPrimaryNav-apps')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('messengerSearchField')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('appsSearchField')), findsNothing);
        expect(
          find.byKey(const ValueKey('appsNarrowSearchReveal')),
          findsOneWidget,
        );
        final header = find.byKey(const ValueKey('appsOverviewHeader'));
        final pill = find.descendant(
          of: header,
          matching: find.byKey(const ValueKey('messengerPageTitlePill')),
        );
        final surface = tester.widget<FaSurface>(pill);
        expect(surface.glass, isTrue);
        expect(surface.borderRadius, BorderRadius.circular(14));
        expect(tester.getSize(pill).height, 40);
        expect(tester.getSize(pill).width, lessThanOrEqualTo(320));
        expect(find.byKey(const ValueKey('appsBackButton')), findsNothing);
        expect(find.byKey(const ValueKey('messengerPageIcon')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('narrowSettingsButton')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('narrowShellNavigation')),
            matching: find.byKey(
              const ValueKey('messengerPrimaryNav-settings'),
            ),
          ),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    }
  });

  testWidgets('compact Networks root search reveals and preserves a query', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    await pumpShell(tester, manager: manager, size: const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-network')));
    await tester.pumpAndSettle();

    final finder = find.byKey(const ValueKey('messengerSearchField'));
    final reveal = find.byKey(const ValueKey('messengerSearchReveal'));
    expect(finder, findsNothing);
    expect(reveal, findsOneWidget);
    await tester.tap(reveal);
    await tester.pumpAndSettle();
    expect(finder, findsOneWidget);
    final field = tester.widget<CupertinoTextField>(
      find.descendant(of: finder, matching: find.byType(CupertinoTextField)),
    );
    expect(field.focusNode?.hasFocus, isTrue);
    await tester.enterText(finder, 'active network');
    await tester.pump(const Duration(milliseconds: 200));
    field.focusNode?.unfocus();
    await tester.pump();
    expect(finder, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('messengerSearchClose')));
    await tester.pumpAndSettle();
    expect(finder, findsNothing);
    expect(reveal, findsOneWidget);
  });

  testWidgets('wide shell Apps omits Back to Chats', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    await pumpShell(tester, manager: manager);
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();

    expect(find.byType(AppLauncherScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('appsBackButton')), findsNothing);
    // The directory rail, not a duplicate back button, owns root navigation.
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-local')));
    await tester.pumpAndSettle();
    expect(find.byType(AppLauncherScreen), findsNothing);
    expect(find.byKey(const ValueKey('messengerSearchField')), findsOneWidget);
  });

  testWidgets('docked Files and chat actions share the top centerline', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    await pumpShell(tester, manager: manager);
    await tester.pumpAndSettle();

    // Open the chat's docked Files panel through the header folder icon.
    await tester.tap(find.byTooltip('Open files'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('faChatFilesPanel')), findsOneWidget);
    expect(find.byKey(const ValueKey('filesAppClose')), findsOneWidget);

    // ONE top centerline across all three panes. Nothing except the narrow
    // compact route reserves a second row below the macOS titlebar.
    final toggle = tester.getRect(
      find.byKey(const ValueKey('chatSidebarCollapse')),
    );
    final filesX = tester.getRect(find.byKey(const ValueKey('filesAppClose')));
    final copy = tester.getRect(find.byTooltip('Copy session'));
    final trajectory = tester.getRect(find.byIcon(Icons.timeline));
    for (final rect in [toggle, filesX, copy, trajectory]) {
      expect(rect.center.dy, closeTo(35, .5), reason: 'off-center $rect');
    }
    expect(filesX.size, const Size.square(36));

    final frameFinder = find.byKey(const ValueKey('filesAppPanelCard'));
    final frame = tester.widget<DecoratedBox>(frameFinder);
    expect((frame.decoration as BoxDecoration).border, isA<Border>());
    expect(
      tester
          .widget<Padding>(
            find
                .descendant(of: frameFinder, matching: find.byType(Padding))
                .first,
          )
          .padding,
      const EdgeInsets.all(1),
    );
    final glass = find
        .descendant(of: frameFinder, matching: find.byType(FaSurface))
        .first;
    expect(tester.getRect(glass), tester.getRect(frameFinder).deflate(1));
    final browserFinder = find.byKey(const ValueKey('fileBrowserPanel'));
    final browser = tester.widget<Material>(browserFinder);
    expect(browser.color, Colors.transparent);

    // Chat Files uses the SAME approved underlay as every sidebar section,
    // extended only by its path bar (52 header + 44 path + 1 divider + 6).
    final filesUnderlay = find.descendant(
      of: browserFinder,
      matching: find.byType(MessengerGlassUnderlay),
    );
    expect(filesUnderlay, findsOneWidget);
    final filesBlurFinder = find.descendant(
      of: filesUnderlay,
      matching: find.byType(ProgressiveBlur),
    );
    final filesBlur = tester.widget<ProgressiveBlur>(filesBlurFinder);
    expect(filesBlur.maxSigma, 8);
    expect(filesBlur.falloff, 3.0);
    expect(filesBlur.direction, ProgressiveBlurDirection.topToBottom);
    final browserRect = tester.getRect(browserFinder);
    final filesGlassRect = tester.getRect(filesBlurFinder);
    expect(filesGlassRect.top, closeTo(browserRect.top, .001));
    expect(filesGlassRect.left, closeTo(browserRect.left + 2, .001));
    expect(filesGlassRect.right, closeTo(browserRect.right - 3, .001));
    expect(filesGlassRect.height, 103);
    final filesClip = tester.widget<ClipRRect>(
      find.descendant(of: filesUnderlay, matching: find.byType(ClipRRect)),
    );
    expect(
      filesClip.borderRadius,
      const BorderRadius.only(
        topLeft: Radius.circular(14),
        topRight: Radius.circular(14),
      ),
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Files tile lives in Apps and remains available from chat', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    await pumpShell(tester, manager: manager);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();

    expect(find.text('Files'), findsOneWidget);
    expect(find.byKey(const ValueKey('appsDirectoryFiles')), findsNothing);
    expect(
      find.byKey(const ValueKey('launcherCell:system:files')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('chatFilter-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open files'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('filesAppPanel')), findsOneWidget);
    final filesX = tester.getRect(find.byKey(const ValueKey('filesAppClose')));
    final toggle = tester.getRect(
      find.byKey(const ValueKey('chatSidebarCollapse')),
    );
    expect(filesX.center.dy, closeTo(35, .5), reason: 'filesX=$filesX');
    expect(filesX.center.dy, closeTo(toggle.center.dy, .5));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('sidebar-left toggle hides and shows every section', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    await pumpShell(tester, manager: manager);

    for (final label in ['Chats', 'Activity', 'Apps']) {
      if (label != 'Chats') {
        await tester.tap(
          find.byKey(ValueKey('messengerPrimaryNav-${label.toLowerCase()}')),
        );
        await tester.pumpAndSettle();
      }
      final collapse = find.byKey(const ValueKey('chatSidebarCollapse'));
      expect(collapse, findsOneWidget, reason: label);
      final newRect = tester.getRect(
        find.byKey(const ValueKey('messengerNewButton')),
      );
      final collapseRect = tester.getRect(collapse);
      expect(newRect.width, 32, reason: label);
      expect(newRect.height, 32, reason: label);
      expect(
        collapseRect.width,
        FaIconActionButton.defaultDiameter,
        reason: label,
      );
      expect(
        collapseRect.height,
        FaIconActionButton.defaultDiameter,
        reason: label,
      );
      // Apps has no sidebar search (owner call) — nothing to measure.
      if (label != 'Apps')
        expect(
          tester
                  .getRect(find.byKey(const ValueKey('messengerSearchField')))
                  .right <=
              newRect.left,
          isTrue,
          reason: label,
        );
      expect(
        find.descendant(
          of: collapse,
          matching: find.byType(MessengerSidebarLeftIcon),
        ),
        findsOneWidget,
        reason: label,
      );
      await tester.tap(collapse);
      await tester.pumpAndSettle();
      final expand = find.byKey(const ValueKey('chatSidebarExpand'));
      expect(expand, findsOneWidget, reason: label);
      expect(
        find.descendant(
          of: expand,
          matching: find.byType(MessengerSidebarLeftIcon),
        ),
        findsOneWidget,
        reason: label,
      );
      await tester.tap(expand);
      await tester.pumpAndSettle();
      expect(collapse, findsOneWidget, reason: label);
    }
  });

  testWidgets('Apps overview opens installed apps from the Launchpad grid', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await env.writeFile(
      'apps/demo/manifest.json',
      '{"name":"Demo","description":"A real installed demo app"}',
    );
    await env.writeFile(
      'apps/demo/widget.js',
      '(function(){jsr.render({type:"text",data:"hi"});})();',
    );
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    await pumpShell(tester, manager: manager);
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();

    expect(find.text('Widgets Catalog'), findsWidgets);
    expect(find.text('Widget Store'), findsNothing);
    expect(find.text('Widgets Store'), findsNothing);
    expect(find.byKey(const ValueKey('appsFeatureCards')), findsNothing);
    final appTile = find.byKey(const ValueKey('launcherCell:app:demo'));
    expect(appTile, findsOneWidget);
    await tester.ensureVisible(appTile);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(appTile);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(MessengerAppPanel), findsOneWidget);

    // Close the real app presentation so JsAppView/JsAppEngine dispose and
    // their UI-tree watcher cannot outlive this widget test.
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  wideShellNarrowHomeTests();

  // Owner rule (FaIconActionButton unification): the SEARCH field and the
  // NEW button are THE SAME shared widgets across chats/activity/apps
  // section switches — built once by the ONE MessengerSectionHeader the
  // shell owns, never duplicated per section. Identical boxes (epsilon
  // 0.5), identical runtime types, one shared ancestor component.
  testWidgets(
    'search field and New button are one shared pair across section switches',
    (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      await pumpShell(tester, manager: manager);

      final snapshots = <String, _HeaderSlotSnapshot>{};
      for (final section in const ['chats', 'activity', 'apps']) {
        if (section != 'chats') {
          await tester.tap(
            find.byKey(ValueKey('messengerPrimaryNav-$section')),
          );
          await tester.pumpAndSettle();
        }
        final search = find.byKey(const ValueKey('messengerSearchField'));
        final newButton = find.byKey(const ValueKey('messengerNewButton'));
        // Apps has no sidebar search (owner call) — only Chats/Activity
        // share the header search slot.
        expect(
          search,
          section == 'apps' ? findsNothing : findsOneWidget,
          reason: section,
        );
        expect(newButton, findsOneWidget, reason: section);
        // One shared component: both slots are descendants of the ONE
        // MessengerSectionHeader the shell builds for every section.
        if (section != 'apps')
          expect(
            find
                .ancestor(
                  of: search,
                  matching: find.byType(MessengerSectionHeader),
                )
                .evaluate()
                .length,
            1,
            reason: section,
          );
        expect(
          find
              .ancestor(
                of: newButton,
                matching: find.byType(MessengerSectionHeader),
              )
              .evaluate()
              .length,
          1,
          reason: section,
        );
        if (section == 'apps') continue;
        snapshots[section] = _HeaderSlotSnapshot(
          searchRect: tester.getRect(search),
          newRect: tester.getRect(newButton),
          searchType: tester.widget(search).runtimeType,
          newType: tester.widget(newButton).runtimeType,
        );
      }

      // The FILES band search is the SAME one component: pump the real
      // FilesChrome band and compare it against the sidebar header's
      // field — same runtime type, same height/vertical metrics
      // (epsilon 0.5), same capsule radius.
      final filesSearch = FileBrowser(env: MemoryExecutionEnv());
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFaTheme(
            direction: FaVisualDirection.glass,
            brightness: Brightness.dark,
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 480, height: 600, child: filesSearch),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final filesField = find.byKey(const ValueKey('fileBrowserSearch'));
      expect(filesField, findsOneWidget);
      final filesRect = tester.getRect(filesField);
      final filesType = tester.widget(filesField).runtimeType;
      final filesShape = tester
          .widget<CupertinoTextField>(
            find.descendant(
              of: filesField,
              matching: find.byType(CupertinoTextField),
            ),
          )
          .decoration
          ?.border;
      final sidebarField = find.byKey(const ValueKey('messengerSearchField'));
      expect(sidebarField, findsNothing, reason: 'shell pumped away');
      // Rebuild the shell's header field standalone for the box compare:
      // the messenger header slot (the one the sections shared above).
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFaTheme(
            direction: FaVisualDirection.glass,
            brightness: Brightness.dark,
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: SessionSearchField(
                  key: const ValueKey('messengerSearchField'),
                  controller: TextEditingController(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final standaloneField = find.byKey(
        const ValueKey('messengerSearchField'),
      );
      final sidebarRect = tester.getRect(standaloneField);
      expect(
        tester.widget(standaloneField).runtimeType,
        filesType,
        reason: 'files band search is the one shared component',
      );
      expect(
        sidebarRect.height,
        closeTo(filesRect.height, .5),
        reason: 'search capsule height',
      );
      expect(
        sidebarRect.top - sidebarRect.center.dy,
        closeTo(filesRect.top - filesRect.center.dy, .5),
        reason: 'vertical metrics',
      );
      final sidebarShape = tester
          .widget<CupertinoTextField>(
            find
                .descendant(
                  of: standaloneField,
                  matching: find.byType(CupertinoTextField),
                )
                .first,
          )
          .decoration
          ?.border;
      expect(sidebarShape, filesShape, reason: 'capsule radius tokens');

      final base = snapshots['chats']!;
      for (final entry in snapshots.entries) {
        final other = entry.value;
        final reason = 'section ${entry.key}';
        expect(other.searchType, base.searchType, reason: reason);
        expect(other.newType, base.newType, reason: reason);
        expect(
          other.searchRect.left,
          closeTo(base.searchRect.left, .5),
          reason: reason,
        );
        expect(
          other.searchRect.top,
          closeTo(base.searchRect.top, .5),
          reason: reason,
        );
        expect(
          other.searchRect.right,
          closeTo(base.searchRect.right, .5),
          reason: reason,
        );
        expect(
          other.searchRect.bottom,
          closeTo(base.searchRect.bottom, .5),
          reason: reason,
        );
        expect(
          other.newRect.left,
          closeTo(base.newRect.left, .5),
          reason: reason,
        );
        expect(
          other.newRect.top,
          closeTo(base.newRect.top, .5),
          reason: reason,
        );
        expect(
          other.newRect.right,
          closeTo(base.newRect.right, .5),
          reason: reason,
        );
        expect(
          other.newRect.bottom,
          closeTo(base.newRect.bottom, .5),
          reason: reason,
        );
      }
    },
  );

  // Subagent sessions owner pass: the badge docks above the composer and
  // the subagent chat's close returns to its parent.
  group('subagent switcher', () {
    Future<void> createSubagent(
      JsonlSessionRepo repo, {
      required String id,
      required String parent,
      String? taskName,
    }) => repo.create(
      JsonlSessionCreateOptions(
        cwd: '/tmp',
        id: id,
        metadata: {'agent': 'subagent', 'parent': parent, 'id': ?taskName},
      ),
    );

    testWidgets('a parent chat shows the subagent badge above the composer; '
        'a popover row tap opens that subagent chat', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('fake-session', _listedService(env));
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      await createSubagent(repo, id: 'sub-scan', parent: 'fake-session');
      await createSubagent(repo, id: 'sub-watch', parent: 'fake-session');

      await pumpShell(
        tester,
        manager: manager,
        sessionNamesStore: SessionNamesStore.inMemory({
          'fake-session': 'poc',
          'sub-scan': 'scan-agent',
        }),
      );
      await tester.pumpAndSettle();

      // One badge above the composer for the open PARENT chat; the
      // subagent rows stay hidden until summoned.
      expect(find.byKey(const ValueKey('chatSubagentBadge')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('chatSubagentChip-sub-scan')),
        findsNothing,
      );
      expect(find.text('scan-agent'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('chatSubagentBadge')));
      await tester.pumpAndSettle();

      // The picker popover: one row per subagent, no parent chip while
      // the parent itself is open.
      expect(
        find.byKey(const ValueKey('chatSubagentEntry-sub-scan')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('chatSubagentEntry-sub-watch')),
        findsOneWidget,
      );
      expect(find.text('←'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('chatSubagentEntry-sub-scan')),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      // The row opened the SUBAGENT chat through the same clone flow a
      // chat list row uses.
      expect(manager.activeId, 'sub-scan');
      // The badge persists for the subagent chat: its popover lists the
      // parent chip first (the title also rides the header's session
      // label — scope to rows via keys).
      await tester.tap(find.byKey(const ValueKey('chatSubagentBadge')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('chatSubagentEntry-fake-session')),
        findsOneWidget,
      );
      expect(find.text('←'), findsOneWidget);

      final opened = manager.sessions.firstWhere((s) => s.id == 'sub-scan');
      manager.switchTo('fake-session');
      await manager.closeSession('sub-scan');
      opened.service.dispose();
      await tester.pumpAndSettle();
    });

    testWidgets('the human task name reaches both picker and chat header', (
      tester,
    ) async {
      const childId = '0198f2f5-90e5-7f35-8e30-bdb535d04b04';
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('fake-session', _listedService(env));
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      await createSubagent(
        repo,
        id: childId,
        parent: 'fake-session',
        taskName: 'channel-open-fix',
      );
      await pumpShell(tester, manager: manager);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('chatSubagentBadge')));
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey('chatSubagentEntry-$childId'));
      expect(
        find.descendant(of: row, matching: find.text('channel-open-fix')),
        findsOneWidget,
      );
      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      expect(manager.activeId, childId);
      expect(
        tester.widget<ChatScreen>(find.byType(ChatScreen)).sessionTitle,
        'channel-open-fix',
      );
      final opened = manager.sessions.firstWhere((s) => s.id == childId);
      manager.switchTo('fake-session');
      await manager.closeSession(childId);
      opened.service.dispose();
      await tester.pumpAndSettle();
    });

    testWidgets('closing the subagent chat returns to the PARENT chat, '
        'not the narrow home', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('fake-session', _listedService(env));
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      await createSubagent(repo, id: 'sub-scan', parent: 'fake-session');

      await pumpShell(
        tester,
        manager: manager,
        sessionNamesStore: SessionNamesStore.inMemory({
          'fake-session': 'poc',
          'sub-scan': 'scan-agent',
        }),
        size: const Size(390, 844),
      );
      await tester.pumpAndSettle();

      // Parents only on the narrow Chats home: the subagent is NOT a
      // row; the parent row opens its chat with the badge above input.
      expect(find.text('scan-agent'), findsNothing);
      await tester.tap(find.text('poc'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('chatSubagentBadge')), findsOneWidget);

      // Badge → picker popover → row tap: the subagent chat opens in the
      // SAME narrow route.
      await tester.tap(find.byKey(const ValueKey('chatSubagentBadge')));
      await tester.pumpAndSettle();
      // The parent chat is open: no parent chip in the popover yet.
      expect(find.text('←'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('chatSubagentEntry-sub-scan')),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(manager.activeId, 'sub-scan');
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.text('←'), findsNothing);

      // Back intercepts: the route STAYS and the parent chat takes over.
      await tester.tap(find.byType(BackButton).first);
      await tester.pumpAndSettle();
      expect(manager.activeId, 'fake-session');
      expect(
        find.byType(ChatScreen),
        findsOneWidget,
        reason: 'close returns to the parent chat, not the home',
      );
      expect(find.text('← poc'), findsNothing);

      // Now back pops to the narrow home normally.
      await tester.tap(find.byType(BackButton).first);
      await tester.pumpAndSettle();
      expect(find.byType(ChatListPanel), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);

      // Cleanup: release the cloned session's drive-lease heartbeat.
      final opened = manager.sessions.firstWhere((s) => s.id == 'sub-scan');
      await manager.closeSession('sub-scan');
      opened.service.dispose();
      await tester.pumpAndSettle();
    });
  });
}

/// The shared header's search/new slots captured for one section.
class _HeaderSlotSnapshot {
  const _HeaderSlotSnapshot({
    required this.searchRect,
    required this.newRect,
    required this.searchType,
    required this.newType,
  });

  final Rect searchRect;
  final Rect newRect;
  final Type searchType;
  final Type newType;
}
