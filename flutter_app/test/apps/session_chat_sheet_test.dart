// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/apps/session_chat_sheet.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/apps_mode_store.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/session_search_field.dart';
import 'package:fa/ui/widgets/sidebar_sessions_list.dart';
import 'package:fa/ui/widgets/chat_composer.dart';
import 'package:fa_ui/fa_ui.dart' show FaAttachGlyph, TrajectoryScreen;
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

/// A hosted (relay-like) service: its [openSessionAction] records the
/// dispatched session ids, like the extension panel's RelayAgentService.
final class _RelayBackedService extends AgentService {
  _RelayBackedService(
    ExecutionEnv env,
    this.openedIds, {
    required super.agent,
    required super.sessionsRoot,
    super.config,
  }) : super(env: env);

  final List<String> openedIds;

  @override
  Future<void> Function(String sessionId)? get openSessionAction =>
      (id) async => openedIds.add(id);
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
      systemPrompt: 'You are Fa.',
      streamFunction: streamFunction ?? _singleTextResponse('ok'),
      toolRegistry: ToolRegistry(const []),
    ),
    watchExternalSessions: false,
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

/// Fake [AsrApi] — widget tests never touch the real method channel.
final class _FakeAsrApi implements AsrApi {
  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> requestAccess() async => true;

  @override
  Future<void> startRecording() async {}

  @override
  Future<AsrRecording> stopRecording() async =>
      (path: '/tmp/fah-mic-test.m4a', durationMs: 5000, sampleRate: 44100);

  @override
  Future<Uint8List> readRecording(String path) async =>
      Uint8List.fromList(const [1, 2, 3]);
}

const _barKey = ValueKey('sessionChatBar');
const _drawerButtonKey = ValueKey('sessionChatDrawerButton');
const _drawerKey = ValueKey('sessionChatDrawer');
const _panelKey = ValueKey('sessionChatPanel');
const _panelSessionsKey = ValueKey('sessionChatPanelSessions');
const _handleKey = ValueKey('sessionChatSheetHandle');
const _menuKey = ValueKey('sessionChatMenu');
const _newSessionKey = ValueKey('sessionChatNewSession');

class _Harness {
  _Harness(this.manager, this.services, this.env);

  final FlutterSessionManager manager;

  /// id → service, for per-session message seeding.
  final Map<String, AgentService> services;

  /// The in-memory env backing the manager (persisted-store assertions).
  final MemoryExecutionEnv env;
}

