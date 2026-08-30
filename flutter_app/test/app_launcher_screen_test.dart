// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/main.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
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

String _manifest(String id, String name, String icon) =>
    '''
{
  "id": "$id",
  "name": "$name",
  "description": "$name app",
  "icon": "$icon"
}
''';

/// Manifest variant opting the app into a live launcher tile.
String _manifestWithTile(String id, String name, String icon, String size) =>
    '''
{
  "id": "$id",
  "name": "$name",
  "description": "$name app",
  "icon": "$icon",
  "widget": { "entry": "widget_tile.js", "size": "$size" }
}
''';

/// Seeds three apps (Alpha/Beta/Gamma) and returns the env. [tileApps] maps
/// app id → tile size (`"WxH"` in grid cells) for apps with a `"widget"`
/// manifest section (live launcher tile).
Future<MemoryExecutionEnv> _seededEnv({
  Map<String, String> tileApps = const {},
}) async {
  final env = MemoryExecutionEnv();
  for (final (id, name, icon) in [
    ('alpha', 'Alpha', '🅰️'),
    ('beta', 'Beta', '🅱️'),
    ('gamma', 'Gamma', '🎲'),
  ]) {
    final size = tileApps[id];
    final manifest = size != null
        ? _manifestWithTile(id, name, icon, size)
        : _manifest(id, name, icon);
    await env.writeFile('apps/$id/manifest.json', manifest);
    await env.writeFile('apps/$id/widget.js', '(function(){})();');
    if (size != null) {
      await env.writeFile('apps/$id/widget_tile.js', '(function(){})();');
    }
  }
  return env;
}

/// Fake tile engine for the live-tile launcher tests: emits a fixed tree,
/// no JavaScriptCore boot (see test/apps/app_tile_host_test.dart).
final class _FakeTileEngine extends JsAppEngine {
  _FakeTileEngine({
    required super.app,
    required super.env,
    required super.permissions,
    super.initialTheme,
  });

  @override
  Future<void> start() async {
    tree.value = const {
      'type': 'container',
      'alignment': 'center',
      'child': {'type': 'text', 'data': 'LIVE TILE'},
    };
  }

  @override
  Future<void> updateTheme(Map<String, dynamic> theme) async {}
}

