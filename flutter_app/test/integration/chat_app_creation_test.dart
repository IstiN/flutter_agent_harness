// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Integration coverage for the flagship chat round-trip: a message typed
/// into the launcher's mini chat bar drives a (fake) model that writes a
/// new JS app into the sandbox; the mutating write bumps `fsRevision` and
/// the app appears in the home grid — live tile included.
library;

import 'dart:async';

import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'integration_fakes.dart';

const _todoManifest = '''
{
  "id": "todo",
  "name": "Todo",
  "description": "Todo app",
  "icon": "✅",
  "widget": { "entry": "widget_tile.js", "size": "2x2" }
}
''';

class _Harness {
  _Harness(this.env, this.service, this.manager);

  final MemoryExecutionEnv env;
  final AgentService service;
  final FlutterSessionManager manager;
}

/// Pumps the launcher with a real builtin-tools service whose model stream
/// is scripted: one tool-call turn writing the todo app, then a text reply.
Future<_Harness> _pumpLauncher(WidgetTester tester) async {
  final env = MemoryExecutionEnv();
  final service = AgentService(
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
      streamFunction: scriptedTurns([
        (model) => toolCallTurn(model, [
          writeCall('c1', 'apps/todo/manifest.json', _todoManifest),
          writeCall('c2', 'apps/todo/widget.js', '(function(){})();'),
          writeCall('c3', 'apps/todo/widget_tile.js', '(function(){})();'),
        ]),
        (model) => textTurn(model, 'Todo app created.'),
      ]),
      toolRegistry: ToolRegistry(builtinTools(env)),
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
  // No addTearDown: each test disposes the service explicitly — the
  // framework's pending-timer invariant runs before addTearDown callbacks,
  // and a still-streaming run holds the idle watchdog open.
  service.approvalPromptHandler = (_) => ApprovalDecision.approveOnce;
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('s1', service);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppLauncherScreen(
        manager: manager,
        layoutStore: LauncherLayoutStore.inMemory(),
        appsStore: AppsStore(
          env,
          readAsset: (path) async =>
              throw StateError('no bundled assets in this test'),
          seedDemoIds: const [],
        ),
        tileEngineFactory: fakeTileEngineFactory(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(env, service, manager);
}

void main() {
  group('chat round-trip', () {
    testWidgets('a message typed into the mini bar reaches the active '
        'session', (tester) async {
      final harness = await _pumpLauncher(tester);
      await tester.enterText(find.byType(TextField).last, 'make me a todo app');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      // The composer hands the text to the active session's service. (The
      // run itself is driven in the other test — agent runs complete in the
      // real async zone, see below.)
      await tester.pump();
      expect(
        harness.service.messages.any(
          (m) => m.role == 'user' && m.content == 'make me a todo app',
        ),
        isTrue,
      );
      // The UI-sent run stays stuck in the fake zone (see below); disposing
      // cancels its idle watchdog before the pending-timer invariant runs.
      harness.service.dispose();
    });

    testWidgets('write tool calls → fsRevision bump → the new app (with '
        'live tile) appears in the home grid', (tester) async {
      final harness = await _pumpLauncher(tester);
      expect(find.text('Todo'), findsNothing);
      final revisionBefore = harness.service.fsRevision.value;

      // The agent run's stream consumption needs the real event loop (it
      // stalls inside the test's fake zone — every streaming widget test in
      // this repo drives runs through runAsync for the same reason).
      await tester.runAsync(() async {
        unawaited(harness.service.sendText('make me a todo app'));
        await harness.service.waitForIdle();
      });
      await tester.pumpAndSettle();

      // The write tool calls landed in the sandbox …
      expect(
        (await harness.env.readTextFile('apps/todo/manifest.json')).valueOrNull,
        _todoManifest,
      );
      // … bumped the filesystem revision (the launcher's refresh hook) …
      expect(harness.service.fsRevision.value, greaterThan(revisionBefore));
      // … and the transcript shows the user message, the tool results, and
      // the assistant reply.
      expect(
        harness.service.messages.any(
          (m) => m.role == 'user' && m.content == 'make me a todo app',
        ),
        isTrue,
      );
      expect(
        harness.service.messages
            .where((m) => m.role == 'tool' && !m.isError)
            .length,
        3,
      );
      expect(
        harness.service.messages.any(
          (m) => m.role == 'assistant' && m.content == 'Todo app created.',
        ),
        isTrue,
      );

      // The new app appears in the home grid; its "widget" manifest section
      // boots the live tile through the injected tile engine factory.
      expect(find.byType(AppTileHost), findsOneWidget);
      expect(find.text('LIVE TILE'), findsOneWidget);
      // A live tile replaces the static icon + label.
      expect(find.text('Todo'), findsNothing);
      harness.service.dispose();
    });
  });
}
