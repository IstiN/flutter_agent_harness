// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Integration coverage for launcher integrity: ownership-aware demo
/// seeding (a customized file is never overwritten), and layout
/// persistence — reorders and folder create/dissolve round-tripping
/// through `launcher_layout.json`.
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

import 'integration_fakes.dart';

String _manifest(String id, String name, {String version = '1.0.0'}) =>
    '''
{
  "id": "$id",
  "name": "$name",
  "description": "$name app",
  "version": "$version",
  "icon": "📦"
}
''';

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
      streamFunction: scriptedTurns([(model) => textTurn(model, 'ok')]),
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
  group('demo seeding ownership', () {
    test('seeding preserves a user-customized file and refreshes untouched '
        'ones', () async {
      final env = MemoryExecutionEnv();
      // The bundled demo, version 1.
      var assets = {
        'manifest.json': _manifest('demo', 'Demo'),
        'widget.js': '/* bundled v1 */',
      };
      final store = AppsStore(
        env,
        readAsset: (path) async =>
            assets[path.split('/').last] ??
            (throw StateError('missing asset $path')),
        seedDemoIds: const ['demo'],
      );
      await store.seedBundledApps();
      expect(
        (await env.readTextFile('apps/demo/widget.js')).valueOrNull,
        '/* bundled v1 */',
      );

      // The user (or the agent) takes ownership of widget.js; the bundle
      // ships v2 of both files.
      await env.writeFile('apps/demo/widget.js', '/* user custom */');
      assets = {
        'manifest.json': _manifest('demo', 'Demo', version: '2.0.0'),
        'widget.js': '/* bundled v2 */',
      };
      await store.seedBundledApps();

      // The customized file is preserved; the untouched one is refreshed.
      expect(
        (await env.readTextFile('apps/demo/widget.js')).valueOrNull,
        '/* user custom */',
      );
      expect(
        (await env.readTextFile('apps/demo/manifest.json')).valueOrNull,
        contains('"2.0.0"'),
      );

      // The escape hatch: resetDemoApp force-restores the reference files.
      expect(await store.resetDemoApp('demo'), isTrue);
      expect(
        (await env.readTextFile('apps/demo/widget.js')).valueOrNull,
        '/* bundled v2 */',
      );
      // … and future refreshes flow again (the seed hashes were re-recorded).
      assets['widget.js'] = '/* bundled v3 */';
      await store.seedBundledApps();
      expect(
        (await env.readTextFile('apps/demo/widget.js')).valueOrNull,
        '/* bundled v3 */',
      );
    });
  });

  group('layout persistence', () {
    /// Pumps the launcher over an env-backed layout store with three apps.
    Future<LauncherLayoutStore> pumpLauncher(
      WidgetTester tester,
      MemoryExecutionEnv env,
    ) async {
      for (final (id, name) in [
        ('alpha', 'Alpha'),
        ('beta', 'Beta'),
        ('gamma', 'Gamma'),
      ]) {
        await env.writeFile('apps/$id/manifest.json', _manifest(id, name));
        await env.writeFile('apps/$id/widget.js', '(function(){})();');
      }
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('s1', _fakeService(env));
      final layout = await LauncherLayoutStore.load(env);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AppLauncherScreen(
            manager: manager,
            layoutStore: layout,
            appsStore: AppsStore(
              env,
              readAsset: (path) async =>
                  throw StateError('no bundled assets in this test'),
              seedDemoIds: const [],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return layout;
    }

    Finder cell(String tileKey) =>
        find.byKey(ValueKey('launcherCell:$tileKey'));

    Future<void> dragTile(
      WidgetTester tester,
      String fromKey,
      Offset target,
    ) async {
      final gesture = await tester.startGesture(
        tester.getCenter(cell(fromKey)),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.moveTo(target);
      // Hold past the 450 ms folder-intent dwell before releasing.
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('a drag reorder persists across a store reload', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final layout = await pumpLauncher(tester, env);
      expect(layout.topLevelKeys, [
        'app:alpha',
        'app:beta',
        'app:gamma',
        LauncherLayoutStore.settingsKey,
        LauncherLayoutStore.filesKey,
      ]);

      // Drop Gamma on the LEFT edge of Alpha's cell → Gamma moves in front.
      final alphaRect = tester.getRect(cell('app:alpha'));
      await dragTile(
        tester,
        'app:gamma',
        Offset(alphaRect.left + 3, alphaRect.top + 4),
      );
      expect(layout.topLevelKeys.first, 'app:gamma');

      // A fresh store over the same env loads the persisted order.
      final reloaded = await LauncherLayoutStore.load(env);
      expect(reloaded.topLevelKeys, layout.topLevelKeys);
      expect(reloaded.topLevelKeys.first, 'app:gamma');
    });

    testWidgets('folder create and dissolve round-trip through '
        'launcher_layout.json', (tester) async {
      final env = MemoryExecutionEnv();
      final layout = await pumpLauncher(tester, env);

      // Drop Alpha on the CENTER of Beta → a folder groups them.
      await dragTile(tester, 'app:alpha', tester.getCenter(cell('app:beta')));
      final folderKeys = layout.topLevelKeys
          .where(LauncherLayoutStore.isFolderKey)
          .toList();
      expect(folderKeys, hasLength(1));
      final folderId = LauncherLayoutStore.folderIdOf(folderKeys.single);

      // The persisted file round-trips: a fresh store sees the folder.
      final reloaded = await LauncherLayoutStore.load(env);
      expect(reloaded.topLevelKeys, layout.topLevelKeys);
      expect(
        reloaded.folderById(folderId)!.tiles,
        containsAll(['app:alpha', 'app:beta']),
      );

      // Dissolve via the folder panel; the tiles return to the top level…
      await tester.tap(find.text('Alpha & Beta'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove folder'));
      await tester.pumpAndSettle();
      expect(layout.folderById(folderId), isNull);
      expect(
        layout.topLevelKeys,
        containsAll(['app:alpha', 'app:beta', 'app:gamma']),
      );

      // … and the dissolve persists too.
      final afterDissolve = await LauncherLayoutStore.load(env);
      expect(afterDissolve.topLevelKeys, layout.topLevelKeys);
      expect(afterDissolve.folderById(folderId), isNull);
    });
  });
}
