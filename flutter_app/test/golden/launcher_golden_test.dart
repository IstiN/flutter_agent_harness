/// Golden (screenshot) tests for the selected Apps surface:
/// `lib/ui/screens/app_launcher_screen.dart` (grid, folders, system tiles).
///
/// Apps are seeded straight into a `MemoryExecutionEnv` (no bundled-asset
/// seeding) with inline-SVG manifest icons — the golden font sandbox renders
/// no emoji glyphs (see `apps_golden_test.dart`).
library;

import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

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

/// A rounded-square badge icon with a white glyph shape (renders with the
/// golden fonts — no emoji).
String _badgeIcon(String bg, String shape) =>
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'>"
    "<rect x='1' y='1' width='22' height='22' rx='6' fill='$bg'/>"
    '$shape</svg>';

const _fg = '#f8fafc';

/// id → [display name, inline SVG icon].
Map<String, List<String>> get _apps => {
  'notes': [
    'Notes',
    _badgeIcon(
      '#6366f1',
      "<rect x='7' y='7' width='10' height='2' rx='1' fill='$_fg'/>"
          "<rect x='7' y='11' width='10' height='2' rx='1' fill='$_fg'/>"
          "<rect x='7' y='15' width='6' height='2' rx='1' fill='$_fg'/>",
    ),
  ],
  'pomodoro': [
    'Pomodoro',
    _badgeIcon(
      '#f43f5e',
      "<circle cx='12' cy='13' r='6' fill='none' stroke='$_fg' "
          "stroke-width='2'/><rect x='10' y='4' width='4' height='2' rx='1' "
          "fill='$_fg'/><path d='M12 13 L12 9.5' stroke='$_fg' "
          "stroke-width='2' stroke-linecap='round'/>",
    ),
  ],
  'habits': [
    'Habit Tracker',
    _badgeIcon(
      '#22c55e',
      "<path d='M7 12.5 L10.5 16 L17 8.5' stroke='$_fg' stroke-width='2.5' "
          "fill='none' stroke-linecap='round' stroke-linejoin='round'/>",
    ),
  ],
  'dice': [
    'Dice Roller',
    _badgeIcon(
      '#8b5cf6',
      "<circle cx='8.5' cy='8.5' r='1.8' fill='$_fg'/>"
          "<circle cx='15.5' cy='8.5' r='1.8' fill='$_fg'/>"
          "<circle cx='8.5' cy='15.5' r='1.8' fill='$_fg'/>"
          "<circle cx='15.5' cy='15.5' r='1.8' fill='$_fg'/>",
    ),
  ],
};

Future<MemoryExecutionEnv> _seededEnv({
  bool liveTiles = false,
  Map<String, String> extraTiles = const {},

  /// Issue #866: adds one `broken` app whose manifest.json does not
  /// parse — its tile renders the visible error badge.
  bool brokenManifest = false,
}) async {
  final env = MemoryExecutionEnv();
  for (final entry in _apps.entries) {
    await env.writeFile(
      'apps/${entry.key}/manifest.json',
      '{"id": "${entry.key}", "name": "${entry.value[0]}", '
          '"description": "${entry.value[0]} app", '
          '"icon": ${_jsonString(entry.value[1])}}',
    );
    await env.writeFile('apps/${entry.key}/widget.js', '(function(){})();');
  }
  if (liveTiles) {
    // Two live-tile apps: the `"widget"` manifest section opts them into
    // AppTileHost spans instead of static icon tiles — weather as the 4x2
    // medium widget (full width on a phone), reminders as the 2x2 small.
    final sunIcon = _badgeIcon(
      '#0ea5e9',
      "<circle cx='12' cy='12' r='5' fill='$_fg'/>"
          "<rect x='11' y='2' width='2' height='4' rx='1' fill='$_fg'/>"
          "<rect x='11' y='18' width='2' height='4' rx='1' fill='$_fg'/>"
          "<rect x='2' y='11' width='4' height='2' rx='1' fill='$_fg'/>"
          "<rect x='18' y='11' width='4' height='2' rx='1' fill='$_fg'/>",
    );
    final bellIcon = _badgeIcon(
      '#f59e0b',
      "<path d='M12 4a6 6 0 0 0-6 6v3l-2 4h16l-2-4v-3a6 6 0 0 0-6-6z' "
          "fill='$_fg'/><circle cx='12' cy='19' r='2' fill='$_fg'/>",
    );
    await env.writeFile(
      'apps/weather/manifest.json',
      '{"id": "weather", "name": "Weather", "description": "Weather app", '
          '"icon": ${_jsonString(sunIcon)}, '
          '"widget": {"entry": "widget_tile.js", "size": "4x2", '
          '"refreshSeconds": 900}}',
    );
    await env.writeFile('apps/weather/widget.js', '(function(){})();');
    await env.writeFile('apps/weather/widget_tile.js', '(function(){})();');
    await env.writeFile(
      'apps/reminders/manifest.json',
      '{"id": "reminders", "name": "Reminders", '
          '"description": "Reminders app", '
          '"icon": ${_jsonString(bellIcon)}, '
          '"widget": {"entry": "widget_tile.js", "size": "2x2"}}',
    );
    await env.writeFile('apps/reminders/widget.js', '(function(){});');
    await env.writeFile('apps/reminders/widget_tile.js', '(function(){});');
  }
  // Extra live-tile apps (issue #166 span goldens): id → `"WxH"` size.
  final chartIcon = _badgeIcon(
    '#22c55e',
    "<rect x='4' y='12' width='3' height='8' rx='1' fill='$_fg'/>"
        "<rect x='10' y='8' width='3' height='12' rx='1' fill='$_fg'/>"
        "<rect x='16' y='4' width='3' height='16' rx='1' fill='$_fg'/>",
  );
  for (final entry in extraTiles.entries) {
    await env.writeFile(
      'apps/${entry.key}/manifest.json',
      '{"id": "${entry.key}", "name": "Steps", '
          '"description": "Steps app", '
          '"icon": ${_jsonString(chartIcon)}, '
          '"widget": {"entry": "widget_tile.js", "size": "${entry.value}"}}',
    );
    await env.writeFile('apps/${entry.key}/widget.js', '(function(){});');
    await env.writeFile('apps/${entry.key}/widget_tile.js', '(function(){});');
  }
  if (brokenManifest) {
    await env.writeFile('apps/broken/manifest.json', '{"name": ');
    await env.writeFile('apps/broken/widget.js', '(function(){});');
  }
  return env;
}

