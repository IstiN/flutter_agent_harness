// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/main.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/widgets/file_browser.dart';
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
      systemPrompt: 'You are fah.',
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

String _manifest(String id, String name, String icon) =>
    '''
{
  "id": "$id",
  "name": "$name",
  "description": "$name app",
  "icon": "$icon"
}
''';

/// Seeds three apps (Alpha/Beta/Gamma) and returns the env.
Future<MemoryExecutionEnv> _seededEnv() async {
  final env = MemoryExecutionEnv();
  for (final (id, name, icon) in [
    ('alpha', 'Alpha', '🅰️'),
    ('beta', 'Beta', '🅱️'),
    ('gamma', 'Gamma', '🎲'),
  ]) {
    await env.writeFile('apps/$id/manifest.json', _manifest(id, name, icon));
    await env.writeFile('apps/$id/widget.js', '(function(){})();');
  }
  return env;
}

AppsStore _appsStore(MemoryExecutionEnv env) => AppsStore(
  env,
  readAsset: (path) async => throw StateError('no bundled assets in this test'),
  seedDemoIds: const [],
);

class _Harness {
  _Harness(this.env, this.manager, this.layout);

  final MemoryExecutionEnv env;
  final FlutterSessionManager manager;
  final LauncherLayoutStore layout;
}