TileEngineFactory _fakeTileEngineFactory() =>
    ({
      required JsAppInfo app,
      required ExecutionEnv env,
      required AppPermissions permissions,
      required Map<String, dynamic> initialTheme,
    }) => _FakeTileEngine(
      app: app,
      env: env,
      permissions: permissions,
      initialTheme: initialTheme,
    );

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
/// [useEnvLayout] skips the in-memory layout store: the screen loads
/// `launcher_layout.json` from the env instead (agent-edit reload tests).
Future<_Harness> _pumpLauncher(
  WidgetTester tester, {
  List<String>? order,
  List<LauncherFolder>? folders,
  Map<String, String> tileApps = const {},
  TileEngineFactory? tileEngineFactory,
  int? gridColumns,
  bool useEnvLayout = false,
  Size? surface,
}) async {
  if (surface != null) {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  final env = await _seededEnv(tileApps: tileApps);
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
    gridColumns: gridColumns,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppLauncherScreen(
        manager: manager,
        layoutStore: useEnvLayout ? null : layout,
        appsStore: _appsStore(env),
        tileEngineFactory: tileEngineFactory,
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
  // Hold past the 450 ms folder-intent dwell before releasing.
  await tester.pump(const Duration(milliseconds: 500));
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

      // Rename. (Scope the field finder to the AlertDialog — the mini chat
      // bar's composer TextField is always on screen too.)
      await tester.tap(find.byTooltip('Rename folder'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Stuff',
      );
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

    testWidgets('an app with a widget section renders a live tile', (
      tester,
    ) async {
      await _pumpLauncher(
        tester,
        tileApps: {'alpha': '2x2'},
        tileEngineFactory: _fakeTileEngineFactory(),
      );
      // The live tile replaces Alpha's static icon + label …
      expect(find.byType(AppTileHost), findsOneWidget);
      expect(find.text('LIVE TILE'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
      // … while the other apps keep the classic icon tile.
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Gamma'), findsOneWidget);
    });

    testWidgets('a 4x2 live tile aligns with the icon-slot block', (
      tester,
    ) async {
      // 800px surface → 6 columns; a 4x2 tile covers rows 0-1, cols 0-3.
      await _pumpLauncher(
        tester,
        tileApps: {'alpha': '4x2'},
        tileEngineFactory: _fakeTileEngineFactory(),
      );
      const i = 56.0, cellMain = 76.0;
      // Dynamic cross-axis spacing: 800px surface, 6 columns →
      // (768 − 6×56)/5 = 86.4, capped at 44; the row gap stays 16.
      const g = 44.0, gr = 16.0;
      final hostRect = tester.getRect(find.byType(AppTileHost));
      final betaRect = tester.getRect(_cell('app:beta'));
      // Exact icon-unit extents: 4 slots + 3 gaps wide, 2 + 1 row-gap high.
      expect(hostRect.width, moreOrLessEquals(4 * i + 3 * g, epsilon: 0.5));
      expect(
        hostRect.height,
        moreOrLessEquals(2 * cellMain + gr, epsilon: 0.5),
      );
      // Beta packs first-fit beside the tile: SAME row, left edge exactly
      // 4 slots + 4 gaps to the right of the tile's left edge.
      expect(hostRect.top, moreOrLessEquals(betaRect.top, epsilon: 0.5));
      expect(
        betaRect.left,
        moreOrLessEquals(hostRect.left + 4 * (i + g), epsilon: 0.5),
      );
      // And Beta's slot is exactly one icon unit.
      expect(betaRect.width, moreOrLessEquals(i, epsilon: 0.5));
      expect(betaRect.height, moreOrLessEquals(cellMain, epsilon: 0.5));
    });

    testWidgets('defaults to 4 icon columns on a phone-width screen', (
      tester,
    ) async {
      await _pumpLauncher(tester, surface: const Size(390, 844));
      // Row 0: alpha, beta, gamma, settings — files wraps to row 1.
      final settingsRect = tester.getRect(
        _cell(LauncherLayoutStore.settingsKey),
      );
      final filesRect = tester.getRect(_cell(LauncherLayoutStore.filesKey));
      final alphaRect = tester.getRect(_cell('app:alpha'));
      final gammaRect = tester.getRect(_cell('app:gamma'));
      expect(settingsRect.top, moreOrLessEquals(alphaRect.top, epsilon: 0.5));
      expect(settingsRect.left, greaterThan(gammaRect.left));
      expect(filesRect.top, greaterThan(settingsRect.top));
      // Dynamic spacing: (390 − 32 − 4×56)/3 ≈ 44.67 → capped 44, so the
      // grid is 4×56 + 3×44 = 356 wide, nearly filling the padded area.
      expect(
        alphaRect.left,
        moreOrLessEquals(16 + (390 - 32 - 356) / 2, epsilon: 0.5),
      );
      // A 5th column would NOT fit — the count stays 4.
      expect(gammaRect.left - tester.getRect(_cell('app:beta')).left, 100.0);
    });

    testWidgets('dragging over an edge half live-reflows the grid', (
      tester,
    ) async {
      final harness = await _pumpLauncher(tester);
      final betaBefore = tester.getRect(_cell('app:beta'));
      final alphaRect = tester.getRect(_cell('app:alpha'));
      // Drag gamma onto the RIGHT half of alpha's slot (insert after) and
      // HOLD — the preview moves beta aside without persisting anything.
      final gesture = await tester.startGesture(
        tester.getCenter(_cell('app:gamma')),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.moveTo(Offset(alphaRect.right - 8, alphaRect.center.dy));
      // First pump: the preview builds and the reflow animation starts;
      // second pump: the 180 ms AnimatedPositioned run completes.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final betaPreview = tester.getRect(_cell('app:beta'));
      expect(betaPreview.left, greaterThan(betaBefore.left));
      expect(harness.layout.topLevelKeys.first, 'app:alpha'); // not persisted
      // Release: the preview becomes the persisted order.
      await gesture.up();
      await tester.pumpAndSettle();
      expect(harness.layout.topLevelKeys, [
        'app:alpha',
        'app:gamma',
        'app:beta',
        LauncherLayoutStore.settingsKey,
        LauncherLayoutStore.filesKey,
      ]);
    });

    testWidgets('dragging onto the first tile left edge moves to index 0', (
      tester,
    ) async {
      final harness = await _pumpLauncher(tester);
      final alphaRect = tester.getRect(_cell('app:alpha'));
      final gesture = await tester.startGesture(
        tester.getCenter(_cell('app:gamma')),
      );
      await tester.pump(const Duration(milliseconds: 700));
      // The left sliver of the FIRST tile: folder intent does not arm here
      // (center dwell band only), so the insert preview applies.
      await gesture.moveTo(Offset(alphaRect.left + 4, alphaRect.center.dy));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(harness.layout.topLevelKeys, [
        'app:gamma',
        'app:alpha',
        'app:beta',
        LauncherLayoutStore.settingsKey,
        LauncherLayoutStore.filesKey,
      ]);
    });

    testWidgets('center-band hover arms folder intent without reflow', (
      tester,
    ) async {
      final harness = await _pumpLauncher(tester);
      final betaBefore = tester.getRect(_cell('app:beta'));
      final gammaRect = tester.getRect(_cell('app:gamma'));
      // Drag alpha onto the CENTER of beta and hold: no insertion preview …
      final gesture = await tester.startGesture(
        tester.getCenter(_cell('app:alpha')),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.moveTo(betaBefore.center);
      // Folder intent arms only after a 450 ms dwell — before it, nothing.
      await tester.pump(const Duration(milliseconds: 200));
      expect(harness.layout.topLevelKeys.first, 'app:alpha');
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getRect(_cell('app:gamma')), gammaRect); // … no reflow
      // … and the drop groups both into a folder.
      await gesture.up();
      await tester.pumpAndSettle();
      final folderKeys = harness.layout.topLevelKeys
          .where(LauncherLayoutStore.isFolderKey)
          .toList();
      expect(folderKeys, hasLength(1));
      expect(
        harness.layout
            .folderById(LauncherLayoutStore.folderIdOf(folderKeys.single))!
            .tiles,
        containsAll(['app:alpha', 'app:beta']),
      );
    });

    testWidgets('hold-release without moving opens the tile size menu', (
      tester,
    ) async {
      final harness = await _pumpLauncher(
        tester,
        tileApps: {'alpha': '2x2'},
        tileEngineFactory: _fakeTileEngineFactory(),
      );
      // Long-press alpha and release WITHOUT moving: the menu opens.
      final gesture = await tester.startGesture(
        tester.getCenter(_cell('app:alpha')),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('Small (2×2)'), findsOneWidget);
      expect(find.text('Medium (4×2)'), findsOneWidget);
      expect(find.text('Large (4×4)'), findsOneWidget);
      // No override yet → no reset entry.
      expect(find.text('Reset to default'), findsNothing);

      // Pick Medium: the override lands and the tile resizes (dynamic
      // spacing 44 on the 800px surface → 4×56 + 3×44).
      await tester.tap(find.text('Medium (4×2)'));
      await tester.pumpAndSettle();
      expect(harness.layout.tileSizeFor('alpha'), (w: 4, h: 2));
      expect(
        tester.getRect(find.byType(AppTileHost)).width,
        moreOrLessEquals(4 * 56 + 3 * 44, epsilon: 0.5),
      );

      // Menu again → current size checked, reset offered; reset clears.
      final gesture2 = await tester.startGesture(
        tester.getCenter(_cell('app:alpha')),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await gesture2.up();
      await tester.pumpAndSettle();
      expect(find.text('Reset to default'), findsOneWidget);
      await tester.tap(find.text('Reset to default'));
      await tester.pumpAndSettle();
      expect(harness.layout.tileSizeFor('alpha'), isNull);
    });

    testWidgets('hold-release on a classic app tile opens the menu', (
      tester,
    ) async {
      await _pumpLauncher(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(_cell('app:beta')),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.up();
      await tester.pumpAndSettle();
      // Every app gets a menu now (Remove for non-demos) — no early
      // return for plain icon tiles.
      expect(find.byType(PopupMenuItem<Object?>), findsWidgets);
      expect(find.text('Remove widget'), findsOneWidget);
      expect(find.text('Small (2×2)'), findsNothing);
    });

    testWidgets('a layout JSON edit + fsRevision bump reconfigures the grid', (
      tester,
    ) async {
      final harness = await _pumpLauncher(
        tester,
        tileApps: {'alpha': '2x2'},
        tileEngineFactory: _fakeTileEngineFactory(),
        useEnvLayout: true,
      );
      // Seed the v2 layout: 4 columns, alpha at its manifest size (2x2).
      await harness.env.writeFile(
        '${harness.env.cwd}/${LauncherLayoutStore.fileName}',
        '{"version":2,'
            '"order":["app:alpha","app:beta","app:gamma",'
            '"system:settings","system:files"],'
            '"folders":[],"grid":{"columns":4},"tileSizes":{}}',
      );
      // The env-backed store loads on boot — pump a fresh screen state.
      harness.manager.active!.service.fsRevision.value++;
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(AppTileHost)).width,
        // Dynamic spacing caps at 44 on the 800px surface: 2×56 + 44.
        moreOrLessEquals(2 * 56 + 44, epsilon: 0.5),
      );

      // The agent reconfigures: 3 columns + a 4x2 override (clamped to 3).
      await harness.env.writeFile(
        '${harness.env.cwd}/${LauncherLayoutStore.fileName}',
        '{"version":2,'
            '"order":["app:alpha","app:beta","app:gamma",'
            '"system:settings","system:files"],'
            '"folders":[],"grid":{"columns":3},'
            '"tileSizes":{"alpha":"4x2"}}',
      );
      harness.manager.active!.service.fsRevision.value++;
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(AppTileHost)).width,
        // 3 columns, spacing still capped at 44: 3×56 + 2×44.
        moreOrLessEquals(3 * 56 + 2 * 44, epsilon: 0.5),
      );
    });

    testWidgets('a drop over the dragged tile itself applies the preview', (
      tester,
    ) async {
      final harness = await _pumpLauncher(tester);
      final alphaRect = tester.getRect(_cell('app:alpha'));
      final gesture = await tester.startGesture(
        tester.getCenter(_cell('app:gamma')),
      );
      await tester.pump(const Duration(milliseconds: 700));
      // Hover the RIGHT half of alpha's slot → preview: alpha, gamma, beta.
      await gesture.moveTo(Offset(alphaRect.right - 8, alphaRect.center.dy));
      await tester.pump(const Duration(milliseconds: 300));
      // Release over the DRAGGED tile's own (drop-rejecting) slot — the
      // usual landing zone when dragging a big widget. The last previewed
      // arrangement must still apply (iOS: what you saw is what you get).
      final gammaRect = tester.getRect(_cell('app:gamma'));
      await gesture.moveTo(gammaRect.center);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(harness.layout.topLevelKeys, [
        'app:alpha',
        'app:gamma',
        'app:beta',
        LauncherLayoutStore.settingsKey,
        LauncherLayoutStore.filesKey,
      ]);
    });

    testWidgets('live tiles still reorder by drag & drop', (tester) async {
      final harness = await _pumpLauncher(
        tester,
        tileApps: {'alpha': '2x2'},
        tileEngineFactory: _fakeTileEngineFactory(),
      );
      // Drop the live tile on the LEFT edge of Gamma's cell → Alpha moves
      // behind Gamma.
      final gammaRect = tester.getRect(_cell('app:gamma'));
      await _dragTile(
        tester,
        'app:alpha',
        Offset(gammaRect.left + 3, gammaRect.top + 4),
      );
      expect(harness.layout.topLevelKeys, [
        'app:beta',
        'app:alpha',
        'app:gamma',
        LauncherLayoutStore.settingsKey,
        LauncherLayoutStore.filesKey,
      ]);
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

    testWidgets('wide (>= 900px) boots into the wide layout shell', (
      tester,
    ) async {
      // Wide screens use the sidebar + content layout.
      expect(
        await homeAt(tester, const Size(1280, 800)),
        isA<WideLayoutShell>(),
      );
    });
  });
}
