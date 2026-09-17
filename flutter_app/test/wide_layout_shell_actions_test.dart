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
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

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
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) =>
              faHomeScreen(context: context, manager: manager),
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

    await pumpShell(tester, manager: manager);
    final ghost = (await manager.listPersistedSessions()).single;
    // The unnamed row shows its derived date title — computed with the
    // same formatter the sidebar uses.
    final ghostTitle = DateFormat.MMMd(
      'en',
    ).add_Hm().format(ghost.createdAt.toLocal());
    await tester.tap(find.text(ghostTitle).first);
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
}