/// Fake tile engine emitting deterministic per-app tile trees so the
/// live-tile goldens stay pixel-stable (no JavaScriptCore boot).
final class _FakeTileEngine extends JsAppEngine {
  _FakeTileEngine({
    required super.app,
    required super.env,
    required super.permissions,
    super.initialTheme,
  });

  static const _weatherTree = <String, dynamic>{
    'type': 'container',
    'padding': [18, 12, 18, 12],
    'child': {
      'type': 'row',
      'crossAxisAlignment': 'center',
      'children': [
        {
          'type': 'column',
          'mainAxisSize': 'min',
          'crossAxisAlignment': 'center',
          'children': [
            {
              'type': 'icon',
              'name': 'wb_sunny',
              'color': '#FBBF24',
              'size': 34,
            },
            {'type': 'sizedBox', 'height': 4},
            {
              'type': 'text',
              'data': 'Minsk',
              'style': {'fontSize': 12},
            },
          ],
        },
        {
          'type': 'expanded',
          'child': {'type': 'sizedBox'},
        },
        {
          'type': 'column',
          'mainAxisSize': 'min',
          'crossAxisAlignment': 'end',
          'children': [
            {
              'type': 'text',
              'data': '21°',
              'style': {'fontSize': 42, 'fontWeight': 'w700'},
            },
            {
              'type': 'text',
              'data': 'Partly cloudy',
              'style': {'fontSize': 11},
            },
          ],
        },
      ],
    },
  };

  static const _remindersTree = <String, dynamic>{
    'type': 'container',
    'padding': [12, 10, 12, 10],
    'child': {
      'type': 'column',
      'mainAxisAlignment': 'center',
      'crossAxisAlignment': 'stretch',
      'children': [
        {
          'type': 'row',
          'crossAxisAlignment': 'center',
          'children': [
            {
              'type': 'icon',
              'name': 'notifications',
              'color': '#5EEAD4',
              'size': 14,
            },
            {'type': 'sizedBox', 'width': 6},
            {
              'type': 'expanded',
              'child': {
                'type': 'text',
                'data': 'Dentist',
                'maxLines': 1,
                'overflow': 'ellipsis',
                'style': {'fontSize': 12, 'fontWeight': 'w600'},
              },
            },
            {
              'type': 'text',
              'data': '25m',
              'style': {'fontSize': 10},
            },
          ],
        },
        {'type': 'sizedBox', 'height': 8},
        {
          'type': 'row',
          'crossAxisAlignment': 'center',
          'children': [
            {
              'type': 'icon',
              'name': 'notifications',
              'color': '#5EEAD4',
              'size': 14,
            },
            {'type': 'sizedBox', 'width': 6},
            {
              'type': 'expanded',
              'child': {
                'type': 'text',
                'data': 'Call Anna',
                'maxLines': 1,
                'overflow': 'ellipsis',
                'style': {'fontSize': 12, 'fontWeight': 'w600'},
              },
            },
            {
              'type': 'text',
              'data': '1h 10m',
              'style': {'fontSize': 10},
            },
          ],
        },
      ],
    },
  };