/// Pumps the sheet with two sessions; the second one (`sess-b`) is active.
/// [restoreAppsMode] mirrors the production flag (issue #224) — the
/// persisted apps↔chat mode is loaded on mount.
Future<_Harness> _pumpSheet(
  WidgetTester tester, {
  Map<String, List<FahChatMessage>>? messages,
  SessionNamesStore? namesStore,
  bool restoreAppsMode = false,
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
        body: SessionChatSheet(
          manager: manager,
          sessionNamesStore: namesStore,
          asr: _FakeAsrApi(),
          restoreAppsMode: restoreAppsMode,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(manager, services, env);
}

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(find.byKey(_drawerButtonKey));
  await tester.pumpAndSettle();
}

/// Opens the panel on a session through the real user flow: drawer → row.
Future<void> _openPanelViaDrawer(WidgetTester tester, String id) async {
  await _openDrawer(tester);
  await tester.tap(find.byKey(ValueKey('sessionChatDrawerEntry:$id')));
  await tester.pumpAndSettle();
}

void main() {
  // Date-derived session titles format through intl — its date symbols are
  // not compiled in (main.dart loads them for the app locales).
  setUpAll(() async {
    await initializeDateFormatting('en');
  });

  group('SessionChatSheet', () {
    testWidgets('rests as the input bar: composer + sessions button, no '
        'panel, no drawer', (tester) async {
      await _pumpSheet(tester);
      expect(find.byKey(_barKey), findsOneWidget);
      expect(find.byType(ChatComposer), findsOneWidget);
      expect(find.byKey(_drawerButtonKey), findsOneWidget);
      expect(find.byKey(_panelKey), findsNothing);
      expect(find.byKey(_drawerKey), findsNothing);
    });

    testWidgets('the sessions button opens the drawer listing live sessions; '
        'a scrim tap closes it', (tester) async {
      await _pumpSheet(tester);
      await _openDrawer(tester);
      expect(find.byKey(_drawerKey), findsOneWidget);
      expect(find.byKey(_newSessionKey), findsOneWidget);
      // Both live sessions listed (the same SessionTile the sidebar uses —
      // live rows carry a date-derived title, so match by key).
      expect(
        find.byKey(const ValueKey('sessionChatDrawerEntry:sess-a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sessionChatDrawerEntry:sess-b')),
        findsOneWidget,
      );

      // A tap on the exposed grid area (the scrim) dismisses the drawer.
      await tester.tapAt(const Offset(700, 100));
      await tester.pumpAndSettle();
      expect(find.byKey(_drawerKey), findsNothing);
      expect(find.byKey(_drawerButtonKey), findsOneWidget);
    });

    testWidgets('a drawer row switches the session and opens the panel; the '
        'leading icon becomes the attach button', (tester) async {
      final harness = await _pumpSheet(
        tester,
        messages: {
          'sess-a': [FahChatMessage(role: 'user', content: 'first session')],
          'sess-b': [FahChatMessage(role: 'user', content: 'second session')],
        },
      );
      expect(harness.manager.activeId, 'sess-b');

      await _openPanelViaDrawer(tester, 'sess-a');
      expect(harness.manager.activeId, 'sess-a');
      expect(find.byKey(_panelKey), findsOneWidget);
      expect(find.byKey(_drawerKey), findsNothing);
      expect(find.text('first session'), findsOneWidget);
      // Header title tracks the switch.
      expect(find.text('session sess-a'), findsOneWidget);
      // The sessions button turned into the composer's attach button.
      expect(find.byKey(_drawerButtonKey), findsNothing);
      expect(find.byType(FaAttachGlyph), findsOneWidget);
    });

    testWidgets('a hosted drawer row re-dispatches through the relay '
        'instead of a silent local switchTo', (tester) async {
      // Hosted surfaces (extension panel): the local slot only holds the
      // boot attach — switching the manager locally never re-attaches the
      // transcript. The row tap must go through openSessionAction.
      final env = MemoryExecutionEnv();
      final openedIds = <String>[];
      final relay = _RelayBackedService(
        env,
        openedIds,
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
        sessionsRoot: '/sessions',
        config: AgentConfig(
          providerKind: 'test',
          modelId: 'test-model',
          baseUrl: 'https://example.com',
          apiKey: '',
        ),
      );
      addTearDown(relay.dispose);
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('sess-a', _fakeService(env))
        ..addSession('sess-b', relay);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SessionChatSheet(manager: manager)),
        ),
      );
      await tester.pumpAndSettle();
      expect(manager.activeId, 'sess-b');

      await _openPanelViaDrawer(tester, 'sess-a');

      expect(openedIds, ['sess-a']);
      // The manager itself was not switched — the SW re-attach does that.
      expect(manager.activeId, 'sess-b');
    });

    testWidgets('a hosted drawer tap highlights the row immediately — the '
        'same pending rule as the wide sidebar', (tester) async {
      // The relay dispatch resolves but nothing adopts the session yet
      // (no SW confirm): the dot must still move NOW, not a beat later.
      final env = MemoryExecutionEnv();
      final openedIds = <String>[];
      final relay = _RelayBackedService(
        env,
        openedIds,
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
        sessionsRoot: '/sessions',
        config: AgentConfig(
          providerKind: 'test',
          modelId: 'test-model',
          baseUrl: 'https://example.com',
          apiKey: '',
        ),
      );
      addTearDown(relay.dispose);
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('sess-a', _fakeService(env))
        ..addSession('sess-b', relay);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SessionChatSheet(manager: manager)),
        ),
      );
      await tester.pumpAndSettle();
      expect(manager.activeId, 'sess-b');

      await _openDrawer(tester);
      expect(
        tester
            .widget<SessionTile>(
              find.byKey(const ValueKey('sessionChatDrawerEntry:sess-a')),
            )
            .isActive,
        isFalse,
      );

      await tester.tap(
        find.byKey(const ValueKey('sessionChatDrawerEntry:sess-a')),
      );
      await tester.pumpAndSettle();
      // The tap opened the panel (the drawer closed) — collapse it so the
      // sessions button comes back, then re-open the drawer.
      await tester.drag(find.byKey(_handleKey), const Offset(0, 400));
      await tester.pumpAndSettle();
      await _openDrawer(tester);

      // Pending highlight: selected without any SW confirm.
      expect(
        tester
            .widget<SessionTile>(
              find.byKey(const ValueKey('sessionChatDrawerEntry:sess-a')),
            )
            .isActive,
        isTrue,
      );
      expect(manager.activeId, 'sess-b');
    });

    testWidgets('a persisted session opens lazily from the drawer', (
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

      await _openDrawer(tester);
      expect(
        find.byKey(ValueKey('sessionChatDrawerEntry:${persistedMeta.id}')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(ValueKey('sessionChatDrawerEntry:${persistedMeta.id}')),
      );
      await tester.pumpAndSettle();
      // The lazy open completes over real async hops (clone + session
      // load); the widget-test clock does not advance them, so drain the
      // real queue until the manager switches (bounded — a hang must fail,
      // not stall).
      for (var i = 0; i < 50 && manager.activeId != persistedMeta.id; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pumpAndSettle();
      }

      expect(manager.activeId, persistedMeta.id);
      expect(manager.sessions, hasLength(2));
      expect(find.byKey(_panelKey), findsOneWidget);
      expect(find.text('old chat'), findsOneWidget);
    });

    testWidgets('an opened session keeps its own folder label in the drawer', (
      tester,
    ) async {
      // Seed an on-disk session created in /work/alpha…
      final seedEnv = MemoryExecutionEnv(cwd: '/work/alpha');
      final seed = _fakeService(seedEnv);
      late final SessionMetadata persistedMeta;
      late final String sessionFile;
      await tester.runAsync(() async {
        await seed.initialize();
        await seed.sendText('old chat');
        await seed.waitForIdle();
        persistedMeta = (await seed.listSessions()).single;
        sessionFile = (await seedEnv.readTextFile(
          persistedMeta.path,
        )).getOrThrow();
      });
      seed.dispose();

      // …then mount a DIFFERENT working directory: the live env reports
      // /work/beta for every session, so without the metadata lookup the
      // tile's folder label would flip from alpha to beta on open.
      final liveEnv = MemoryExecutionEnv(cwd: '/work/beta');
      await tester.runAsync(() async {
        (await liveEnv.writeFile(persistedMeta.path, sessionFile)).getOrThrow();
      });
      final live = _fakeService(liveEnv);
      addTearDown(live.dispose);
      final manager = FlutterSessionManager(
        env: liveEnv,
        sessionsRoot: '/sessions',
      )..addSession('sess-live', live);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SessionChatSheet(manager: manager)),
        ),
      );
      await tester.pumpAndSettle();

      await _openDrawer(tester);
      // The folder is now the GROUP HEADER above the tile (the per-tile
      // cwd label is gone — it duplicated the header).
      expect(find.text('alpha'), findsOneWidget);

      await tester.tap(
        find.byKey(ValueKey('sessionChatDrawerEntry:${persistedMeta.id}')),
      );
      await tester.pumpAndSettle();
      // The lazy open completes over real async hops (clone + session
      // load); drain the real queue until the manager switches (bounded —
      // a hang must fail, not stall).
      for (var i = 0; i < 50 && manager.activeId != persistedMeta.id; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pumpAndSettle();
      }
      expect(manager.activeId, persistedMeta.id);

      // Live now — the opened session must STAY in its origin folder's
      // group (alpha), not move into the current mount's (beta). The
      // beta group may exist — that's the fresh default session living
      // in the beta workspace — but the opened session is not in it.
      await tester.tap(find.byKey(_panelSessionsKey));
      await tester.pumpAndSettle();
      expect(find.byKey(_drawerKey), findsOneWidget);
      final openedTile = find.byKey(
        ValueKey('sessionChatDrawerEntry:${persistedMeta.id}'),
      );
      // The opened tile sits under the alpha header: alpha's header is
      // the nearest header above the tile.
      final alphaHeader = tester.getTopLeft(find.text('alpha'));
      final tileTop = tester.getTopLeft(openedTile);
      expect(tileTop.dy, greaterThan(alphaHeader.dy));
    });

    testWidgets('the drawer New session tile creates, activates and opens '
        'the panel', (tester) async {
      final harness = await _pumpSheet(tester);
      await _openDrawer(tester);
      await tester.tap(find.byKey(_newSessionKey));
      await tester.pumpAndSettle();

      expect(harness.manager.sessions, hasLength(3));
      expect(harness.manager.activeId, isNot('sess-b'));
      expect(find.byKey(_panelKey), findsOneWidget);
      expect(find.text('Nothing here yet — ask Fa anything.'), findsOneWidget);
    });

    testWidgets('the mic swaps into send as soon as text is entered; sending '
        'from the bar delivers the message', (tester) async {
      final harness = await _pumpSheet(tester);
      // Empty field: the mic is the ONLY trailing affordance (iMessage-style)
      // — no send circle until there is something to send.
      expect(find.byIcon(Icons.mic_none), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward), findsNothing);

      await tester.enterText(find.byType(TextField).last, 'hello Fa');
      // pumpAndSettle: the mic↔send swap runs through an AnimatedSwitcher
      // (both children exist mid-transition), and focusing the field opens
      // the panel.
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.mic_none), findsNothing);
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
      expect(find.byKey(_panelKey), findsOneWidget);

      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      final messages = harness.services['sess-b']!.messages;
      expect(messages.first.role, 'user');
      expect(messages.first.content, 'hello Fa');
    });

    testWidgets('focusing the bar field opens the current session panel', (
      tester,
    ) async {
      await _pumpSheet(tester);
      // No autofocus in the bar: the panel starts closed.
      expect(find.byKey(_panelKey), findsNothing);

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(find.byKey(_panelKey), findsOneWidget);
    });

    testWidgets('the panel header sessions button opens the drawer over the '
        'panel', (tester) async {
      await _pumpSheet(tester);
      await _openPanelViaDrawer(tester, 'sess-b');
      expect(find.byKey(_panelKey), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sessionChatPanelSessions')));
      await tester.pumpAndSettle();
      expect(find.byKey(_drawerKey), findsOneWidget);
      // The drawer lists the same rows while the panel stays underneath.
      expect(
        find.byKey(const ValueKey('sessionChatDrawerEntry:sess-a')),
        findsOneWidget,
      );
      expect(find.byKey(_panelKey), findsOneWidget);
    });

    testWidgets('sending keeps the input focused — the next message needs no '
        're-tap', (tester) async {
      final harness = await _pumpSheet(tester);
      // The transcript bubbles are SelectableText (= EditableText), so scope
      // the finder to the composer's TextField.
      final fieldEditable = find.descendant(
        of: find.byType(TextField),
        matching: find.byType(EditableText),
      );
      final focusNode = tester.widget<EditableText>(fieldEditable).focusNode;

      await tester.enterText(find.byType(TextField).last, 'first');
      // The focus opened the panel; the status-row slot in the bar column
      // toggled — the composer element must survive that re-layout.
      await tester.pumpAndSettle();
      expect(find.byKey(_panelKey), findsOneWidget);
      expect(
        tester.widget<EditableText>(fieldEditable).focusNode,
        same(focusNode),
      );
      expect(focusNode.hasFocus, isTrue);

      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(harness.services['sess-b']!.messages.first.content, 'first');
      // Still the same focused field after the send: the IME's send action
      // unfocuses (EditableText finalizes with shouldUnfocus) — the composer
      // restores focus so the follow-up needs no re-tap.
      expect(
        tester.widget<EditableText>(fieldEditable).focusNode,
        same(focusNode),
      );
      expect(focusNode.hasFocus, isTrue);
    });

    testWidgets('with the panel open, a tap outside the open drawer still '
        'closes it', (tester) async {
      await _pumpSheet(tester);
      await _openPanelViaDrawer(tester, 'sess-b');
      expect(find.byKey(_panelKey), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sessionChatPanelSessions')));
      await tester.pumpAndSettle();
      expect(find.byKey(_drawerKey), findsOneWidget);

      // Tap on the PANEL area right of the drawer: the drawer's own scrim
      // (above the panel) catches it — the grid-level scrim is covered.
      await tester.tapAt(const Offset(600, 400));
      await tester.pumpAndSettle();
      expect(find.byKey(_drawerKey), findsNothing);
      expect(find.byKey(_panelKey), findsOneWidget);
    });

    testWidgets('streaming with the panel closed shows the status row; its '
        'expand button opens the panel', (tester) async {
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
      // FaWorkBar stays in the tree but renders nothing while idle — the
      // orbit indicator only exists once the status row is actually shown.
      const orbitKey = ValueKey('faWorkBarOrbit');
      expect(find.byKey(orbitKey), findsNothing);

      // Started OUTSIDE the bar (no composer onSent): the panel stays
      // closed and the slim status row appears instead.
      await tester.runAsync(() async {
        unawaited(service.sendText('long task'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(service.isStreaming, isTrue);
      // The orbit repeats forever — pump timed frames, never pumpAndSettle.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(orbitKey), findsOneWidget);
      expect(find.byKey(_panelKey), findsNothing);

      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(_panelKey), findsOneWidget);
    });

    testWidgets('menu: Close dismisses the panel back to the bare bar', (
      tester,
    ) async {
      await _pumpSheet(tester);
      await _openPanelViaDrawer(tester, 'sess-b');
      expect(find.byKey(_panelKey), findsOneWidget);

      await tester.tap(find.byKey(_menuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Collapse chat'));
      await tester.pumpAndSettle();
      expect(find.byKey(_panelKey), findsNothing);
      expect(find.byKey(_drawerButtonKey), findsOneWidget);
    });

    testWidgets('a pull-down on the handle closes the panel', (tester) async {
      await _pumpSheet(tester);
      await _openPanelViaDrawer(tester, 'sess-b');
      expect(find.byKey(_panelKey), findsOneWidget);

      await tester.drag(find.byKey(_handleKey), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(find.byKey(_panelKey), findsNothing);
      expect(find.byType(ChatComposer), findsOneWidget);
    });

    testWidgets('closing the panel drops the field focus (keyboard hides)', (
      tester,
    ) async {
      await _pumpSheet(tester);
      final fieldEditable = find.descendant(
        of: find.byType(TextField),
        matching: find.byType(EditableText),
      );

      // Focusing the bar field opens the panel (the keyboard would be up).
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(find.byKey(_panelKey), findsOneWidget);
      expect(
        tester.widget<EditableText>(fieldEditable).focusNode.hasFocus,
        isTrue,
      );

      // Closing the panel must unfocus — otherwise the keyboard stays
      // floating over the app grid with no visible way to dismiss it.
      await tester.tap(find.byKey(_menuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Collapse chat'));
      await tester.pumpAndSettle();
      expect(find.byKey(_panelKey), findsNothing);
      expect(
        tester.widget<EditableText>(fieldEditable).focusNode.hasFocus,
        isFalse,
      );
    });

    testWidgets('menu: New session creates and activates a fresh session', (
      tester,
    ) async {
      final harness = await _pumpSheet(tester);
      await _openPanelViaDrawer(tester, 'sess-b');
      await tester.tap(find.byKey(_menuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New session'));
      await tester.pumpAndSettle();

      expect(harness.manager.sessions, hasLength(3));
      expect(harness.manager.activeId, isNot('sess-b'));
      expect(find.text('Nothing here yet — ask Fa anything.'), findsOneWidget);
    });

    testWidgets('menu: Open full chat pushes the ChatScreen', (tester) async {
      await _pumpSheet(tester);
      await _openPanelViaDrawer(tester, 'sess-b');
      await tester.tap(find.byKey(_menuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open full chat'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
    });

    testWidgets('menu: Rename session saves a custom title into the header', (
      tester,
    ) async {
      final namesStore = SessionNamesStore.inMemory();
      await _pumpSheet(tester, namesStore: namesStore);
      await _openPanelViaDrawer(tester, 'sess-b');
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
      await _openPanelViaDrawer(tester, 'sess-b');
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
      await _openPanelViaDrawer(tester, 'sess-b');

      await tester.tap(find.byKey(_menuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy session'));
      await tester.pumpAndSettle();

      expect(copied, contains('## You\nbuild me a dice app'));
      expect(copied, contains('## Fa\nDone — Dice Roller.'));
    });

    testWidgets('the panel header stays on screen when the keyboard opens', (
      tester,
    ) async {
      // Simulate the OS keyboard: viewInsets.bottom consumes the lower part
      // of the display while MediaQuery.size stays full height — the exact
      // setup that used to push the header off the top edge.
      tester.view.viewInsets = FakeViewPadding(bottom: 336);
      addTearDown(tester.view.resetViewInsets);

      await _pumpSheet(tester);
      await _openPanelViaDrawer(tester, 'sess-b');

      // The menu button lives in the panel header: it must be INSIDE the
      // viewport (its top below the screen's top edge), not flown above it.
      final topLeft = tester.getTopLeft(find.byKey(_menuKey));
      expect(topLeft.dy, greaterThanOrEqualTo(0));
      expect(find.byKey(_menuKey), findsOneWidget);
    });

    testWidgets('the panel header survives the keyboard opening AFTER the '
        'sheet was laid out', (tester) async {
      // The dynamic case (the real user flow): `View.of` never notifies on
      // viewInsets changes, so the sheet must react to the keyboard through
      // the shrunken layout constraints, not a static inset read.
      await _pumpSheet(tester);
      await _openPanelViaDrawer(tester, 'sess-b');
      expect(find.byKey(_menuKey), findsOneWidget);

      tester.view.viewInsets = FakeViewPadding(bottom: 336);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();

      final topLeft = tester.getTopLeft(find.byKey(_menuKey));
      expect(topLeft.dy, greaterThanOrEqualTo(0));
      expect(find.byKey(_menuKey), findsOneWidget);
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
        // Materialise the session file so listSessions() returns metadata
        // with a reachable creation time for the date-derived title.
        await service.sendText('hello');
        await service.waitForIdle();
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
      await _openPanelViaDrawer(tester, sessionId);

      // "Jul 31 12:30" — intl month-day + 24h time, no `session <id8>`
      // anywhere in the HEADER (the drawer row shares the derived title, so
      // the drawer is closed by now and only the header text remains).
      final dateTitle = RegExp(r'^\w{3}\.? \d{1,2},? \d{2}:\d{2}$');
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && w.data != null && dateTitle.hasMatch(w.data!),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('session '), findsNothing);
    });
  });

  group('SessionChatSheet trajectory (issue #168)', () {
    const trajectoryButtonKey = ValueKey('sessionChatPanelTrajectory');

    /// Drives a real turn on [service] so its trajectory feed holds the
    /// finalized records (runAsync: the fake provider stream completes on
    /// the real event loop, not on FakeAsync pumps).
    Future<void> driveTurn(
      WidgetTester tester,
      AgentService service,
      String text,
    ) async {
      await tester.runAsync(() async {
        await service.initialize();
        await service.sendText(text);
        await service.waitForIdle();
      });
    }

    /// Opens the panel and pushes the trajectory page; settles the
    /// controller's snapshot debounce.
    Future<AgentService> openTrajectoryPage(
      WidgetTester tester,
      _Harness harness,
    ) async {
      await _openPanelViaDrawer(tester, 'sess-b');
      await tester.tap(find.byKey(trajectoryButtonKey));
      await tester.pump(); // route push
      await tester.pump(const Duration(seconds: 4)); // debounce + throttle
      return harness.services['sess-b']!;
    }

    testWidgets('the panel header timeline button pushes the ledger page '
        'rendering the session through the shared fa_ui widgets (AC1)', (
      tester,
    ) async {
      final harness = await _pumpSheet(tester);
      await driveTurn(
        tester,
        harness.services['sess-b']!,
        'deploy the service',
      );
      await openTrajectoryPage(tester, harness);

      expect(find.byType(TrajectoryScreen), findsOneWidget);
      // A full-screen route, not a sheet/dialog over the launcher.
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      // The ledger renders the live session's records.
      expect(
        find.descendant(
          of: find.byType(TrajectoryScreen),
          matching: find.textContaining('deploy the service'),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('an empty session shows the friendly empty state, not a '
        'spinner (E1)', (tester) async {
      final harness = await _pumpSheet(tester);
      // No turn driven: the feed replays an empty snapshot immediately.
      await openTrajectoryPage(tester, harness);

      expect(find.byType(TrajectoryScreen), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.descendant(
          of: find.byType(TrajectoryScreen),
          matching: find.textContaining('No records yet'),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a turn landing while the page stays open appears without '
        'manual refresh (AC2)', (tester) async {
      final harness = await _pumpSheet(tester);
      await driveTurn(
        tester,
        harness.services['sess-b']!,
        'deploy the service',
      );
      final service = await openTrajectoryPage(tester, harness);

      await driveTurn(tester, service, 'check the logs');
      await tester.pump(const Duration(seconds: 4));

      expect(
        find.descendant(
          of: find.byType(TrajectoryScreen),
          matching: find.textContaining('check the logs'),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a ledger row tap opens the details sheet; back returns to '
        'the page, back again to the sheet (AC3)', (tester) async {
      final harness = await _pumpSheet(tester);
      await driveTurn(
        tester,
        harness.services['sess-b']!,
        'deploy the service',
      );
      await openTrajectoryPage(tester, harness);

      await tester.tap(
        find.descendant(
          of: find.byType(TrajectoryScreen),
          matching: find.textContaining('deploy the service'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);

      // Back: the details sheet's barrier tap closes it onto the
      // still-open page (the phone back gesture's equivalent).
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(TrajectoryScreen), findsOneWidget);

      // Back again: the page's header close pops it onto the launcher
      // sheet, panel intact.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(TrajectoryScreen), findsNothing);
      expect(find.byKey(_panelKey), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a session switch while the page stays open follows the '
        'newly active session (E2: follow, pinned)', (tester) async {
      final harness = await _pumpSheet(tester);
      await driveTurn(
        tester,
        harness.services['sess-b']!,
        'deploy the service',
      );
      await driveTurn(tester, harness.services['sess-a']!, 'review the diff');
      await openTrajectoryPage(tester, harness);
      expect(
        find.descendant(
          of: find.byType(TrajectoryScreen),
          matching: find.textContaining('deploy the service'),
        ),
        findsOneWidget,
      );

      harness.manager.switchTo('sess-a');
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));

      // The page now renders the NEWLY active session's ledger.
      expect(
        find.descendant(
          of: find.byType(TrajectoryScreen),
          matching: find.textContaining('review the diff'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(TrajectoryScreen),
          matching: find.textContaining('deploy the service'),
        ),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 4));
    });
  });
  group('sessions drawer search (issue #200)', () {
    Future<void> typeQuery(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(SessionSearchField), text);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('the drawer filters by id and hides non-matches; clear '
        'restores (AC1, AC4)', (tester) async {
      await _pumpSheet(tester);
      await _openDrawer(tester);

      await typeQuery(tester, 'sess-a');
      expect(
        find.byKey(const ValueKey('sessionChatDrawerEntry:sess-a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sessionChatDrawerEntry:sess-b')),
        findsNothing,
      );

      await tester.tap(find.byIcon(Icons.cancel));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('sessionChatDrawerEntry:sess-b')),
        findsOneWidget,
      );
    });

    testWidgets('no matches shows the empty state (E1)', (tester) async {
      await _pumpSheet(tester);
      await _openDrawer(tester);

      await typeQuery(tester, 'zzz');
      expect(find.text('No sessions match "zzz"'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(find.text('No sessions match "zzz"'), findsNothing);
    });

    testWidgets('closing the drawer drops the query: reopening shows the '
        'full list', (tester) async {
      await _pumpSheet(tester);
      await _openDrawer(tester);
      await typeQuery(tester, 'sess-a');
      expect(
        find.byKey(const ValueKey('sessionChatDrawerEntry:sess-b')),
        findsNothing,
      );

      // Scrim tap closes the drawer.
      await tester.tapAt(const Offset(700, 100));
      await tester.pumpAndSettle();
      await _openDrawer(tester);
      expect(
        find.byKey(const ValueKey('sessionChatDrawerEntry:sess-a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sessionChatDrawerEntry:sess-b')),
        findsOneWidget,
      );
    });

    testWidgets('the keyboard does not overflow the 320pt drawer '
        '(AC4)', (tester) async {
      await _pumpSheet(tester);
      await _openDrawer(tester);
      tester.view.viewInsets = FakeViewPadding(bottom: 336);
      await tester.pump();
      await typeQuery(tester, 'sess');

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('sessionChatDrawerEntry:sess-a')),
        findsOneWidget,
      );
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
    });
  });

  group('SessionChatSheet apps collapse toggle (issue #224)', () {
    const panelAppsKey = ValueKey('sessionChatPanelApps');

    testWidgets('the header Apps icon collapses the panel; the input bar '
        'stays (AC1)', (tester) async {
      await _pumpSheet(tester);
      await _openPanelViaDrawer(tester, 'sess-b');
      expect(find.byKey(_panelKey), findsOneWidget);

      await tester.tap(find.byKey(panelAppsKey));
      await tester.pumpAndSettle();
      expect(find.byKey(_panelKey), findsNothing);
      expect(find.byKey(_barKey), findsOneWidget);
    });

    testWidgets('restore boots the panel expanded when the user last left '
        'it so (AC2)', (tester) async {
      final env = MemoryExecutionEnv();
      final store = await AppsHomeModeStore.load(env);
      await store.setChatExpanded(true);
      final services = {'sess-b': _fakeService(env)};
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('sess-b', services['sess-b']!);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SessionChatSheet(manager: manager, restoreAppsMode: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_panelKey), findsOneWidget);
    });

    testWidgets('restore on a first run boots chat expanded (issue '
        'default)', (tester) async {
      await _pumpSheet(tester, restoreAppsMode: true);
      expect(find.byKey(_panelKey), findsOneWidget);
    });

    testWidgets('toggling persists the mode for the next boot (AC2)', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final store = await AppsHomeModeStore.load(env);
      await store.setChatExpanded(false); // user's last state: apps home
      final services = {'sess-b': _fakeService(env)};
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('sess-b', services['sess-b']!);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SessionChatSheet(manager: manager, restoreAppsMode: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_panelKey), findsNothing);
      // The user opens the chat again: the toggle records chat-expanded.
      await _openPanelViaDrawer(tester, 'sess-b');
      expect(find.byKey(_panelKey), findsOneWidget);
      final persisted = await AppsHomeModeStore.load(env);
      expect(persisted.chatExpanded, isTrue);
    });

    testWidgets('composer text survives the toggle in both directions '
        '(AC3)', (tester) async {
      await _pumpSheet(tester);
      await tester.enterText(find.byType(TextField).first, 'draft reply');
      await tester.pump();

      // Chat -> apps: the bar's text must survive the panel close.
      await _openPanelViaDrawer(tester, 'sess-b');
      await tester.tap(find.byKey(panelAppsKey));
      await tester.pumpAndSettle();
      expect(find.text('draft reply'), findsOneWidget);

      // Apps -> chat: opening the panel keeps the draft too.
      await _openPanelViaDrawer(tester, 'sess-b');
      expect(find.text('draft reply'), findsOneWidget);
    });

    testWidgets('a streaming run keeps streaming across the toggle; the '
        'work bar stays reachable on the apps home (E1)', (tester) async {
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
      await tester.runAsync(() async {
        unawaited(service.sendText('long task'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      // Expand the chat while streaming through the status row's expand
      // button (timed pumps — the orbit indicator never settles), then
      // collapse it back through the header Apps icon.
      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(_panelKey), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('sessionChatPanelApps')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(_panelKey), findsNothing);
      expect(service.isStreaming, isTrue);
      const orbitKey = ValueKey('faWorkBarOrbit');
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(orbitKey), findsOneWidget); // status row visible
    });
  });
  group('SessionChatSheet session tree (issue #198)', () {
    /// Seeds a main + subagent child pair on disk (the header metadata
    /// both hosts' childSessionFactory writes) and returns their
    /// metadata.
    Future<(SessionMetadata, SessionMetadata)> seedFamily(
      JsonlSessionRepo repo,
    ) async {
      final parentSession = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work/proj'),
      );
      final parent = await parentSession.getMetadata();
      final childSession = await repo.create(
        JsonlSessionCreateOptions(
          cwd: '/work/proj',
          metadata: {'agent': 'subagent', 'parent': parent.id},
        ),
      );
      return (parent, await childSession.getMetadata());
    }

    Future<void> pumpTreeSheet(
      WidgetTester tester, {
      required MemoryExecutionEnv env,
      required FlutterSessionManager manager,
      SessionNamesStore? namesStore,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SessionChatSheet(
              manager: manager,
              sessionNamesStore: namesStore,
              asr: _FakeAsrApi(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the drawer collapses subagent sessions under their parent '
        'and expanding reveals them', (tester) async {
      final env = MemoryExecutionEnv();
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final (parent, child) = await seedFamily(repo);
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession(parent.id, _fakeService(env));
      await pumpTreeSheet(
        tester,
        env: env,
        manager: manager,
        namesStore: SessionNamesStore.inMemory({
          parent.id: 'Main chat',
          child.id: 'goal_builder',
        }),
      );

      await _openDrawer(tester);
      // Collapsed by default: the parent's count badge shows, the child
      // row does not.
      expect(find.text('Main chat'), findsOneWidget);
      expect(find.text('1 agent'), findsOneWidget);
      expect(find.text('goal_builder'), findsNothing);

      // Expanding from the drawer reveals the child with the SAME key
      // scheme as before the tree.
      await tester.tap(find.text('1 agent'));
      await tester.pumpAndSettle();
      expect(find.text('goal_builder'), findsOneWidget);
      expect(
        find.byKey(ValueKey('sessionChatDrawerEntry:${child.id}')),
        findsOneWidget,
      );

      // Tapping the child row opens the panel on it.
      await tester.tap(
        find.byKey(ValueKey('sessionChatDrawerEntry:${child.id}')),
      );
      await tester.pumpAndSettle();
      expect(manager.activeId, child.id);
      expect(find.byKey(_panelKey), findsOneWidget);
      expect(find.byKey(_drawerKey), findsNothing);
    });

    testWidgets('an active descendant forces its parent group open in the '
        'drawer (same rule as the wide sidebar)', (tester) async {
      final env = MemoryExecutionEnv();
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final (parent, child) = await seedFamily(repo);
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession(child.id, _fakeService(env));
      await pumpTreeSheet(
        tester,
        env: env,
        manager: manager,
        namesStore: SessionNamesStore.inMemory({
          parent.id: 'Main chat',
          child.id: 'goal_builder',
        }),
      );

      await _openDrawer(tester);
      expect(find.text('Main chat'), findsOneWidget);
      expect(find.text('1 agent'), findsOneWidget);
      // No tap needed: the child IS the active session.
      expect(find.text('goal_builder'), findsOneWidget);
    });
  });
}
