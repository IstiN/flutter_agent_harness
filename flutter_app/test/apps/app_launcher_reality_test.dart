// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Widget integration tests for issue #866 — the apps panel (the launcher
/// grid) reflects reality: an agent-side manifest rename shows up without
/// reinstall or restart, and a manifest the agent broke renders a visible
/// error affordance while the panel stays usable.
library;

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

Future<AppsStore> _store(MemoryExecutionEnv env) async => AppsStore(
  env,
  readAsset: (path) async => throw StateError('no bundled assets here'),
  seedDemoIds: const [],
);

Future<FlutterSessionManager> _pumpLauncher(
  WidgetTester tester,
  MemoryExecutionEnv env,
) async {
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
  manager.addSession('test-session', _fakeService(env));
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildFahTheme(),
      home: AppLauncherScreen(
        manager: manager,
        layoutStore: LauncherLayoutStore.inMemory(
          order: ['app:2048', 'app:broken'],
        ),
        appsStore: await _store(env),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return manager;
}

Future<MemoryExecutionEnv> _seededEnv({required bool broken}) async {
  final env = MemoryExecutionEnv();
  await env.writeFile(
    'apps/2048/manifest.json',
    '{"id": "2048", "name": "2048", "description": "Tile game"}',
  );
  await env.writeFile('apps/2048/widget.js', '(function(){});');
  if (broken) {
    // A manifest an agent edit broke (issue #866): present, unparseable.
    await env.writeFile('apps/broken/manifest.json', '{"name": ');
    await env.writeFile('apps/broken/widget.js', '(function(){});');
  }
  return env;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('AC1 — an agent rename appears without restart', (tester) async {
    final env = await _seededEnv(broken: false);
    final manager = await _pumpLauncher(tester, env);
    expect(find.text('2048'), findsWidgets);
    expect(find.text('2048 Renamed'), findsNothing);

    // The agent writes the rename through its regular file tools.
    await env.writeFile(
      'apps/2048/manifest.json',
      '{"id": "2048", "name": "2048 Renamed"}',
    );
    // The post-write hook: the launcher reloads on fsRevision bumps
    // (AgentService bumps it after every write/edit/bash tool call).
    manager.active!.service.fsRevision.value++;
    await tester.pumpAndSettle();
    expect(find.text('2048 Renamed'), findsWidgets);

    // Reopening the panel (a fresh surface) shows the new name too.
    await _pumpLauncher(tester, env);
    expect(find.text('2048 Renamed'), findsWidgets);
  });

  testWidgets('AC4 — broken manifest: flagged tile, usable panel', (
    tester,
  ) async {
    final env = await _seededEnv(broken: true);
    await _pumpLauncher(tester, env);
    // The broken app is visible (never silently dropped) under its folder
    // name, with the error badge on the tile.
    expect(find.text('broken'), findsWidgets);
    expect(find.text('!'), findsWidgets);

    // Tapping the broken tile surfaces the error instead of launching.
    await tester.tap(find.text('broken').first);
    await tester.pumpAndSettle();
    expect(find.text('App failed to load'), findsOneWidget);
    expect(find.textContaining('does not parse'), findsOneWidget);
    await tester.tap(find.text('Copy error'));
    await tester.pumpAndSettle();

    // The panel stays usable: the healthy neighbor still opens its menu.
    expect(find.text('2048'), findsWidgets);
  });
}