  /// The 1x3 tall tile's content: a compact stat list fitting the narrow
  /// one-cell width (only node types the other fake trees already use).
  static const _stepsTree = <String, dynamic>{
    'type': 'container',
    'padding': [10, 6, 10, 6],
    'child': {
      'type': 'column',
      'mainAxisAlignment': 'center',
      'crossAxisAlignment': 'stretch',
      'children': [
        {
          'type': 'text',
          'data': 'Steps',
          'maxLines': 1,
          'overflow': 'ellipsis',
          'style': {'fontSize': 11, 'fontWeight': 'w700'},
        },
        {'type': 'sizedBox', 'height': 6},
        {
          'type': 'text',
          'data': 'Mon',
          'maxLines': 1,
          'style': {'fontSize': 10},
        },
        {
          'type': 'text',
          'data': '8.2k',
          'maxLines': 1,
          'style': {'fontSize': 11, 'fontWeight': 'w600'},
        },
        {'type': 'sizedBox', 'height': 5},
        {
          'type': 'text',
          'data': 'Tue',
          'maxLines': 1,
          'style': {'fontSize': 10},
        },
        {
          'type': 'text',
          'data': '11k',
          'maxLines': 1,
          'style': {'fontSize': 11, 'fontWeight': 'w600'},
        },
        {'type': 'sizedBox', 'height': 5},
        {
          'type': 'text',
          'data': 'Wed',
          'maxLines': 1,
          'style': {'fontSize': 10},
        },
        {
          'type': 'text',
          'data': '9.7k',
          'maxLines': 1,
          'style': {'fontSize': 11, 'fontWeight': 'w600'},
        },
      ],
    },
  };

