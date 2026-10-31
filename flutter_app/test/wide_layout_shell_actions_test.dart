@TestOn('vm')
/// Widget tests for the wide shell's session actions (issue #561): the
/// new-session folder dialog, the persisted-session open degrading on a
/// ghost/transcript-less entry, and the session info dialog contents.
/// Fakes mirror `wide_layout_shell_sidebar_resize_test.dart`.
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/main.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/sidebar_nav_item.dart';
import 'package:fa/ui/widgets/sidebar_sessions_list.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa_ui/fa_ui.dart' show FaChatHost;
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

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    required FlutterSessionManager manager,
    SessionNamesStore? sessionNamesStore,
    Size size = const Size(1280, 800),
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => faHomeScreen(
            context: context,
            manager: manager,
            sessionNamesStore: sessionNamesStore,
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
    await tester.tap(find.byIcon(Icons.add_circle_outline).first);
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
    // The composer's project chip (its label is the folder state) opens
    // the session info dialog.
    await tester.tap(find.text('Personal').last);
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
    expect(find.text('CHATS'), findsOneWidget);
    expect(find.text('Search chats'), findsOneWidget);
    expect(find.text('New chat'), findsOneWidget);
    expect(find.text('SESSIONS'), findsNothing);
    expect(find.text('Search sessions'), findsNothing);
    final chats = tester.widget<SidebarNavItem>(
      find.widgetWithText(SidebarNavItem, 'Chats'),
    );
    expect(chats.selected, isTrue);
    await tester.pump(const Duration(milliseconds: 100));
  });

  for (final size in const [Size(800, 900), Size(1440, 900)]) {
    testWidgets('Apps is a selected full center surface at ${size.width}', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('fake-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: size);
      expect(find.byType(AppLauncherScreen), findsNothing);

      await tester.tap(find.widgetWithText(SidebarNavItem, 'Apps'));
      await tester.pumpAndSettle();

      expect(find.byType(AppLauncherScreen), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);
      expect(tester.getRect(find.byType(AppLauncherScreen)).right, size.width);
      final apps = tester.widget<SidebarNavItem>(
        find.widgetWithText(SidebarNavItem, 'Apps'),
      );
      expect(apps.selected, isTrue);
    });
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
    final apps = tester.widget<SidebarNavItem>(
      find.widgetWithText(SidebarNavItem, 'Apps'),
    );
    expect(apps.selected, isTrue);
  });

  testWidgets('Activity explains its empty state', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');

    await pumpShell(tester, manager: manager);
    await tester.tap(find.widgetWithText(SidebarNavItem, 'Activity'));
    await tester.pumpAndSettle();

    expect(find.text('No session activity yet.'), findsOneWidget);
    expect(find.text('Running'), findsNothing);
    expect(find.text('Recent'), findsNothing);
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
    await tester.tap(find.widgetWithText(SidebarNavItem, 'Activity'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('wideActivitySession-running-session')),
        matching: find.text('Build release'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('wideActivitySession-recent-session')),
        matching: find.text('Write docs'),
      ),
      findsOneWidget,
    );
    expect(find.text('Running'), findsNothing);
    expect(find.text('Recent'), findsOneWidget);

    runningService.isStreaming = true;
    runningService.notifyListeners();
    await tester.pump();

    expect(find.text('Running'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('wideActivitySession-running-session')),
        matching: find.text('Build release'),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('wideActivitySession-running-session')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(manager.activeId, 'running-session');
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(
      find.byKey(const ValueKey('wideActivitySession-running-session')),
      findsNothing,
    );
    final chats = tester.widget<SidebarNavItem>(
      find.widgetWithText(SidebarNavItem, 'Chats'),
    );
    expect(chats.selected, isTrue);
    runningService.isStreaming = false;
    runningService.notifyListeners();
    await tester.pumpAndSettle();
  });

  group('narrow messenger home', () {
    testWidgets('boots to the Chats conversation list, not the launcher', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(
        tester,
        manager: manager,
        sessionNamesStore: SessionNamesStore.inMemory({
          'design-session': 'Fa 2.0 redesign',
        }),
        size: const Size(390, 844),
      );

      expect(find.byType(WideLayoutShell), findsOneWidget);
      expect(find.byType(SidebarSessionsList), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('Fa 2.0 redesign'), findsOneWidget);
      expect(find.text('Search chats'), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.byType(AppLauncherScreen), findsNothing);
      expect(find.byKey(const ValueKey('narrowShellNewChat')), findsOneWidget);
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
      expect(find.byType(NavigationBar), findsOneWidget);

      await tester.tap(find.text('Activity'));
      await tester.pumpAndSettle();
      expect(find.text('Recent'), findsOneWidget);
      expect(find.byType(AppLauncherScreen), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('conversation tap pushes the full chat and back returns', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

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
      expect(find.byType(NavigationBar), findsNothing);
      expect(manager.activeId, 'design-session');

      await tester.tap(find.byType(BackButton).first);
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.byType(SidebarSessionsList), findsOneWidget);
      expect(find.text('Fa 2.0 redesign'), findsOneWidget);
    });

    testWidgets('New chat keeps the session-folder flow', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
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

      expect(find.byType(SidebarNavItem), findsWidgets);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(AppLauncherScreen), findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
    });
  });
}
