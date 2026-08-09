// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Integration coverage for the settings round-trips: the "icons per row"
/// setting writes `grid.columns` into `launcher_layout.json` and the
/// launcher reflows live; the theme mode persists through `theme.json`.
library;

import 'package:fa/apps/apps_store.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'integration_fakes.dart';

String _manifest(String id, String name) =>
    '''
{
  "id": "$id",
  "name": "$name",
  "description": "$name app",
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
  group('settings round-trips', () {
    testWidgets('icons per row writes grid.columns and the launcher reflows '
        'live', (tester) async {
      final env = MemoryExecutionEnv();
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

      Finder cell(String tileKey) =>
          find.byKey(ValueKey('launcherCell:$tileKey'));
      // Default 4 columns on the 800px surface: settings sits on row 0.
      final gammaTop = tester.getRect(cell('app:gamma')).top;
      expect(
        tester.getRect(cell(LauncherLayoutStore.settingsKey)).top,
        moreOrLessEquals(gammaTop, epsilon: 0.5),
      );

      // Settings tile → Home grid section → pick 3 icons per row.
      await tester.tap(cell(LauncherLayoutStore.settingsKey));
      await tester.pumpAndSettle();
      expect(find.byType(HomeGridSection), findsOneWidget);
      // The settings page is scrollable; the dropdown may sit below the
      // fold after the providers section grew, so scroll it into view.
      await tester.ensureVisible(find.byType(DropdownButton<int?>));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<int?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('3').last);
      await tester.pumpAndSettle();

      // The override landed in the store and persisted to the layout file.
      expect(layout.gridColumns, 3);
      Future<String> layoutJson() async =>
          (await env.readTextFile(
            '${env.cwd}/${LauncherLayoutStore.fileName}',
          )).valueOrNull ??
          '';
      expect(await layoutJson(), contains('"columns":3'));

      // Back on the launcher the grid reflowed: 3 columns push the settings
      // tile off row 0.
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(AppLauncherScreen), findsOneWidget);
      expect(
        tester.getRect(cell(LauncherLayoutStore.settingsKey)).top,
        greaterThan(tester.getRect(cell('app:gamma')).top),
      );

      // And a fresh store over the same env loads the override.
      final reloaded = await LauncherLayoutStore.load(env);
      expect(reloaded.gridColumns, 3);
    });

    testWidgets('the theme mode persists through theme.json', (tester) async {
      final env = MemoryExecutionEnv();
      final controller = await ThemeController.load(env);
      expect(controller.mode, FahThemeMode.system);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahThemeLight(),
          darkTheme: buildFahTheme(),
          themeMode: controller.themeMode,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: FahThemeScope(
            controller: controller,
            child: const Scaffold(
              body: SingleChildScrollView(child: ThemeModeSection()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<FahThemeMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dark').last);
      await tester.pumpAndSettle();

      expect(controller.mode, FahThemeMode.dark);
      expect(
        (await env.readTextFile(
          '${env.cwd}/${ThemeController.fileName}',
        )).valueOrNull,
        contains('"dark"'),
      );

      // A fresh controller over the same env boots into the persisted mode.
      final reloaded = await ThemeController.load(env);
      expect(reloaded.mode, FahThemeMode.dark);
      expect(reloaded.themeMode, ThemeMode.dark);
    });
  });
}