  @override
  Future<void> start() async {
    tree.value = switch (app.id) {
      'weather' => _weatherTree,
      'reminders' => _remindersTree,
      'steps' => _stepsTree,
      _ => const {'type': 'text', 'data': 'TILE'},
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

/// JSON-encodes [value] as a string literal (double quotes, escaped).
String _jsonString(String value) {
  final buffer = StringBuffer('"');
  for (final unit in value.codeUnits) {
    final char = String.fromCharCode(unit);
    if (char == '"' || char == '\\') buffer.write('\\');
    buffer.write(char);
  }
  buffer.write('"');
  return buffer.toString();
}

AppsStore _appsStore(MemoryExecutionEnv env) => AppsStore(
  env,
  readAsset: (path) async => throw StateError('no bundled assets in this test'),
  seedDemoIds: const [],
);

/// Pumps the selected Apps surface at phone size. [folders] seeds a
/// pre-made folder layout (default: the four apps + system tiles).
/// [liveTiles] adds two apps whose manifests declare a `"widget"` section
/// (weather 4x2, reminders 2x2) — pair it with [tileEngineFactory] so the
/// live tiles render deterministic trees.
Future<void> _pumpLauncher(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  ThemeData? theme,
  List<String>? order,
  List<LauncherFolder>? folders,
  bool liveTiles = false,
  TileEngineFactory? tileEngineFactory,
  Size size = goldenSizePhone,
  int? gridColumns,
  Map<String, String> extraTiles = const {},
  bool brokenManifest = false,
}) async {
  final env = await _seededEnv(
    liveTiles: liveTiles,
    extraTiles: extraTiles,
    brokenManifest: brokenManifest,
  );
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('fake-session', _fakeService(env));
  final launcher = AppLauncherScreen(
    manager: manager,
    layoutStore: LauncherLayoutStore.inMemory(
      order:
          order ??
          [
            if (liveTiles) 'app:weather',
            if (liveTiles) 'app:reminders',
            'app:notes',
            'app:pomodoro',
            'app:habits',
            'app:dice',
            LauncherLayoutStore.settingsKey,
            LauncherLayoutStore.filesKey,
          ],
      folders: folders,
      gridColumns: gridColumns,
    ),
    appsStore: _appsStore(env),
    tileEngineFactory: tileEngineFactory,
  );
  await pumpGolden(
    tester,
    launcher,
    size: size,
    locale: locale,
    theme: theme,
    wrap: (child) => child,
  );
}

void main() {
  setUpAll(ensureGoldenFonts);

  group('AppLauncherScreen goldens (launcher/)', () {
    testWidgets('launcher grid — dark', (tester) async {
      await _pumpLauncher(tester);
      await expectGolden(tester, 'launcher/grid_dark');
    });

    testWidgets('launcher grid — light', (tester) async {
      await _pumpLauncher(tester, theme: buildFahThemeLight());
      await expectGolden(tester, 'launcher/grid_light');
    });

    testWidgets('launcher grid — ru', (tester) async {
      await _pumpLauncher(tester, locale: const Locale('ru'));
      await expectGolden(tester, 'launcher/grid_ru');
    });

    testWidgets('launcher grid — manifest broken by an agent edit (#866)', (
      tester,
    ) async {
      await _pumpLauncher(
        tester,
        order: [
          'app:notes',
          'app:broken',
          'app:pomodoro',
          'app:habits',
          'app:dice',
          LauncherLayoutStore.settingsKey,
          LauncherLayoutStore.filesKey,
        ],
        brokenManifest: true,
      );
      expect(find.text('!'), findsWidgets);
      await expectGolden(tester, 'launcher/grid_broken_manifest');
    });

    testWidgets('folder open — dark', (tester) async {
      await _pumpLauncher(
        tester,
        order: [
          'folder:f1',
          'app:habits',
          'app:dice',
          LauncherLayoutStore.settingsKey,
          LauncherLayoutStore.filesKey,
        ],
        folders: [
          LauncherFolder(
            id: 'f1',
            name: 'Writing',
            tiles: ['app:notes', 'app:pomodoro'],
          ),
        ],
      );
      await tester.tap(find.text('Writing'));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'launcher/folder_open_dark');
    });

    testWidgets('grid with live tiles (4x2 + 2x2) — dark', (tester) async {
      await _pumpLauncher(
        tester,
        liveTiles: true,
        tileEngineFactory: _fakeTileEngineFactory(),
      );
      await expectGolden(tester, 'launcher/grid_widget_tile_dark');
    });

    testWidgets('grid with live tiles (4x2 + 2x2) — light', (tester) async {
      await _pumpLauncher(
        tester,
        liveTiles: true,
        tileEngineFactory: _fakeTileEngineFactory(),
        theme: buildFahThemeLight(),
      );
      await expectGolden(tester, 'launcher/grid_widget_tile_light');
    });

    /// The alignment showcase: a plain row of app icons sits ABOVE the 4x2
    /// weather widget, so a reviewer can see the widget's left/right edges
    /// line up EXACTLY with the outer edges of the 4-icon row (and the 2x2
    /// reminders widget with a 2-icon block) — the icon-unit geometry
    /// contract of LauncherGridSpec.
    testWidgets('ios alignment — widgets align with icon blocks', (
      tester,
    ) async {
      await _pumpLauncher(
        tester,
        liveTiles: true,
        tileEngineFactory: _fakeTileEngineFactory(),
        order: [
          'app:notes',
          'app:pomodoro',
          'app:habits',
          'app:dice',
          'app:weather',
          'app:reminders',
          LauncherLayoutStore.settingsKey,
          LauncherLayoutStore.filesKey,
        ],
      );
      await expectGolden(tester, 'launcher/grid_ios_alignment_dark');
    });

    /// AC4 of issue #166 (clamp, narrow): a 4x2 span on a 3-column grid
    /// renders full-width without overflow, the 1x3 steps widget stretches
    /// one cell wide and three tall beside the 2x2 reminders widget.
    testWidgets('custom spans clamp on a narrow grid — dark', (tester) async {
      await _pumpLauncher(
        tester,
        liveTiles: true,
        extraTiles: {'steps': '1x3'},
        gridColumns: 3,
        tileEngineFactory: _fakeTileEngineFactory(),
        order: [
          'app:weather',
          'app:steps',
          'app:reminders',
          'app:notes',
          'app:pomodoro',
          'app:habits',
          'app:dice',
          LauncherLayoutStore.settingsKey,
          LauncherLayoutStore.filesKey,
        ],
      );
      await expectGolden(tester, 'launcher/grid_span_clamp_narrow_dark');
    });

    /// AC4 of issue #166 (wide): the same span set on a wide 6-column
    /// desktop layout — nothing clamps, the 4x2 weather keeps 4 columns,
    /// the 1x3 steps widget stays one cell wide.
    testWidgets('custom spans on a wide grid — dark', (tester) async {
      await _pumpLauncher(
        tester,
        liveTiles: true,
        extraTiles: {'steps': '1x3'},
        size: goldenSizeDesktop,
        tileEngineFactory: _fakeTileEngineFactory(),
        order: [
          'app:weather',
          'app:steps',
          'app:reminders',
          'app:notes',
          'app:pomodoro',
          'app:habits',
          'app:dice',
          LauncherLayoutStore.settingsKey,
          LauncherLayoutStore.filesKey,
        ],
      );
      await expectGolden(tester, 'launcher/grid_span_wide_dark');
    });
  });
}
