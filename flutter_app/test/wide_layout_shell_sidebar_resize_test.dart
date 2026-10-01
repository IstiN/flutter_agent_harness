@TestOn('vm')
library;

import 'dart:async';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/main.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_ui_prefs_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
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

/// A hosted (relay-like) service whose new-session reset hangs on a gate:
/// holds the brand mint in flight so the single-flight guard (E3) can be
/// pinned deterministically. The reset action is the mint's first await.
final class _GatedRelayService extends AgentService {
  _GatedRelayService({
    required super.agent,
    required super.env,
    required super.sessionsRoot,
    required super.config,
  });

  final Completer<void> gate = Completer<void>();
  int resets = 0;

  @override
  Future<void> Function()? get newSessionAction => () async {
    resets++;
    await gate.future;
  };
}

/// A hosted (relay-like) service whose new-session reset always throws:
/// the brand mint's first await fails exactly where a clone/initialize
/// failure would (review #1144 follow-up).
final class _FailingRelayService extends AgentService {
  _FailingRelayService({
    required super.agent,
    required super.env,
    required super.sessionsRoot,
    required super.config,
  });

  @override
  Future<void> Function()? get newSessionAction =>
      () async => throw StateError('mint exploded');
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
  });

  /// Boots the wide shell (via the real home-screen dispatch). The shell
  /// lazily loads its own prefs store from the manager's env — assertions
  /// re-read the store from the env the same way.
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

  double handleX(WidgetTester tester) =>
      tester.getTopLeft(find.byKey(kSidebarDragHandleKey)).dx;

  testWidgets('the divider drag resizes the sessions sidebar, clamps to '
      'the 220-480 range, and persists on release (issue #426 item 4)', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', _fakeService(env));

    await pumpShell(tester, manager: manager);
    // Stock 240: the handle sits exactly at the sidebar's right edge.
    expect(handleX(tester), closeTo(240, 0.5));

    // Drag right: the sidebar grows with the pointer.
    await tester.drag(find.byKey(kSidebarDragHandleKey), const Offset(90, 0));
    await tester.pumpAndSettle();
    expect(handleX(tester), closeTo(330, 0.5));
    // The settled gesture wrote the store (the shell owns its instance —
    // verify through a fresh load, like a second reader would).
    expect(
      (await SessionUiPrefsStore.load(env)).sidebarWidth,
      closeTo(330, 0.5),
    );

    // A huge drag clamps at 480, not past it.
    await tester.drag(find.byKey(kSidebarDragHandleKey), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(handleX(tester), closeTo(SessionUiPrefsStore.maxSidebarWidth, 0.5));
    expect(
      (await SessionUiPrefsStore.load(env)).sidebarWidth,
      SessionUiPrefsStore.maxSidebarWidth,
    );

    // And left, down to the 220 floor.
    await tester.drag(find.byKey(kSidebarDragHandleKey), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(handleX(tester), closeTo(SessionUiPrefsStore.minSidebarWidth, 0.5));
    expect(
      (await SessionUiPrefsStore.load(env)).sidebarWidth,
      SessionUiPrefsStore.minSidebarWidth,
    );
  });

  testWidgets('the persisted width survives an app restart (issue #426 '
      'item 4)', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', _fakeService(env));
    await (await SessionUiPrefsStore.load(env)).setSidebarWidth(400);

    await pumpShell(tester, manager: manager);
    // The boot adopts the stored width — the handle opens at 400.
    await tester.pumpAndSettle();
    expect(handleX(tester), closeTo(400, 0.5));
  });

  testWidgets('a width stored out of range is clamped on load, never '
      'wedges the layout', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', _fakeService(env));
    await env.writeFile(
      '${env.cwd}/${SessionUiPrefsStore.fileName}',
      '{"version":1,"expandedParents":[],"collapsedParents":[],'
          '"sidebarWidth":5000}',
    );

    await pumpShell(tester, manager: manager);
    await tester.pumpAndSettle();
    expect(handleX(tester), closeTo(SessionUiPrefsStore.maxSidebarWidth, 0.5));
  });

  group('Fa brand long-press (issue #864, wide surface)', () {
    testWidgets('a long-press mints exactly one session and activates it '
        '(AC2)', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('fake-session', _fakeService(env));

      await pumpShell(tester, manager: manager);
      await tester.longPress(find.byKey(const ValueKey('wideShellFaBrand')));
      await tester.pumpAndSettle();

      expect(manager.sessions, hasLength(2));
      expect(manager.activeId, isNot('fake-session'));
    });

    testWidgets('a second long-press while the mint is in flight is dropped '
        '(E3)', (tester) async {
      final env = MemoryExecutionEnv();
      final gated = _GatedRelayService(
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
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('fake-session', gated);

      await pumpShell(tester, manager: manager);
      // First long-press: the mint hangs on the gated relay reset.
      await tester.longPress(find.byKey(const ValueKey('wideShellFaBrand')));
      // Second long-press while the first is in flight: dropped by the
      // single-flight guard.
      await tester.longPress(find.byKey(const ValueKey('wideShellFaBrand')));
      gated.gate.complete();
      await tester.pumpAndSettle();

      // Exactly ONE trigger went through: one relay reset, no clone mint.
      expect(gated.resets, 1);
      expect(manager.sessions, hasLength(1));
      expect(manager.activeId, 'fake-session');
    });

    testWidgets('a failed mint shows the error snack instead of leaking an '
        'unhandled zone error; nothing mints, active stays (review #1144 '
        'follow-up)', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession(
          'fake-session',
          _FailingRelayService(
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
          ),
        );

      await pumpShell(tester, manager: manager);
      // Real gesture entry: pre-fix this long-press surfaced the failure
      // as an unhandled zone error (unawaited(...) with no catch).
      await tester.longPress(find.byKey(const ValueKey('wideShellFaBrand')));
      await tester.pumpAndSettle();

      // The messenger presents the same snack in every Scaffold the wide
      // shell has registered — at least one must carry the failure text.
      expect(find.byType(SnackBar), findsWidgets);
      expect(find.text("Couldn't create a new session."), findsWidgets);
      expect(manager.sessions, hasLength(1));
      expect(manager.activeId, 'fake-session');
    });
  });
}
