// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/apps/fa_work_bar.dart';
import 'package:fa/apps/session_chat_sheet.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/chat_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// A hung stream honoring aborts (the fa_work_bar_test.dart pattern): the
/// provider stream stays open until aborted, so `isStreaming` stays true.
StreamFunction _hungResponse() {
  fn(Model model, dynamic context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final partial = AssistantMessage(
      content: const [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime(2026),
    );
    stream.push(StartEvent(partial: partial));
    cancelToken?.onCancel.then((_) {
      stream.push(ErrorEvent(reason: StopReason.aborted, error: partial));
      stream.end();
    });
    return stream; // stays open until aborted
  }

  return fn;
}

AgentService _fakeService(ExecutionEnv env, [StreamFunction? streamFunction]) {
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
      systemPrompt: 'You are fah.',
      streamFunction: streamFunction ?? _singleTextResponse('ok'),
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

const _faButtonKey = ValueKey('sessionChatFaButton');
const _pagerKey = ValueKey('sessionChatPager');
const _menuKey = ValueKey('sessionChatMenu');

class _Harness {
  _Harness(this.manager, this.services);

  final FlutterSessionManager manager;

  /// id → service, for per-session message seeding.
  final Map<String, AgentService> services;
}

/// Pumps the sheet with two sessions; the second one (`sess-b`) is active.
Future<_Harness> _pumpSheet(
  WidgetTester tester, {
  Map<String, List<FahChatMessage>>? messages,
}) async {
  final env = MemoryExecutionEnv();
  final services = {'sess-a': _fakeService(env), 'sess-b': _fakeService(env)};
  messages?.forEach((id, seeded) => services[id]!.messages.addAll(seeded));
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('sess-a', services['sess-a']!)
    ..addSession('sess-b', services['sess-b']!);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SessionChatSheet(manager: manager)),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(manager, services);
}

Future<void> _expand(WidgetTester tester) async {
  // The mini bar has no handle (it belongs to the expanded sheet) — a tap
  // anywhere on the bar opens the sheet; the drag zone is a stable target.
  await tester.tap(find.byKey(const ValueKey('sessionChatMiniDragZone')));
  await tester.pumpAndSettle();
}

/// Drags the mini bar down into the collapsed round-Fa-icon state.
Future<void> _collapseToIcon(WidgetTester tester) async {
  await tester.drag(
    find.byKey(const ValueKey('sessionChatMiniDragZone')),
    const Offset(0, 400),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('SessionChatSheet', () {
    testWidgets('starts as the mini bar by default; tap expands the sheet', (
      tester,
    ) async {
      await _pumpSheet(tester);
      // The MINI bar is the default resting state: composer ready, no
      // pager, no round icon.
      expect(find.byType(ChatComposer), findsOneWidget);
      expect(find.byKey(_pagerKey), findsNothing);
      expect(find.byKey(_faButtonKey), findsNothing);

      await _expand(tester);
      expect(find.byKey(_pagerKey), findsOneWidget);
      expect(find.byKey(_menuKey), findsOneWidget);
      expect(find.byType(ChatComposer), findsOneWidget);
      expect(find.byKey(_faButtonKey), findsNothing);
      // The active session's derived title shows in the header.
      expect(find.text('session sess-b'), findsOneWidget);
    });

    testWidgets('mini bar shows the FaWorkBar while streaming', (tester) async {
      final env = MemoryExecutionEnv();
      final service = _fakeService(env, _hungResponse());
      addTearDown(service.dispose);
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('sess-h', service);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SessionChatSheet(manager: manager)),
        ),
      );
      await tester.pumpAndSettle();
      // Mini bar by default — no round icon.
      expect(find.byKey(_faButtonKey), findsNothing);

      await tester.runAsync(() async {
        unawaited(service.sendText('long task'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(service.isStreaming, isTrue);

      // The status row appears inside the mini bar; the work bar's orbit
      // repeats forever, so pump timed frames instead of pumpAndSettle.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(FaWorkBar), findsOneWidget);
      expect(find.byKey(_faButtonKey), findsNothing);

      await tester.tap(find.byType(FaWorkBar));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(_pagerKey), findsOneWidget);
    });

    testWidgets('the icon auto-grows to the mini bar when the stream starts', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final service = _fakeService(env, _hungResponse());
      addTearDown(service.dispose);
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('sess-h', service);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SessionChatSheet(manager: manager)),
        ),
      );
      await tester.pumpAndSettle();
      // Collapse to the round icon first, then start a stream.
      await _collapseToIcon(tester);
      expect(find.byKey(_faButtonKey), findsOneWidget);

      await tester.runAsync(() async {
        unawaited(service.sendText('long task'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(service.isStreaming, isTrue);

      // The stream-start auto-grow animates the panel to the mini state
      // (260 ms); pump timed frames (the orbit animation never settles).
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(FaWorkBar), findsOneWidget);
      expect(find.byType(ChatComposer), findsOneWidget);
      expect(find.byKey(_faButtonKey), findsNothing);
    });

    testWidgets('the pager switches the active session', (tester) async {
      final harness = await _pumpSheet(
        tester,
        messages: {
          'sess-a': [FahChatMessage(role: 'user', content: 'first session')],
          'sess-b': [FahChatMessage(role: 'user', content: 'second session')],
        },
      );
      expect(harness.manager.activeId, 'sess-b');
      await _expand(tester);
      expect(find.text('second session'), findsOneWidget);

      // Swipe left → page 2 (sess-a) → the manager switches over.
      await tester.fling(find.byKey(_pagerKey), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(harness.manager.activeId, 'sess-a');
      expect(find.text('first session'), findsOneWidget);
      expect(find.text('session sess-a'), findsOneWidget);
    });

    testWidgets('menu: New session creates and activates a fresh session', (
      tester,
    ) async {
      final harness = await _pumpSheet(tester);
      await _expand(tester);
      await tester.tap(find.byKey(_menuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New session'));
      await tester.pumpAndSettle();

      expect(harness.manager.sessions, hasLength(3));
      final activeId = harness.manager.activeId!;
      expect(activeId, isNot('sess-b'));
      // The new session is empty and the pager shows its page.
      expect(find.text('Nothing here yet — ask Fa anything.'), findsOneWidget);
    });

    testWidgets('menu: Open full chat pushes the ChatScreen', (tester) async {
      await _pumpSheet(tester);
      await _expand(tester);
      await tester.tap(find.byKey(_menuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open full chat'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
    });

    testWidgets('menu: Collapse returns to the Fa button', (tester) async {
      await _pumpSheet(tester);
      await _expand(tester);
      await tester.tap(find.byKey(_menuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Collapse chat'));
      await tester.pumpAndSettle();
      expect(find.byKey(_pagerKey), findsNothing);
      expect(find.byKey(_faButtonKey), findsOneWidget);
    });

    testWidgets('pull-down collapses: sheet → mini bar → round icon', (
      tester,
    ) async {
      await _pumpSheet(tester);
      await _expand(tester);

      // First pull: the sheet settles into the mini bar (composer stays,
      // pager gone, no round icon).
      await tester.drag(
        find.byKey(const ValueKey('sessionChatSheetHandle')),
        const Offset(0, 400),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_pagerKey), findsNothing);
      expect(find.byKey(_faButtonKey), findsNothing);
      expect(find.byType(ChatComposer), findsOneWidget);

      // Second pull: collapses to the round Fa button (the mini bar has no
      // handle — drag its body).
      await tester.drag(
        find.byKey(const ValueKey('sessionChatMiniDragZone')),
        const Offset(0, 400),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_faButtonKey), findsOneWidget);
    });

    testWidgets('fling DOWN from the sheet stops at the mini bar', (
      tester,
    ) async {
      await _pumpSheet(tester);
      await _expand(tester);
      expect(find.byKey(_pagerKey), findsOneWidget);

      // A fast swipe down from the full sheet settles into the mini bar —
      // it must NOT skip straight to the round icon.
      await tester.fling(
        find.byKey(const ValueKey('sessionChatSheetHandle')),
        const Offset(0, 300),
        1200,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_pagerKey), findsNothing);
      expect(find.byType(ChatComposer), findsOneWidget);
      expect(find.byKey(_faButtonKey), findsNothing);
    });

    testWidgets('fling DOWN from the mini bar settles into the icon', (
      tester,
    ) async {
      await _pumpSheet(tester);
      expect(find.byType(ChatComposer), findsOneWidget);

      await tester.fling(
        find.byKey(const ValueKey('sessionChatMiniDragZone')),
        const Offset(0, 300),
        1200,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_faButtonKey), findsOneWidget);
      expect(find.byType(ChatComposer), findsNothing);
    });

    testWidgets('a tap on the icon opens the MINI bar (not the sheet)', (
      tester,
    ) async {
      await _pumpSheet(tester);
      await _collapseToIcon(tester);
      expect(find.byKey(_faButtonKey), findsOneWidget);

      await tester.tap(find.byKey(_faButtonKey));
      await tester.pumpAndSettle();
      expect(find.byType(ChatComposer), findsOneWidget);
      expect(find.byKey(_pagerKey), findsNothing);
      expect(find.byKey(_faButtonKey), findsNothing);
    });

    testWidgets('fling UP from the icon stops at the mini bar', (tester) async {
      await _pumpSheet(tester);
      await _collapseToIcon(tester);
      expect(find.byKey(_faButtonKey), findsOneWidget);

      await tester.fling(find.byKey(_faButtonKey), const Offset(0, -300), 1200);
      await tester.pumpAndSettle();
      expect(find.byType(ChatComposer), findsOneWidget);
      expect(find.byKey(_pagerKey), findsNothing);
      expect(find.byKey(_faButtonKey), findsNothing);
    });

    testWidgets('the composer sends to the active session', (tester) async {
      final harness = await _pumpSheet(tester);
      await _expand(tester);
      await tester.enterText(find.byType(TextField).last, 'hello Fa');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      final messages = harness.services['sess-b']!.messages;
      expect(messages.first.role, 'user');
      expect(messages.first.content, 'hello Fa');
    });
  });
}
