// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/apps/fa_work_bar.dart';
import 'package:fa/apps/session_chat_sheet.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/chat_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      stream.push(
        ErrorEvent(
          reason: StopReason.aborted,
          error: partial.copyWith(
            stopReason: StopReason.aborted,
            errorMessage: 'Operation aborted',
          ),
        ),
      );
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
  SessionNamesStore? namesStore,
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
      home: Scaffold(
        body: SessionChatSheet(manager: manager, sessionNamesStore: namesStore),
      ),
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
  // Date-derived session titles format through intl — its date symbols are
  // not compiled in (main.dart loads them for the app locales).
  setUpAll(() async {
    await initializeDateFormatting('en');
  });

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

    testWidgets('a persisted page opened by swiping stays put (no bounce)', (
      tester,
    ) async {
      // Seed an on-disk session: a chat from "yesterday" that is NOT live.
      // (runAsync: the fake stream's idle completion needs the real event
      // loop, not FakeAsync pumps.)
      final env = MemoryExecutionEnv();
      final seed = _fakeService(env);
      late final SessionMetadata persistedMeta;
      await tester.runAsync(() async {
        await seed.initialize();
        await seed.sendText('old chat');
        await seed.waitForIdle();
        persistedMeta = (await seed.listSessions()).single;
      });
      seed.dispose();

      final live = _fakeService(env);
      addTearDown(live.dispose);
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('sess-live', live);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SessionChatSheet(manager: manager)),
        ),
      );
      await tester.pumpAndSettle();
      await _expand(tester);
      // Two pages: the live session, then the persisted one on the right.
      expect(find.byKey(_pagerKey), findsOneWidget);

      // Swipe to the rightmost (persisted) page: it opens lazily and the
      // pager must SETTLE there — the old bug duplicated the session
      // (live + persisted) and bounced the pager back a page.
      await tester.fling(find.byKey(_pagerKey), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(manager.activeId, persistedMeta.id);
      expect(manager.sessions, hasLength(2));
      // Still the rightmost page: no jump back to page 0.
      expect(find.text('old chat'), findsOneWidget);

      // Swiping right again is a no-op (it IS the last page).
      await tester.fling(find.byKey(_pagerKey), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(manager.activeId, persistedMeta.id);
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

    testWidgets('menu: Rename session saves a custom title into the header', (
      tester,
    ) async {
      final namesStore = SessionNamesStore.inMemory();
      await _pumpSheet(tester, namesStore: namesStore);
      await _expand(tester);
      expect(find.text('session sess-b'), findsOneWidget);

      await tester.tap(find.byKey(_menuKey));
      await tester.pumpAndSettle();
      expect(find.text('Rename session'), findsOneWidget);
      await tester.tap(find.text('Rename session'));
      await tester.pumpAndSettle();

      // The shared rename dialog (same as the sidebar's): empty prefilled
      // field with the derived name as the hint.
      final dialogField = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(find.text('Rename session'), findsOneWidget);
      expect(tester.widget<TextField>(dialogField).controller!.text, '');
      await tester.enterText(dialogField, 'Dice rolling');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // The header updates live through the store.
      expect(namesStore.titleFor('sess-b'), 'Dice rolling');
      expect(find.text('Dice rolling'), findsOneWidget);
      expect(find.text('session sess-b'), findsNothing);
    });

    testWidgets('menu: Rename Clear restores the derived name', (tester) async {
      final namesStore = SessionNamesStore.inMemory({'sess-b': 'Dice rolling'});
      await _pumpSheet(tester, namesStore: namesStore);
      await _expand(tester);
      expect(find.text('Dice rolling'), findsOneWidget);

      await tester.tap(find.byKey(_menuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename session'));
      await tester.pumpAndSettle();
      // Reopening prefills the custom title.
      final dialogField = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(
        tester.widget<TextField>(dialogField).controller!.text,
        'Dice rolling',
      );
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();

      expect(namesStore.titleFor('sess-b'), isNull);
      expect(find.text('session sess-b'), findsOneWidget);
    });

    testWidgets('menu: Copy session puts the Markdown transcript on the '
        'clipboard', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await _pumpSheet(
        tester,
        messages: {
          'sess-b': [
            FahChatMessage(role: 'user', content: 'build me a dice app'),
            FahChatMessage(role: 'assistant', content: 'Done — Dice Roller.'),
          ],
        },
      );
      await _expand(tester);

      await tester.tap(find.byKey(_menuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy session'));
      await tester.pumpAndSettle();

      expect(copied, contains('## You\nbuild me a dice app'));
      expect(copied, contains('## Fa\nDone — Dice Roller.'));
    });

    testWidgets('the header derives a date-based title from the session '
        'creation time when it is reachable', (tester) async {
      // A session persisted on disk carries its creation time in the file
      // header (runAsync: session setup needs the real event loop).
      final env = MemoryExecutionEnv();
      final service = _fakeService(env);
      addTearDown(service.dispose);
      late final String sessionId;
      await tester.runAsync(() async {
        await service.initialize();
        sessionId = service.currentSessionId!;
      });
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession(sessionId, service);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SessionChatSheet(manager: manager)),
        ),
      );
      await tester.pumpAndSettle();
      await _expand(tester);

      // "Jul 31 12:30" — intl month-day + 24h time, no `session <id8>`
      // anywhere.
      final dateTitle = RegExp(r'^\w{3}\.? \d{1,2},? \d{2}:\d{2}$');
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && w.data != null && dateTitle.hasMatch(w.data!),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('session '), findsNothing);
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
