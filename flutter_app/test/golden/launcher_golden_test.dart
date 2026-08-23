/// Golden (screenshot) tests for the apps launcher home:
/// `lib/ui/screens/app_launcher_screen.dart` (grid, folders, system tiles)
/// and, hosted over it, `lib/apps/session_chat_sheet.dart` — whose input
/// bar, sessions drawer and session panel states also exercise the shared
/// `ChatComposer` (`lib/ui/widgets/chat_composer.dart`).
///
/// Apps are seeded straight into a `MemoryExecutionEnv` (no bundled-asset
/// seeding) with inline-SVG manifest icons — the golden font sandbox renders
/// no emoji glyphs (see `apps_golden_test.dart`).
library;

import 'dart:async';

import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/session_names_store.dart';
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

/// A hung stream honoring aborts (the apps_golden_test.dart pattern): the
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

Future<MemoryExecutionEnv> _seededEnv({bool liveTiles = false}) async {
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
    await env.writeFile('apps/reminders/widget.js', '(function(){})();');
    await env.writeFile('apps/reminders/widget_tile.js', '(function(){})();');
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

  @override
  Future<void> start() async {
    tree.value = switch (app.id) {
      'weather' => _weatherTree,
      'reminders' => _remindersTree,
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

/// Pumps the launcher as the full app home at phone size. [folders] seeds a
/// pre-made folder layout (default: the four apps + system tiles).
/// [sessions] maps session ids to seeded transcript messages (the LAST id
/// is the active session). [liveTiles] adds two apps whose manifests
/// declare a `"widget"` section (weather 4x2, reminders 2x2) — pair it with
/// [tileEngineFactory] so the live tiles render deterministic trees.
Future<void> _pumpLauncher(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  ThemeData? theme,
  List<String>? order,
  List<LauncherFolder>? folders,
  Map<String, List<FahChatMessage>>? sessions,
  StreamFunction? streamFunction,
  bool liveTiles = false,
  TileEngineFactory? tileEngineFactory,
  EdgeInsets? viewPadding,
}) async {
  final env = await _seededEnv(liveTiles: liveTiles);
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
  for (final entry
      in (sessions ?? const {'fake-session': <FahChatMessage>[]}).entries) {
    final service = _fakeService(env, streamFunction);
    service.messages.addAll(entry.value);
    // Pinned creation time (deep in the past → the "Jan 5"-style branch):
    // the session tile's relative-time subtitle must not stamp the golden
    // with the RUN's clock.
    manager.addSession(entry.key, service, createdAt: DateTime(2026, 1, 5));
  }
  // Deterministic session chip in the header: the date-derived fallback
  // title would stamp every golden with the RUN's date. The manager lists
  // the ACTIVE session (sess-b, the dice-roller chat) first, so the canned
  // titles land in that order.
  final namesStore = await SessionNamesStore.load(env);
  final chipTitles = ['Dice roller', 'Weather app', 'Third chat'];
  for (final (i, session) in manager.sessions.indexed) {
    await namesStore.rename(session.id, chipTitles[i % chipTitles.length]);
  }
  final launcher = AppLauncherScreen(
    manager: manager,
    sessionNamesStore: namesStore,
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
    ),
    appsStore: _appsStore(env),
    tileEngineFactory: tileEngineFactory,
  );
  await pumpGolden(
    tester,
    viewPadding == null
        ? launcher
        // Simulate a notched phone (Dynamic Island + home indicator):
        // padding lets the SafeArea inset the stack, viewPadding drives
        // the sheet's floating/docked geometry. copyWith keeps the host
        // MediaQuery's size/pixel ratio intact.
        : Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(padding: viewPadding, viewPadding: viewPadding),
              child: launcher,
            ),
          ),
    size: goldenSizePhone,
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
  });

  group('SessionChatSheet state matrix (launcher/sheet_*)', () {
    /// The seeded conversation driving every sheet-state shot: sess-b
    /// (active, a finished dice-roller exchange) and sess-a (drawer row 2).
    Map<String, List<FahChatMessage>> twoSessions() => {
      'sess-a': [
        FahChatMessage(role: 'user', content: 'remind me what we decided'),
        FahChatMessage(
          role: 'assistant',
          content: 'We ship the launcher first, the chat sheet second.',
        ),
      ],
      'sess-b': [
        FahChatMessage(
          role: 'user',
          content: 'build me a tiny dice roller app',
        ),
        FahChatMessage(
          role: 'tool',
          toolName: 'write',
          content: 'apps/dice/widget.js (342 bytes)',
        ),
        FahChatMessage(
          role: 'assistant',
          content:
              'Done — **Dice Roller** is on your home grid now. Tap it to '
              'roll d4…d20.',
        ),
      ],
    };

    /// The sessions button in the bar's leading slot opens the drawer.
    Future<void> openDrawer(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('sessionChatDrawerButton')));
      await tester.pumpAndSettle();
    }

    /// Same as [openDrawer] but with timed pumps — usable while the
    /// streaming orbit animation keeps the tree from ever settling.
    Future<void> openDrawerWhileStreaming(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('sessionChatDrawerButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// The real user flow into a session: drawer → row tap → the panel
    /// slides up under the input bar.
    Future<void> openSessionPanel(WidgetTester tester, String id) async {
      await openDrawer(tester);
      await tester.tap(find.byKey(ValueKey('sessionChatDrawerEntry:$id')));
      await tester.pumpAndSettle();
    }

    /// Starts a hung run and pumps fixed frames until the streaming status
    /// row settles above the bar (the orbit repeats forever, so
    /// pumpAndSettle would time out).
    Future<void> startHungRun(WidgetTester tester) async {
      final service = tester
          .widget<AppLauncherScreen>(find.byType(AppLauncherScreen))
          .manager
          .active!
          .service;
      await tester.runAsync(() async {
        unawaited(service.sendText('roll a d20'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('input bar — dark', (tester) async {
      // The bar IS the default resting state — no gestures needed.
      await _pumpLauncher(tester, sessions: twoSessions());
      await expectGolden(tester, 'launcher/sheet_bar_dark');
    });

    testWidgets('input bar — light', (tester) async {
      await _pumpLauncher(
        tester,
        sessions: twoSessions(),
        theme: buildFahThemeLight(),
      );
      await expectGolden(tester, 'launcher/sheet_bar_light');
    });

    testWidgets('input bar streaming status row — dark', (tester) async {
      // Started outside the bar (no composer onSent): the panel stays
      // closed and the slim FaWorkBar status row sits above the composer.
      await _pumpLauncher(
        tester,
        sessions: {'sess-b': twoSessions()['sess-b']!},
        streamFunction: _hungResponse(),
      );
      await startHungRun(tester);
      await expectGolden(tester, 'launcher/sheet_bar_streaming_dark');
    });

    testWidgets('input bar streaming status row — light', (tester) async {
      await _pumpLauncher(
        tester,
        sessions: {'sess-b': twoSessions()['sess-b']!},
        streamFunction: _hungResponse(),
        theme: buildFahThemeLight(),
      );
      await startHungRun(tester);
      await expectGolden(tester, 'launcher/sheet_bar_streaming_light');
    });

    testWidgets('sessions drawer — dark', (tester) async {
      await _pumpLauncher(tester, sessions: twoSessions());
      await openDrawer(tester);
      await expectGolden(tester, 'launcher/sheet_drawer_dark');
    });

    testWidgets('sessions drawer — light', (tester) async {
      await _pumpLauncher(
        tester,
        sessions: twoSessions(),
        theme: buildFahThemeLight(),
      );
      await openDrawer(tester);
      await expectGolden(tester, 'launcher/sheet_drawer_light');
    });

    testWidgets('session panel — dark', (tester) async {
      await _pumpLauncher(tester, sessions: twoSessions());
      await openSessionPanel(tester, 'sess-b');
      await expectGolden(tester, 'launcher/sheet_session_dark');
    });

    testWidgets('session panel — ru', (tester) async {
      await _pumpLauncher(
        tester,
        locale: const Locale('ru'),
        sessions: twoSessions(),
      );
      await openSessionPanel(tester, 'sess-b');
      await expectGolden(tester, 'launcher/sheet_session_ru');
    });

    testWidgets('session panel — light', (tester) async {
      await _pumpLauncher(
        tester,
        sessions: twoSessions(),
        theme: buildFahThemeLight(),
      );
      await openSessionPanel(tester, 'sess-b');
      await expectGolden(tester, 'launcher/sheet_session_light');
    });

    testWidgets('session panel streaming — dark', (tester) async {
      await _pumpLauncher(
        tester,
        sessions: {'sess-b': twoSessions()['sess-b']!},
        streamFunction: _hungResponse(),
      );
      await startHungRun(tester);
      await openDrawerWhileStreaming(tester);
      await tester.tap(
        find.byKey(const ValueKey('sessionChatDrawerEntry:sess-b')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await expectGolden(tester, 'launcher/sheet_session_streaming_dark');
    });

    // iPhone 16 Pro insets: 59pt island top, 34pt home indicator bottom.
    const phoneInsets = EdgeInsets.only(top: 59, bottom: 34);

    testWidgets('input bar on a notched phone — dark', (tester) async {
      await _pumpLauncher(
        tester,
        sessions: twoSessions(),
        viewPadding: phoneInsets,
      );
      await expectGolden(tester, 'launcher/sheet_bar_insets_dark');
    });

    testWidgets('session panel on a notched phone — dark', (tester) async {
      await _pumpLauncher(
        tester,
        sessions: twoSessions(),
        viewPadding: phoneInsets,
      );
      await openSessionPanel(tester, 'sess-b');
      await expectGolden(tester, 'launcher/sheet_session_insets_dark');
    });

    testWidgets('session panel on a notched phone — light', (tester) async {
      await _pumpLauncher(
        tester,
        sessions: twoSessions(),
        theme: buildFahThemeLight(),
        viewPadding: phoneInsets,
      );
      await openSessionPanel(tester, 'sess-b');
      await expectGolden(tester, 'launcher/sheet_session_insets_light');
    });
  });
}