/// Pumps the launcher with three apps and an explicit initial layout.
Future<_Harness> _pumpLauncher(
  WidgetTester tester, {
  List<String>? order,
  List<LauncherFolder>? folders,
}) async {
  final env = await _seededEnv();
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('fake-session', _fakeService(env));
  final layout = LauncherLayoutStore.inMemory(
    order:
        order ??
        [
          'app:alpha',
          'app:beta',
          'app:gamma',
          LauncherLayoutStore.settingsKey,
          LauncherLayoutStore.filesKey,
        ],
    folders: folders,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppLauncherScreen(
        manager: manager,
        layoutStore: layout,
        appsStore: _appsStore(env),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(env, manager, layout);
}

Finder _cell(String tileKey) => find.byKey(ValueKey('launcherCell:$tileKey'));

/// Long-press drags the tile [fromKey] onto [target] (a global offset).
Future<void> _dragTile(
  WidgetTester tester,
  String fromKey,
  Offset target,
) async {
  final gesture = await tester.startGesture(tester.getCenter(_cell(fromKey)));
  await tester.pump(const Duration(milliseconds: 700));
  await gesture.moveTo(target);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  group('AppLauncherScreen', () {
    testWidgets('renders app tiles and the settings/files system tiles', (
      tester,
    ) async {
      await _pumpLauncher(tester);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Gamma'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Files'), findsOneWidget);
    });

    testWidgets('drop near the edge reorders tiles', (tester) async {
      final harness = await _pumpLauncher(tester);
      // Drop Gamma on the LEFT edge of Alpha's cell → Gamma moves in front.
      final alphaRect = tester.getRect(_cell('app:alpha'));
      await _dragTile(
        tester,
        'app:gamma',
        Offset(alphaRect.left + 3, alphaRect.top + 4),
      );
      expect(harness.layout.topLevelKeys, [
        'app:gamma',
        'app:alpha',
        'app:beta',
        LauncherLayoutStore.settingsKey,
        LauncherLayoutStore.filesKey,
      ]);
    });

    testWidgets('drop on the center of an app tile creates a folder', (
      tester,
    ) async {
      final harness = await _pumpLauncher(tester);
      await _dragTile(tester, 'app:alpha', tester.getCenter(_cell('app:beta')));
      final folderKeys = harness.layout.topLevelKeys
          .where(LauncherLayoutStore.isFolderKey)
          .toList();
      expect(folderKeys, hasLength(1));
      final folder = harness.layout.folderById(
        LauncherLayoutStore.folderIdOf(folderKeys.single),
      )!;
      // Auto-named from the two app names.
      expect(folder.name, 'Alpha & Beta');
      expect(folder.tiles, containsAll(['app:alpha', 'app:beta']));
      expect(find.text('Alpha & Beta'), findsOneWidget);
      expect(harness.layout.topLevelKeys, [
        folderKeys.single,
        'app:gamma',
        LauncherLayoutStore.settingsKey,
        LauncherLayoutStore.filesKey,
      ]);
    });

    testWidgets('drop on a folder tile adds the app to the folder', (
      tester,
    ) async {
      final harness = await _pumpLauncher(
        tester,
        order: [
          'folder:f1',
          'app:gamma',
          LauncherLayoutStore.settingsKey,
          LauncherLayoutStore.filesKey,
        ],
        folders: [
          LauncherFolder(
            id: 'f1',
            name: 'Pair',
            tiles: ['app:alpha', 'app:beta'],
          ),
        ],
      );
      await _dragTile(
        tester,
        'app:gamma',
        tester.getCenter(_cell('folder:f1')),
      );
      expect(harness.layout.folderById('f1')!.tiles, [
        'app:alpha',
        'app:beta',
        'app:gamma',
      ]);
      expect(harness.layout.topLevelKeys, [
        'folder:f1',
        LauncherLayoutStore.settingsKey,
        LauncherLayoutStore.filesKey,
      ]);
    });

    testWidgets('tapping a folder opens its panel; barrier tap closes it', (
      tester,
    ) async {
      await _pumpLauncher(
        tester,
        order: [
          'folder:f1',
          LauncherLayoutStore.settingsKey,
          LauncherLayoutStore.filesKey,
        ],
        folders: [
          LauncherFolder(
            id: 'f1',
            name: 'Pair',
            tiles: ['app:alpha', 'app:beta'],
          ),
        ],
      );
      await tester.tap(find.text('Pair'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('launcherFolderPanel')), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);

      await tester.tapAt(const Offset(12, 12));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('launcherFolderPanel')), findsNothing);
    });

    testWidgets('dragging a tile out of the folder panel ungroups it', (
      tester,
    ) async {
      final harness = await _pumpLauncher(
        tester,
        order: [
          'folder:f1',
          LauncherLayoutStore.settingsKey,
          LauncherLayoutStore.filesKey,
        ],
        folders: [
          LauncherFolder(
            id: 'f1',
            name: 'Pair',
            tiles: ['app:alpha', 'app:beta'],
          ),
        ],
      );
      await tester.tap(find.text('Pair'));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Alpha')),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.moveTo(const Offset(30, 500));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(harness.layout.folderById('f1')!.tiles, ['app:beta']);
      expect(harness.layout.topLevelKeys, [
        'folder:f1',
        'app:alpha',
        LauncherLayoutStore.settingsKey,
        LauncherLayoutStore.filesKey,
        'app:gamma',
      ]);
    });

    testWidgets('folder panel renames and dissolves the folder', (
      tester,
    ) async {
      final harness = await _pumpLauncher(
        tester,
        order: [
          'folder:f1',
          LauncherLayoutStore.settingsKey,
          LauncherLayoutStore.filesKey,
        ],
        folders: [
          LauncherFolder(
            id: 'f1',
            name: 'Pair',
            tiles: ['app:alpha', 'app:beta'],
          ),
        ],
      );
      await tester.tap(find.text('Pair'));
      await tester.pumpAndSettle();

      // Rename.
      await tester.tap(find.byTooltip('Rename folder'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Stuff');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(harness.layout.folderById('f1')!.name, 'Stuff');
      expect(find.text('Stuff'), findsWidgets);

      // Dissolve: both tiles return to the top level.
      await tester.tap(find.byTooltip('Remove folder'));
      await tester.pumpAndSettle();
      expect(harness.layout.folderById('f1'), isNull);
      expect(harness.layout.topLevelKeys, [
        'app:alpha',
        'app:beta',
        LauncherLayoutStore.settingsKey,
        LauncherLayoutStore.filesKey,
        'app:gamma',
      ]);
      expect(find.byKey(const ValueKey('launcherFolderPanel')), findsNothing);
    });

    testWidgets('settings tile pushes the settings screen', (tester) async {
      await _pumpLauncher(tester);
      await tester.tap(_cell(LauncherLayoutStore.settingsKey));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('files tile pushes the file browser', (tester) async {
      await _pumpLauncher(tester);
      await tester.tap(_cell(LauncherLayoutStore.filesKey));
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowser), findsOneWidget);
    });

    testWidgets('a new app created mid-session appears after fsRevision bump', (
      tester,
    ) async {
      final harness = await _pumpLauncher(tester);
      await harness.env.writeFile(
        'apps/delta/manifest.json',
        _manifest('delta', 'Delta', '🆕'),
      );
      await harness.env.writeFile('apps/delta/widget.js', '(function(){})();');
      harness.manager.active!.service.fsRevision.value++;
      await tester.pumpAndSettle();
      expect(find.text('Delta'), findsOneWidget);
      expect(harness.layout.topLevelKeys.last, 'app:delta');
    });
  });

  group('faHomeScreen boot choice', () {
    Future<Widget> homeAt(WidgetTester tester, Size size) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('fake-session', _fakeService(env));
      late Widget home;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              home = faHomeScreen(context: context, manager: manager);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return home;
    }

    testWidgets('narrow (< 900px) boots into the apps launcher', (
      tester,
    ) async {
      expect(
        await homeAt(tester, const Size(390, 844)),
        isA<AppLauncherScreen>(),
      );
    });

    testWidgets('wide (>= 900px) boots into the classic chat screen', (
      tester,
    ) async {
      expect(await homeAt(tester, const Size(1280, 800)), isA<ChatScreen>());
    });
  });
}
