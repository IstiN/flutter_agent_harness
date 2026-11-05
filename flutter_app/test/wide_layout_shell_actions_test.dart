@TestOn('vm')
/// Widget tests for the wide shell's session actions (issue #561): the
/// new-session folder dialog, the persisted-session open degrading on a
/// ghost/transcript-less entry, and the session info dialog contents.
/// Fakes mirror `wide_layout_shell_sidebar_resize_test.dart`.
library;

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/apps/widgets_catalog_sheet.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/main.dart';
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
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_panel.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/chats/local_sessions_panel.dart';
import 'package:fa/ui/chats/networks_list_panel.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa_ui/fa_ui.dart'
    show
        FaChatHost,
        FaIconActionButton,
        FaLogo,
        FaSectionEyebrow,
        FaSurface,
        FaVisualDirection,
        buildFaTheme,
        debugFaGlassAlwaysFake;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassIconButton, ProgressiveBlur, ProgressiveBlurDirection;
import 'package:flutter/cupertino.dart' show CupertinoTextField;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

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

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('ru');
  });
  setUp(() => debugFaGlassAlwaysFake = true);
  tearDown(() => debugFaGlassAlwaysFake = false);

  Future<void> pumpShell(
    WidgetTester tester, {
    required FlutterSessionManager manager,
    SessionNamesStore? sessionNamesStore,
    LocalChatListSource Function()? localChatAdapterFactory,
    Size size = const Size(1280, 800),
    Locale locale = const Locale('en'),
    FaVisualDirection direction = FaVisualDirection.glass,
    Brightness brightness = Brightness.dark,
    bool reducedMotion = false,
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
          builder: (context) => localChatAdapterFactory == null
              ? faHomeScreen(
                  context: context,
                  manager: manager,
                  sessionNamesStore: sessionNamesStore,
                )
              : WideLayoutShell(
                  manager: manager,
                  sessionNamesStore: sessionNamesStore,
                  localChatAdapterFactory: localChatAdapterFactory,
                ),
        ),
      ),
    );
    await tester.pump();
  }

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

  testWidgets('wide shell opens in Chats without a permanent Apps pane', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', _fakeService(env));

    await pumpShell(tester, manager: manager);

    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byType(AppLauncherScreen), findsNothing);
    // Chats is the implicit home and stays a quiet destination; the selected
    // filter owns the toolbar's text.
    expect(find.text('Chats'), findsNothing);
    expect(find.text('Search chats'), findsOneWidget);
    expect(find.byKey(const ValueKey('messengerNewButton')), findsOneWidget);
    expect(find.text('SESSIONS'), findsNothing);
    expect(find.text('Search sessions'), findsNothing);
    // Secondary utilities live in Apps, not as a second navigation stack.
    expect(find.widgetWithText(SidebarNavItem, 'Files'), findsNothing);
    expect(find.widgetWithText(SidebarNavItem, 'Settings'), findsNothing);
    // The vertical rail owns navigation now: All/Unread lead, Local and
    // the Network destination follow, Channels/Activity/Apps close; the
    // horizontal toolbar is gone (agents sessions live in Local folders
    // and the flat All list — no rail row).
    final rail = find.byKey(const ValueKey('messengerNavRail'));
    expect(rail, findsOneWidget);
    expect(find.byKey(const ValueKey('chatCategoryChips')), findsNothing);
    expect(
      find.byKey(const ValueKey('messengerPrimaryNav-chats')),
      findsNothing,
      reason: 'the All filter row is the Chats home',
    );
    for (final destination in const [
      'chatFilter-all',
      'chatFilter-unread',
      'messengerPrimaryNav-local',
      'messengerPrimaryNav-network',
      'chatFilter-channels',
      'messengerPrimaryNav-activity',
      'messengerPrimaryNav-apps',
    ]) {
      expect(
        find.descendant(of: rail, matching: find.byKey(ValueKey(destination))),
        findsOneWidget,
        reason: destination,
      );
    }
    expect(
      find.descendant(
        of: rail,
        matching: find.byKey(const ValueKey('chatFilter-agents')),
      ),
      findsNothing,
      reason: 'agents have no rail row (Local folders own them)',
    );
    expect(
      find.byKey(const ValueKey('chatNetworkFilter')),
      findsNothing,
      reason: 'the rail Network row is re-keyed messengerPrimaryNav-network',
    );
    await tester.pump(const Duration(milliseconds: 100));
  });

  for (final size in const [Size(800, 900), Size(1440, 900)]) {
    testWidgets(
      'Apps keeps its directory beside the overview at ${size.width}',
      (tester) async {
        final env = MemoryExecutionEnv();
        final manager = FlutterSessionManager(
          env: env,
          sessionsRoot: '/sessions',
        )..addSession('fake-session', _fakeService(env));

        await pumpShell(tester, manager: manager, size: size);
        expect(find.byType(AppLauncherScreen), findsNothing);

        await tester.tap(
          find.byKey(const ValueKey('messengerPrimaryNav-apps')),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AppLauncherScreen), findsOneWidget);
        expect(find.byType(ChatScreen), findsNothing);
        expect(find.byType(ChatListPanel), findsOneWidget);
        expect(find.byKey(const ValueKey('appsDirectory')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('appsDirectoryMyApps')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('appsDirectoryStore')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('appsDirectoryRunning')),
          findsOneWidget,
        );
        expect(find.text('Files'), findsOneWidget);
        // The directory's Settings tile plus the rail's pinned settings row.
        expect(find.text('Settings'), findsNWidgets(2));
        final appsRect = tester.getRect(find.byType(AppLauncherScreen));
        expect(appsRect.left, greaterThan(250));
        expect(
          appsRect.right,
          size.width,
          reason: 'outer frame reaches the window; content owns its inset',
        );

        await tester.tap(find.byKey(const ValueKey('appsDirectoryStore')));
        await tester.pumpAndSettle();
        expect(find.byType(WidgetsCatalogSheet), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('appsDirectoryMyApps')));
        await tester.pumpAndSettle();
        expect(find.byType(WidgetsCatalogSheet), findsNothing);
        await tester.tap(find.byKey(const ValueKey('appsQuickOpen')));
        await tester.pump();
        final search = tester.widget<CupertinoTextField>(
          find.descendant(
            of: find.byKey(const ValueKey('messengerSearchField')),
            matching: find.byType(CupertinoTextField),
          ),
        );
        expect(search.focusNode?.hasFocus, isTrue);

        final appsAction = find.byKey(
          const ValueKey('messengerPrimaryNav-apps'),
        );
        expect(
          find.descendant(of: appsAction, matching: find.text('Apps')),
          findsOneWidget,
        );
        final appsSemantics = tester.widget<Semantics>(
          find
              .descendant(
                of: appsAction,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is Semantics && widget.properties.button == true,
                ),
              )
              .first,
        );
        expect(appsSemantics.properties.selected, isTrue);
      },
    );
  }

  testWidgets('open_app reveals Apps before resolving its nested Navigator', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', _fakeService(env));

    await pumpShell(tester, manager: manager);
    expect(FaChatHost.jsAppNavigatorKey?.currentState, isNull);

    final revealed = FaChatHost.revealJsApps!.call();
    await tester.pump();
    await revealed;
    await tester.pumpAndSettle();

    expect(find.byType(AppLauncherScreen), findsOneWidget);
    expect(FaChatHost.jsAppNavigatorKey?.currentState, isNotNull);
    final appsAction = find.byKey(const ValueKey('messengerPrimaryNav-apps'));
    expect(
      find.descendant(of: appsAction, matching: find.text('Apps')),
      findsOneWidget,
    );
    final appsSemantics = tester.widget<Semantics>(
      find
          .descendant(
            of: appsAction,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.button == true,
            ),
          )
          .first,
    );
    expect(appsSemantics.properties.selected, isTrue);
  });

  testWidgets('Apps full-window brand opens the shared profile', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', _fakeService(env));

    await pumpShell(tester, manager: manager);
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wideShellFaBrand')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('narrowShellProfileRoute')),
      findsOneWidget,
    );
  });

  testWidgets('desktop app opens beside the current chat and supports Full, '
      'Pin, section navigation, and Close', (tester) async {
    final env = MemoryExecutionEnv();
    final service = _fakeService(env);
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', service);
    const app = JsAppInfo(
      id: 'demo',
      name: 'Demo app',
      description: 'Demo',
      icon: 'D',
      declaredPermissions: AppPermissions(),
    );

    await pumpShell(tester, manager: manager);
    await pushJsApp(
      tester.element(find.byType(ChatScreen)),
      manager: manager,
      app: app,
      source: 'test',
    );
    await tester.pumpAndSettle();

    expect(find.byType(MessengerAppPanel), findsOneWidget);
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byType(AppLauncherScreen), findsNothing);
    expect(tester.getRect(find.byType(MessengerAppPanel)).width, 340);

    await tester.tap(find.byKey(const ValueKey('appFull')));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(MessengerAppPanel)).width, 1280);
    expect(find.text('Exit full'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('appFull')));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(MessengerAppPanel)).width, 340);

    await tester.tap(find.byKey(const ValueKey('appPin')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MessengerAppPanel), findsOneWidget);
    expect(find.byType(ActivityDetailPanel), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('appPin')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chatFilter-all')));
    await tester.pumpAndSettle();
    expect(find.byType(MessengerAppPanel), findsNothing);
  });

  testWidgets('narrow Apps opens one full surface and Close returns to the '
      'directory', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    const app = JsAppInfo(
      id: 'demo',
      name: 'Demo app',
      description: 'Demo',
      icon: 'D',
      declaredPermissions: AppPermissions(),
    );

    await pumpShell(tester, manager: manager, size: const Size(390, 844));
    await tester.tap(find.text('Apps'));
    await tester.pumpAndSettle();
    await pushJsApp(
      tester.element(find.byType(AppLauncherScreen)),
      manager: manager,
      app: app,
      source: 'test',
    );
    await tester.pumpAndSettle();

    expect(find.byType(MessengerAppPanel), findsOneWidget);
    expect(tester.getRect(find.byType(MessengerAppPanel)).width, 390);
    expect(find.byKey(const ValueKey('narrowShellNavigation')), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MessengerAppPanel), findsNothing);
    expect(find.byType(AppLauncherScreen), findsOneWidget);

    await pushJsApp(
      tester.element(find.byType(AppLauncherScreen)),
      manager: manager,
      app: app,
      source: 'test',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appClose')));
    await tester.pumpAndSettle();
    expect(find.byType(MessengerAppPanel), findsNothing);
    expect(find.byType(AppLauncherScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('narrowShellNavigation')), findsOneWidget);
  });

  testWidgets('Activity explains its empty state', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');

    await pumpShell(tester, manager: manager);
    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();

    expect(find.text('No session activity yet.'), findsOneWidget);
    expect(find.byKey(const ValueKey('activityFilter')), findsOneWidget);
    expect(find.byKey(const ValueKey('activityList')), findsNothing);
    expect(find.text('Choose an activity item'), findsOneWidget);
  });

  testWidgets('Activity follows live streaming state and opens its session '
      'back in Chats', (tester) async {
    final env = MemoryExecutionEnv();
    final runningService = _fakeService(env);
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('running-session', runningService)
      ..addSession('recent-session', _fakeService(env));
    final names = SessionNamesStore.inMemory({
      'running-session': 'Build release',
      'recent-session': 'Write docs',
    });

    await pumpShell(tester, manager: manager, sessionNamesStore: names);
    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('activitySession-running-session')),
        matching: find.text('Build release'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('activitySession-recent-session')),
        matching: find.text('Write docs'),
      ),
      findsOneWidget,
    );
    expect(find.byType(ChatListPanel), findsOneWidget);
    expect(find.byType(ActivityListPanel), findsOneWidget);
    expect(find.byType(ActivityDetailPanel), findsOneWidget);
    expect(find.text('Recent'), findsWidgets);

    await tester.enterText(
      find.byKey(const ValueKey('messengerSearchField')),
      'Build',
    );
    // The ONE shared search field applies queries after its 150ms
    // debounce (the sidebar/Files capsule behavior) — advance past it.
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(const ValueKey('activitySession-running-session')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('activitySession-recent-session')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const ValueKey('messengerSearchField')),
      '',
    );
    await tester.pump(const Duration(milliseconds: 200));

    runningService.isStreaming = true;
    runningService.notifyListeners();
    await tester.pump();

    expect(find.text('Running'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('activitySession-running-session')),
        matching: find.text('Build release'),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('activitySession-running-session')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.byType(ChatListPanel), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('activityOpenChat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(manager.activeId, 'running-session');
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byType(ActivityDetailPanel), findsNothing);
    expect(find.byType(ChatListPanel), findsOneWidget);
    expect(
      find.byKey(const ValueKey('wideShellPrimaryNavigation')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
      findsOneWidget,
    );
    runningService.isStreaming = false;
    runningService.notifyListeners();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Liquid Glass desktop separates rounded panels without a divider',
    (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('glass-session', _fakeService(env));
      await pumpShell(tester, manager: manager);
      await tester.pumpAndSettle();

      final sidebarPanel = tester.widget<FaSurface>(
        find
            .descendant(
              of: find.byKey(const ValueKey('glassSidebarPanel')),
              matching: find.byType(FaSurface),
            )
            .first,
      );
      expect(sidebarPanel.glass, isTrue);
      expect(sidebarPanel.color, const Color(0xFF1C1C1E));
      // The chrome band is a graduated blur: rows scroll beneath the
      // search/segment glass (constant sigma — the glass is always armed).
      final underlay = tester.widget<ProgressiveBlur>(
        find.byKey(const ValueKey('chatListChromeUnderlay')),
      );
      expect(underlay.maxSigma, 8);
      final centerPanel = tester.widget<Container>(
        find.byKey(const ValueKey('glassCenterPanel')),
      );
      final centerFrame = centerPanel.decoration as BoxDecoration?;
      expect(centerFrame?.color, const Color(0xFF1E1E1E));
      expect(centerFrame?.border, isNull);
      final sidebar = tester.widget<SizedBox>(
        find.byKey(const ValueKey('desktopSidebarContainer')),
      );
      expect(sidebar.width, 260);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('desktopSidebarContainer')))
            .right,
        tester.getRect(find.byKey(const ValueKey('glassCenterPanel'))).left,
        reason: 'no divider or gap between animated panels',
      );
      final dragHandle = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(kSidebarDragHandleKey),
          matching: find.byKey(const ValueKey('faPaneResizeHandleHitSurface')),
        ),
      );
      expect(
        (dragHandle.decoration as BoxDecoration?)?.color,
        Colors.transparent,
      );
    },
  );

  testWidgets('token notifications do not reload every local session', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final service = _fakeService(env);
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('streaming-session', service);
    final source = _CountingLocalChatListSource();
    await pumpShell(
      tester,
      manager: manager,
      localChatAdapterFactory: () => source,
    );
    await tester.pumpAndSettle();
    final initialLoads = source.loadCount;

    service.isStreaming = true;
    service.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(source.loadCount, initialLoads + 1, reason: 'run start refreshes');

    for (var delta = 0; delta < 12; delta++) {
      service.notifyListeners();
      await tester.pump();
    }
    expect(
      source.loadCount,
      initialLoads + 1,
      reason: 'token deltas must not start persisted-session disk loads',
    );

    service.isStreaming = false;
    service.notifyListeners();
    await tester.pumpAndSettle();
    expect(source.loadCount, initialLoads + 2, reason: 'run end refreshes');
  });

  testWidgets('Activity filters running and recent sessions', (tester) async {
    final env = MemoryExecutionEnv();
    final running = _fakeService(env)..isStreaming = true;
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('running-session', running)
      ..addSession('recent-session', _fakeService(env));

    await pumpShell(tester, manager: manager);
    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('activityFilter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Running').last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('activitySession-running-session')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('activitySession-recent-session')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('activityFilter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recent').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('activitySession-running-session')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('activitySession-recent-session')),
      findsOneWidget,
    );
    running.isStreaming = false;
  });

  testWidgets('Activity and Apps use the Russian messenger labels', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));

    await pumpShell(tester, manager: manager, locale: const Locale('ru'));
    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Вся активность'), findsOneWidget);
    expect(find.text('Статус'), findsOneWidget);
    expect(find.text('Последняя активность'), findsOneWidget);
    expect(find.text('Открыть чат'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    expect(find.text('Мои приложения · Каталог виджетов'), findsOneWidget);
    expect(find.text('Мои приложения'), findsWidgets);
    expect(find.text('Каталог виджетов'), findsWidgets);
    expect(find.text('Магазин виджетов'), findsNothing);
  });

  testWidgets('sidebar section labels share one eyebrow style', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));

    await pumpShell(tester, manager: manager);
    // The flat Chats home renders NO section eyebrows (one flat active
    // list — no Pinned/Recent split); the Activity/Apps bodies still name
    // themselves through FaSectionEyebrow, so typography and case cannot
    // drift where eyebrows do render.
    expect(find.byType(FaSectionEyebrow), findsNothing);

    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FaSectionEyebrow, 'Apps'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(FaSectionEyebrow, 'All activity'),
      findsOneWidget,
    );
    // The count chip on the Activity toolbar stays a plain dim numeral.
    expect(find.byKey(const ValueKey('activityCount')), findsOneWidget);
  });

  testWidgets('the vertical rail owns its surface beside the glass chrome', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    await pumpShell(tester, manager: manager);
    await tester.pump(const Duration(milliseconds: 100));
    // The rail's floating glass card: the outer footprint starts at the
    // window's left edge and carries the 8pt margins on every side; the
    // sidebar column follows immediately (the rail's trailing margin is
    // the seam, the sidebar's own margin completes the gutter).
    final railRect = tester.getRect(
      find.byKey(const ValueKey('messengerNavRail')),
    );
    expect(railRect.left, 0);
    expect(railRect.width, MessengerNavRail.width + MessengerNavRail.seam * 2);
    expect(
      railRect.height,
      tester.view.physicalSize.height / tester.view.devicePixelRatio,
    );
    final sidebar = tester.getRect(
      find.byKey(const ValueKey('desktopSidebarContainer')),
    );
    expect(sidebar.left, railRect.right);
    // The rail's surface is the chats panel's glass 1:1: same FaSurface
    // params (glass mode, one shared backdrop capture, card radius,
    // surface1 tint) and the same 8pt gutter between the two cards — the
    // rail keeps its trailing 8pt margin-as-seam; the sidebar card leads
    // with 0 and keeps its 8pt window margins elsewhere (owner: the gap
    // halves to 8pt total).
    final railSurface = tester.widget<FaSurface>(
      find.descendant(
        of: find.byKey(const ValueKey('messengerNavRail')),
        matching: find.byType(FaSurface),
      ),
    );
    final sidebarSurface = tester.widget<FaSurface>(
      find
          .descendant(
            of: find.byKey(const ValueKey('glassSidebarPanel')),
            matching: find.byType(FaSurface),
          )
          .first,
    );
    expect(railSurface.glass, sidebarSurface.glass);
    expect(railSurface.useBackdropGroup, sidebarSurface.useBackdropGroup);
    expect(
      railSurface.borderRadius?.topLeft.x,
      (sidebarSurface.borderRadius?.topLeft.x ?? 0) + 1,
      reason: 'the inner glass radius sits inside the outer 1pt frame',
    );
    expect(railSurface.color, sidebarSurface.color);
    final railCard = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('messengerNavRail')),
        matching: find.byType(FaSurface),
      ),
    );
    final sidebarCard = tester.getRect(
      find.byKey(const ValueKey('glassSidebarPanel')),
    );
    expect(
      sidebarCard.left - railCard.right,
      MessengerNavRail.seam,
      reason:
          'the rail trailing 8pt seam margin is the shared gutter (one '
          'margin, not two)',
    );
    // The horizontal section pill-bar is gone — its destinations moved
    // into the rail rows.
    expect(find.byKey(const ValueKey('chatCategoryChips')), findsNothing);
    expect(find.byType(MessengerFilterControl), findsNothing);

    // The chat chrome band's glass background stays armed (constant
    // sigma) under the search row.
    final underlay = tester.widget<ProgressiveBlur>(
      find.byKey(const ValueKey('chatListChromeUnderlay')),
    );
    expect(underlay.maxSigma, 8);
    expect(underlay.direction, ProgressiveBlurDirection.topToBottom);
  });

  testWidgets('centered header uses the selected folder and session name', (
    tester,
  ) async {
    final env = MemoryExecutionEnv(cwd: '/work/fa_network');
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    await pumpShell(
      tester,
      manager: manager,
      sessionNamesStore: SessionNamesStore.inMemory({
        'design-session': 'Release review',
      }),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('faChatHeaderProjectLabel')))
          .data,
      'fa_network',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('faChatHeaderSessionLabel')))
          .data,
      'Release review',
    );
    expect(find.byKey(const ValueKey('faChatHeaderTitlePill')), findsOneWidget);
  });

  testWidgets('shared section header and primary nav keep geometry and style', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    const labels = ['Chats', 'Activity', 'Apps'];
    final expectedRects = <String, Rect>{};

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
        Color? searchFill;
        BoxBorder? searchBorder;
        Color? newBackground;
        for (var section = 0; section < labels.length; section++) {
          if (section > 0) {
            await tester.tap(
              find.byKey(
                ValueKey(
                  'messengerPrimaryNav-${labels[section].toLowerCase()}',
                ),
              ),
            );
            await tester.pumpAndSettle();
          }
          final reason = '$direction $brightness ${labels[section]}';
          final search = find.byKey(const ValueKey('messengerSearchField'));
          final newButton = find.byKey(const ValueKey('messengerNewButton'));
          expect(search, findsOneWidget, reason: reason);
          expect(newButton, findsOneWidget, reason: reason);
          final current = <String, Rect>{
            'search': tester.getRect(search),
            'new': tester.getRect(newButton),
            if (section == 0)
              for (final label in const ['All', 'Unread', 'Channels'])
                'filter-$label': tester.getRect(
                  find.byKey(ValueKey('chatFilter-${label.toLowerCase()}')),
                ),
          };
          for (final entry in current.entries) {
            final expected = expectedRects[entry.key];
            if (expected == null) {
              expectedRects[entry.key] = entry.value;
            } else {
              expect(
                entry.value.left,
                closeTo(expected.left, .001),
                reason: reason,
              );
              expect(
                entry.value.top,
                closeTo(expected.top, .001),
                reason: reason,
              );
              expect(
                entry.value.right,
                closeTo(expected.right, .001),
                reason: reason,
              );
              expect(
                entry.value.bottom,
                closeTo(expected.bottom, .001),
                reason: reason,
              );
            }
          }

          if (section == 0) {
            // The rail: 78pt-wide rows on a fixed 64pt pitch, pictogram
            // 25–28pt with the label centered below. Order: All, Unread,
            // Local, Network, Channels, Activity, Apps.
            final all = current['filter-All']!;
            final unread = current['filter-Unread']!;
            final channels = current['filter-Channels']!;
            for (final rect in [all, unread, channels]) {
              expect(rect.width, MessengerNavRail.width, reason: reason);
              expect(rect.height, MessengerNavRail.rowPitch, reason: reason);
            }
            expect(
              unread.top - all.top,
              MessengerNavRail.rowPitch,
              reason: reason,
            );
            final local = tester.getRect(
              find.byKey(const ValueKey('messengerPrimaryNav-local')),
            );
            final network = tester.getRect(
              find.byKey(const ValueKey('messengerPrimaryNav-network')),
            );
            expect(
              local.top - unread.top,
              MessengerNavRail.rowPitch,
              reason: 'Local moved up, right after Unread',
            );
            expect(
              network.top - local.top,
              MessengerNavRail.rowPitch,
              reason: reason,
            );
            expect(
              channels.top - network.top,
              MessengerNavRail.rowPitch,
              reason: reason,
            );
            final allRow = find.byKey(const ValueKey('chatFilter-all'));
            final icon = tester.getRect(
              find.descendant(of: allRow, matching: find.byType(Icon)),
            );
            final label = tester.getRect(find.text('All'));
            expect(icon.width, inInclusiveRange(25, 28), reason: reason);
            expect(icon.center.dx, closeTo(all.center.dx, .5), reason: reason);
            expect(label.center.dx, closeTo(all.center.dx, .5), reason: reason);
            expect(
              label.center.dy,
              greaterThan(icon.center.dy),
              reason: reason,
            );
            // Activity and Apps close the rail on the same pitch.
            final activity = tester.getRect(
              find.byKey(const ValueKey('messengerPrimaryNav-activity')),
            );
            final apps = tester.getRect(
              find.byKey(const ValueKey('messengerPrimaryNav-apps')),
            );
            expect(
              activity.top - channels.top,
              MessengerNavRail.rowPitch,
              reason: reason,
            );
            expect(
              apps.top - activity.top,
              MessengerNavRail.rowPitch,
              reason: reason,
            );
            expect(local.height, MessengerNavRail.rowPitch, reason: reason);
            expect(network.height, MessengerNavRail.rowPitch, reason: reason);
            expect(activity.height, MessengerNavRail.rowPitch, reason: reason);
            expect(apps.height, MessengerNavRail.rowPitch, reason: reason);
            // Settings is pinned last.
            final settings = tester.getRect(
              find.byKey(const ValueKey('railSettingsRow')),
            );
            expect(settings.top, greaterThan(apps.top), reason: reason);
          }

          if (section == 2) {
            expect(
              find.byKey(const ValueKey('appsDirectorySearch')),
              findsNothing,
              reason: reason,
            );
            expect(search, findsOneWidget, reason: reason);
          }

          // Kit-level reads: the shared field is the kit's GlassTextField —
          // its CupertinoTextField carries a BoxDecoration with the fill
          // and the capsule border in every direction (the kit input is
          // the ONE search field, Material TextField is gone).
          final field = tester.widget<CupertinoTextField>(
            find.descendant(
              of: search,
              matching: find.byType(CupertinoTextField),
            ),
          );
          final newStyle = tester.widget<IconButton>(newButton).style;
          final background = newStyle?.backgroundColor?.resolve(const {});
          if (section == 0) {
            searchFill = field.decoration?.color;
            searchBorder = field.decoration?.border;
            newBackground = background;
          } else {
            expect(field.decoration?.color, searchFill, reason: reason);
            expect(field.decoration?.border, searchBorder, reason: reason);
            expect(background, newBackground, reason: reason);
          }
          expect(field.placeholder, isNotEmpty, reason: reason);
          expect(
            tester
                .widget<Icon>(
                  find.descendant(of: newButton, matching: find.byType(Icon)),
                )
                .icon,
            Icons.edit_outlined,
            reason: reason,
          );
        }
      }
    }
  });

  testWidgets('rail rows keep section selection and callbacks', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _listedService(env));
    await pumpShell(tester, manager: manager);
    await tester.pump(const Duration(milliseconds: 100));

    Semantics chip(String label) => tester.widget<Semantics>(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.button == true &&
                widget.properties.label == label,
          )
          .first,
    );
    SizedBox railRow(String key) =>
        tester.widget<SizedBox>(find.byKey(ValueKey(key)));
    // Every rail row shows its label; selection is the accent tint.
    expect(find.text('All'), findsOneWidget);
    for (final label in ['Unread', 'Channels']) {
      expect(find.text(label), findsOneWidget);
      expect(chip(label).properties.selected, isFalse);
    }
    expect(chip('All').properties.selected, isTrue);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chatFilter-all')),
        matching: find.byIcon(Icons.inbox_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('chatFilter-agents')),
      findsNothing,
      reason: 'agents have no rail row (Local folders own them)',
    );
    expect(
      find.byKey(const ValueKey('wideShellPrimaryNavigation')),
      findsNothing,
    );
    // The rail has no separate Chats destination: the All filter row IS
    // the Chats home.
    expect(
      find.byKey(const ValueKey('messengerPrimaryNav-chats')),
      findsNothing,
    );
    Finder sectionAction(String section) =>
        find.byKey(ValueKey('messengerPrimaryNav-$section'));
    String sectionLabel(String section) => switch (section) {
      'activity' => 'Activity',
      _ => 'Apps',
    };
    final allRect = tester.getRect(
      find.byKey(const ValueKey('chatFilter-all')),
    );
    expect(allRect.width, MessengerNavRail.width);
    final allIcon = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('chatFilter-all')),
        matching: find.byIcon(Icons.inbox_outlined),
      ),
    );
    final allText = tester.getRect(find.text('All'));
    expect(allIcon.center.dx, closeTo(allRect.center.dx, .5));
    expect(allText.center.dx, closeTo(allRect.center.dx, .5));
    for (final section in const ['activity', 'apps']) {
      final action = sectionAction(section);
      expect(tester.getRect(action).height, MessengerNavRail.rowPitch);
      expect(
        find.descendant(
          of: action,
          matching: find.byIcon(switch (section) {
            'activity' => Icons.notifications_none_rounded,
            _ => Icons.grid_view_rounded,
          }),
        ),
        findsOneWidget,
        reason: section,
      );
      // Rail rows always carry their label (Telegram pattern).
      expect(
        find.descendant(of: action, matching: find.text(sectionLabel(section))),
        findsOneWidget,
        reason: section,
      );
      expect(chip(sectionLabel(section)).properties.selected, isFalse);
    }

    await tester.pumpAndSettle();

    for (final selected in const ['activity', 'apps']) {
      await tester.tap(sectionAction(selected));
      await tester.pumpAndSettle();
      expect(
        chip(sectionLabel(selected)).properties.selected,
        isTrue,
        reason: selected,
      );
      // The filter rows quiet down while a section owns the rail.
      for (final label in const ['All', 'Unread', 'Channels']) {
        expect(chip(label).properties.selected, isFalse, reason: label);
      }
      for (final quiet in const ['activity', 'apps']) {
        expect(
          chip(sectionLabel(quiet)).properties.selected,
          quiet == selected,
          reason: quiet,
        );
      }
      expect(tester.takeException(), isNull, reason: selected);
    }

    // Tapping a filter returns to the Chats home from another section.
    await tester.tap(find.byKey(const ValueKey('chatFilter-unread')));
    await tester.pumpAndSettle();
    expect(find.byType(ActivityListPanel), findsNothing);
    expect(find.byKey(const ValueKey('appsDirectory')), findsNothing);
    expect(chip('Unread').properties.selected, isTrue);
    expect(find.text('Unread'), findsOneWidget);
    for (final quiet in const ['activity', 'apps']) {
      expect(
        chip(sectionLabel(quiet)).properties.selected,
        isFalse,
        reason: quiet,
      );
    }

    for (final label in const ['Channels', 'All']) {
      await tester.tap(
        find.byKey(ValueKey('chatFilter-${label.toLowerCase()}')),
      );
      await tester.pumpAndSettle();
      expect(
        chip(label).properties.selected,
        isTrue,
        reason: '$label must be tappable',
      );
    }
    // The Network row (the identity globe, re-keyed) swaps the CHATS
    // SIDEBAR content to the networks surface (the same slot the Local
    // drill-down uses); the chat message column keeps the chat — the old
    // chat-column surface is gone.
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-network')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatNetworksList')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatNetworksBack')), findsOneWidget);
    expect(find.byType(ChatNetworksPanel), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('glassCenterPanel')),
        matching: find.byType(ChatNetworksPanel),
      ),
      findsNothing,
      reason: 'the networks surface no longer renders in the message column',
    );
    // It lives IN the sidebar panel — the same slot the Local drill-down
    // uses.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('glassSidebarPanel')),
        matching: find.byType(ChatNetworksPanel),
      ),
      findsOneWidget,
    );
    // The sidebar swapped: the chat list panel is replaced while the
    // surface is open.
    expect(find.byType(ChatListPanel), findsNothing);
    // Back walks the surface to the normal chats list.
    await tester.tap(find.byKey(const ValueKey('chatNetworksBack')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatNetworksList')), findsNothing);
    expect(find.byKey(const ValueKey('chatListScroll')), findsOneWidget);
    expect(find.byType(ChatListPanel), findsOneWidget);
    expect(chip('All').properties.selected, isTrue);
    // The rail row itself never becomes selected.
    railRow('chatFilter-all');
  });

  testWidgets(
    'wide sections rebuild only the list and keep the shared panel chrome',
    (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _listedService(env));
      await pumpShell(tester, manager: manager);
      await tester.pumpAndSettle();

      final panel = find.byType(ChatListPanel);
      expect(find.byKey(const ValueKey('chatListScroll')), findsOneWidget);
      final railRect = tester.getRect(
        find.byKey(const ValueKey('messengerNavRail')),
      );
      final search = tester.getRect(
        find.byKey(const ValueKey('messengerSearchField')),
      );
      final newButton = tester.getRect(
        find.byKey(const ValueKey('messengerNewButton')),
      );
      final panelElement = tester.element(panel);

      await tester.tap(
        find.byKey(const ValueKey('messengerPrimaryNav-activity')),
      );
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(tester.element(panel), same(panelElement));
      expect(find.byType(ActivityListPanel), findsOneWidget);
      expect(find.byKey(const ValueKey('chatListScroll')), findsNothing);
      expect(
        find.byKey(const ValueKey('wideShellPrimaryNavigation')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(tester.element(panel), same(panelElement));
      expect(find.byKey(const ValueKey('appsDirectory')), findsOneWidget);
      expect(find.byType(ActivityListPanel), findsNothing);

      // Filters are the Chats home: tapping one returns from Apps.
      await tester.tap(find.byKey(const ValueKey('chatFilter-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chatListScroll')), findsOneWidget);
      // The rail is steady chrome: section switches never move it.
      expect(
        tester.getRect(find.byKey(const ValueKey('messengerNavRail'))),
        railRect,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('messengerSearchField'))),
        search,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('messengerNewButton'))),
        newButton,
      );

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('narrowShellNavigation')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('messengerPrimaryTab-Chats')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

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
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.text('Agent one'), findsOneWidget);
    expect(find.text('Agent two'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

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
            final search = tester.getRect(
              find.byKey(const ValueKey('messengerSearchField')),
            );
            final expandedCenter = tester.getRect(
              find.byKey(const ValueKey('glassCenterPanel')),
            );
            expect(collapse.center.dy, closeTo(35, .001), reason: reason);
            expect(
              search.center.dy,
              closeTo(collapse.center.dy, .001),
              reason: reason,
            );
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
                      find.byKey(const ValueKey('collapsedSidebarNewSession')),
                    )
                    .dx,
                closeTo(axis, .001),
                reason: '$reason New axis',
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
      final newActions =
          find.byKey(const ValueKey('messengerNewButton')).evaluate().length +
          find
              .byKey(const ValueKey('collapsedSidebarNewSession'))
              .evaluate()
              .length;
      expect(newActions, lessThanOrEqualTo(1));
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
        expect(composer.right - send.right, 2, reason: 'flush right');
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

  testWidgets('compact section headers keep identical search geometry', (
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
        for (final label in ['Chats', 'Activity', 'Apps']) {
          if (label != 'Chats') {
            await tester.tap(
              find.byKey(
                ValueKey('messengerPrimaryNav-${label.toLowerCase()}'),
              ),
            );
            await tester.pumpAndSettle();
          }
          final finder = find.byKey(const ValueKey('messengerSearchField'));
          expect(finder, findsOneWidget);
          final rect = tester.getRect(finder);
          final field = tester.widget<CupertinoTextField>(
            find.descendant(
              of: finder,
              matching: find.byType(CupertinoTextField),
            ),
          );
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
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    }
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
    final browser = tester.widget<Material>(
      find.byKey(const ValueKey('fileBrowserPanel')),
    );
    expect(browser.color, Colors.transparent);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('wide Apps Files route also uses the top action centerline', (
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
    await tester.tap(find.text('Files'));
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

  testWidgets(
    'Apps overview uses real feature cards and Widgets Catalog name',
    (tester) async {
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
      expect(find.byKey(const ValueKey('appsFeatureCards')), findsOneWidget);
      final feature = find.byKey(const ValueKey('appsFeatureCard-demo'));
      expect(feature, findsOneWidget);
      expect(find.text('A real installed demo app'), findsOneWidget);
      await tester.ensureVisible(feature);
      await tester.pumpAndSettle();
      final featureViewport = tester.getRect(
        find.byKey(const ValueKey('appsFeatureCards')),
      );
      expect(featureViewport.contains(tester.getCenter(feature)), isTrue);
      await tester.runAsync(() async {
        await tester.tap(feature);
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
    },
  );

  group('narrow messenger home', () {
    testWidgets('boots to the Chats conversation list, not the launcher', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _listedService(env));

      await pumpShell(
        tester,
        manager: manager,
        sessionNamesStore: SessionNamesStore.inMemory({
          'design-session': 'Fa 2.0 redesign',
        }),
        size: const Size(390, 844),
      );

      expect(find.byType(WideLayoutShell), findsOneWidget);
      expect(find.byType(ChatListPanel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('narrowShellNavigation')),
        findsOneWidget,
      );
      expect(find.text('Fa 2.0 redesign'), findsOneWidget);
      expect(find.text('Search chats'), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.byType(AppLauncherScreen), findsNothing);
      expect(find.byKey(const ValueKey('narrowShellNewChat')), findsOneWidget);
    });

    testWidgets(
      'macOS compact chrome clears traffic lights but phones do not',
      (tester) async {
        final env = MemoryExecutionEnv();
        final manager = FlutterSessionManager(
          env: env,
          sessionsRoot: '/sessions',
        )..addSession('design-session', _fakeService(env));
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        for (final platform in const [
          TargetPlatform.macOS,
          TargetPlatform.iOS,
          TargetPlatform.android,
        ]) {
          debugDefaultTargetPlatformOverride = platform;
          await tester.pumpWidget(const SizedBox());
          await pumpShell(tester, manager: manager, size: const Size(390, 844));
          final brand = find.byKey(const ValueKey('wideShellFaBrand'));
          final titlebar = find.byKey(const ValueKey('macosSidebarTitlebar'));
          if (platform == TargetPlatform.macOS) {
            expect(tester.getSize(titlebar).height, 30);
            expect(tester.getTopLeft(brand).dy, greaterThanOrEqualTo(30));
          } else {
            expect(titlebar, findsNothing);
            expect(tester.getTopLeft(brand).dy, lessThan(28));
          }
        }
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets('floating dock geometry is invariant across themes', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      const labels = ['Chats', 'Local', 'Activity', 'Apps'];
      const ids = ['chats', 'local', 'activity', 'apps'];

      for (final direction in FaVisualDirection.values) {
        for (final brightness in Brightness.values) {
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          await pumpShell(
            tester,
            manager: manager,
            direction: direction,
            brightness: brightness,
            size: const Size(390, 844),
          );
          await tester.pumpAndSettle();
          final reason = '$direction/$brightness';
          final navigation = find.byKey(
            const ValueKey('narrowShellNavigation'),
          );
          final dock = tester.getRect(navigation);
          expect(dock, const Rect.fromLTRB(12, 780, 378, 836), reason: reason);
          final surfaceFinder = find.descendant(
            of: navigation,
            matching: find.byType(FaSurface),
          );
          final surface = tester.widget<FaSurface>(surfaceFinder);
          final surfaceRect = tester.getRect(surfaceFinder);
          expect(surfaceRect.width, 280, reason: reason);
          expect(surfaceRect.height, 56, reason: reason);
          expect(surfaceRect.center.dx, 195, reason: reason);
          expect(
            surface.glass,
            direction == FaVisualDirection.glass,
            reason: reason,
          );
          expect(surface.useBackdropGroup, isTrue, reason: reason);
          final pill = tester.getRect(
            find.byKey(const ValueKey('narrowShellSelectionPill')),
          );
          expect(dock.contains(pill.topLeft), isTrue, reason: reason);
          expect(dock.contains(pill.bottomRight), isTrue, reason: reason);
          expect(pill.top - dock.top, 4, reason: reason);
          expect(dock.bottom - pill.bottom, 4, reason: reason);

          for (var index = 0; index < labels.length; index++) {
            final item = find.byKey(
              ValueKey('messengerPrimaryNav-${ids[index]}'),
            );
            final rect = tester.getRect(item);
            expect(rect.width, closeTo(280 / 4, .001), reason: reason);
            expect(rect.height, 56, reason: reason);
            expect(rect.center.dy, dock.center.dy, reason: reason);
            final icon = tester.getRect(
              find.descendant(of: item, matching: find.byType(Icon)),
            );
            final label = tester.getRect(
              find.descendant(of: item, matching: find.text(labels[index])),
            );
            expect(icon.bottom, lessThanOrEqualTo(label.top), reason: reason);
            expect(icon.center.dx, closeTo(rect.center.dx, .001));
            expect(label.center.dx, closeTo(rect.center.dx, .001));
            expect(item.hitTestable(), findsOneWidget, reason: reason);
            final semantics = tester.widget<Semantics>(
              find.descendant(
                of: item,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is Semantics &&
                      widget.properties.button == true &&
                      widget.properties.label == labels[index],
                ),
              ),
            );
            expect(semantics.properties.selected, index == 0, reason: reason);
          }
          final selectedIcon = tester.widget<Icon>(
            find.descendant(
              of: find.byKey(const ValueKey('messengerPrimaryNav-chats')),
              matching: find.byType(Icon),
            ),
          );
          final quietIcon = tester.widget<Icon>(
            find.descendant(
              of: find.byKey(const ValueKey('messengerPrimaryNav-activity')),
              matching: find.byType(Icon),
            ),
          );
          expect(selectedIcon.color, isNot(quietIcon.color), reason: reason);
          expect(
            find.descendant(
              of: navigation,
              matching: find.byIcon(Icons.search),
            ),
            findsNothing,
            reason: reason,
          );
          expect(tester.takeException(), isNull, reason: reason);
        }
      }
    });

    testWidgets('dock and compact scroll ends stay reachable at 320px', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      final entries = [
        for (var index = 0; index < 20; index++)
          ChatListEntry(
            id: ChatEntryId.local('Agent $index'),
            kind: ChatListEntryKind.localAgent,
            title: 'Agent $index',
            preview: 'Preview',
            createdAt: DateTime.utc(2025),
            lastActivity: DateTime.utc(2026),
            localMessageCount: 1,
          ),
      ];
      await pumpShell(
        tester,
        manager: manager,
        size: const Size(320, 700),
        localChatAdapterFactory: () => _StaticLocalChatListSource(entries),
      );
      await tester.pumpAndSettle();
      final dock = tester.getRect(
        find.byKey(const ValueKey('narrowShellNavigation')),
      );
      expect(dock, const Rect.fromLTRB(12, 636, 308, 692));
      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('chatListScroll')),
      );
      expect((list.padding as EdgeInsets).bottom, greaterThanOrEqualTo(76));
      final rowRects = [
        for (var index = 0; index < entries.length; index++)
          if (find.text('Agent $index').evaluate().isNotEmpty)
            tester.getRect(find.text('Agent $index')),
      ];
      expect(
        rowRects.any(
          (rect) => rect.bottom > dock.top && rect.top < dock.bottom,
        ),
        isTrue,
        reason: 'visible rows must continue underneath the glass dock',
      );
      final scrollable = tester.widget<Scrollable>(
        find.descendant(
          of: find.byKey(const ValueKey('chatListScroll')),
          matching: find.byType(Scrollable),
        ),
      );
      scrollable.controller!.jumpTo(
        scrollable.controller!.position.maxScrollExtent,
      );
      await tester.pumpAndSettle();
      final last = tester.getRect(find.text('Agent 19'));
      final fab = tester.getRect(
        find.byKey(const ValueKey('narrowShellNewChat')),
      );
      expect(last.bottom, lessThanOrEqualTo(fab.top));
      for (final id in ['activity', 'apps', 'chats']) {
        await tester.tap(
          find.byKey(ValueKey('messengerPrimaryNav-$id')).hitTestable(),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: id);
      }
      final returnedScrollable = tester.widget<Scrollable>(
        find.descendant(
          of: find.byKey(const ValueKey('chatListScroll')),
          matching: find.byType(Scrollable),
        ),
      );
      returnedScrollable.controller!.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('Agent 0').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dock clears the FAB while content scrolls underneath', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      tester.view.padding = const FakeViewPadding(bottom: 34);
      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.pumpAndSettle();

      final dock = tester.getRect(
        find.byKey(const ValueKey('narrowShellNavigation')),
      );
      final fab = find.byKey(const ValueKey('narrowShellNewChat'));
      final fabRect = tester.getRect(fab);
      final content = tester.getRect(find.byType(ChatListPanel));
      expect(dock.bottom, 802); // 844 - 34 SafeArea - 8 separation.
      expect(dock.height, 56);
      expect(
        content.bottom,
        greaterThan(dock.top),
        reason: 'conversation rows must scroll underneath the glass dock',
      );
      expect(fabRect.bottom, lessThanOrEqualTo(dock.top - 8));
      expect(fab.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dock selection animates once and honors reduced motion', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      final pill = find.byKey(const ValueKey('narrowShellSelectionPill'));
      // The first frame is already at Chats; there is no entrance animation.
      final initialPill = tester.getRect(pill);
      expect(initialPill.left, closeTo(59, .001));
      expect(initialPill.top, 784);
      expect(initialPill.width, closeTo(280 / 4 - 8, .001));
      expect(initialPill.bottom, 832);
      var animated = tester.widget<AnimatedPositioned>(pill);
      expect(animated.duration, const Duration(milliseconds: 200));
      expect(animated.curve, Curves.easeInOutCubic);

      Future<void> verify(String id, {required bool forward}) async {
        final previous = tester.getRect(pill);
        await tester.tap(find.byKey(ValueKey('messengerPrimaryNav-$id')));
        await tester.pump();
        expect(tester.getRect(pill), previous);
        var prior = previous;
        for (final elapsed in [50, 100, 200]) {
          await tester.pump(Duration(milliseconds: elapsed == 200 ? 100 : 50));
          final current = tester.getRect(pill);
          expect(current.width, closeTo(previous.width, .001));
          expect(
            forward ? current.left >= prior.left : current.left <= prior.left,
            isTrue,
            reason: '$id at $elapsed ms',
          );
          prior = current;
        }
        final item = tester.getRect(
          find.byKey(ValueKey('messengerPrimaryNav-$id')),
        );
        expect(prior.center.dx, closeTo(item.center.dx, .001));
        expect(
          find.byType(AppLauncherScreen),
          id == 'apps' ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      }

      await verify('activity', forward: true);
      await verify('apps', forward: true);
      await verify('chats', forward: false);

      await pumpShell(
        tester,
        manager: manager,
        size: const Size(390, 844),
        reducedMotion: true,
      );
      animated = tester.widget<AnimatedPositioned>(pill);
      expect(animated.duration, Duration.zero);
      for (final id in ['activity', 'apps', 'chats']) {
        await tester.tap(find.byKey(ValueKey('messengerPrimaryNav-$id')));
        await tester.pump();
        final item = tester.getRect(
          find.byKey(ValueKey('messengerPrimaryNav-$id')),
        );
        expect(tester.getRect(pill).center.dx, closeTo(item.center.dx, .001));
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('bottom navigation opens Apps and the live Activity surface', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));

      await tester.tap(find.text('Apps'));
      await tester.pumpAndSettle();
      expect(find.byType(AppLauncherScreen), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);
      expect(
        find.byKey(const ValueKey('narrowShellNavigation')),
        findsOneWidget,
      );

      await tester.tap(find.text('Activity'));
      await tester.pumpAndSettle();
      expect(find.text('Recent'), findsWidgets);
      expect(find.byType(AppLauncherScreen), findsNothing);
      expect(
        find.byKey(const ValueKey('narrowShellNavigation')),
        findsOneWidget,
      );
    });

    testWidgets('narrow Activity opens detail, returns, then opens its chat', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.tap(find.text('Activity'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('activitySession-design-session')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ActivityDetailPanel), findsOneWidget);
      expect(find.byKey(const ValueKey('activityBack')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('activityBack')));
      await tester.pumpAndSettle();
      expect(find.byType(ActivityListPanel), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('activitySession-design-session')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('activityOpenChat')));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(manager.activeId, 'design-session');
    });

    testWidgets('conversation tap pushes the full chat and back returns', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _listedService(env));

      await pumpShell(
        tester,
        manager: manager,
        sessionNamesStore: SessionNamesStore.inMemory({
          'design-session': 'Fa 2.0 redesign',
        }),
        size: const Size(390, 844),
      );
      await tester.tap(find.text('Fa 2.0 redesign'));
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('narrowShellNavigation')), findsNothing);
      expect(manager.activeId, 'design-session');

      await tester.tap(find.byType(BackButton).first);
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.byType(ChatListPanel), findsOneWidget);
      expect(find.text('Fa 2.0 redesign'), findsOneWidget);
    });

    testWidgets('narrow chat route folds into the wide shell on resize', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _listedService(env));

      await pumpShell(
        tester,
        manager: manager,
        sessionNamesStore: SessionNamesStore.inMemory({
          'design-session': 'Fa 2.0 redesign',
        }),
        size: const Size(390, 844),
      );
      await tester.tap(find.text('Fa 2.0 redesign'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byType(ChatListPanel), findsNothing);

      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byType(ChatListPanel), findsOneWidget);
      expect(find.byKey(const ValueKey('narrowShellNavigation')), findsNothing);
      expect(
        find.byKey(const ValueKey('wideShellSidebarToggle')),
        findsOneWidget,
      );
    });

    testWidgets('Fa brand tap opens the active chat', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('wideShellFaBrand')));
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(manager.activeId, 'design-session');
    });

    testWidgets('model chip long-press opens Models settings', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('wideShellFaBrand')));
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const ValueKey('wideModelChip')));
      await tester.pumpAndSettle();

      expect(find.byType(ModelsSettingsPage), findsOneWidget);
    });

    testWidgets('Fa brand long-press mints and activates one session', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.longPress(find.byKey(const ValueKey('wideShellFaBrand')));
      await tester.pumpAndSettle();

      expect(manager.sessions, hasLength(2));
      expect(manager.activeId, isNot('design-session'));
    });

    testWidgets('reveal active chat from Apps pushes one narrow chat route', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.tap(find.text('Apps'));
      await tester.pumpAndSettle();
      FaChatHost.revealActiveChat!();
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(manager.activeId, 'design-session');
    });

    testWidgets('reveal active chat reuses an already visible chat route', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('wideShellFaBrand')));
      await tester.pumpAndSettle();
      await FaChatHost.revealActiveChat!();
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      await tester.tap(find.byType(BackButton).first);
      await tester.pumpAndSettle();
    });

    testWidgets('New chat keeps the session-folder flow', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      final newButton = find.byKey(const ValueKey('narrowShellNewChat'));
      expect(tester.getSize(newButton), const Size.square(52));
      final surface = tester.widget<FaSurface>(
        find.descendant(of: newButton, matching: find.byType(FaSurface)),
      );
      expect(surface.circular, isTrue);
      expect(surface.glass, isTrue);
      expect(surface.useBackdropGroup, isTrue);
      final icon = tester.widget<Icon>(
        find.descendant(of: newButton, matching: find.byType(Icon)),
      );
      expect(icon.color, const Color(0xFF3F8FF7));
      await tester.tap(find.byKey(const ValueKey('narrowShellNewChat')));
      await tester.pumpAndSettle();

      expect(find.byType(SimpleDialog), findsOneWidget);
      expect(find.text('New session — folder'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(manager.sessions.length, 1);
    });

    testWidgets('wide keeps the sidebar and inline chat', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(1280, 800));

      expect(
        find.byKey(const ValueKey('messengerPrimaryNav-activity')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('messengerPrimaryNav-apps')),
        findsOneWidget,
      );
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('narrowShellNavigation')), findsNothing);
      expect(find.byType(AppLauncherScreen), findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
    });
  });

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
        expect(search, findsOneWidget, reason: section);
        expect(newButton, findsOneWidget, reason: section);
        // One shared component: both slots are descendants of the ONE
        // MessengerSectionHeader the shell builds for every section.
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
