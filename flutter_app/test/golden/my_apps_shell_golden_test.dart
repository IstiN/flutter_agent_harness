/// Golden (screenshot) tests for the unified "My Apps" surface —
/// `lib/ui/widgets/my_apps_shell.dart` — the panel variant that backs the
/// wide-layout right side AND the mobile home. Search bar, filter chips,
/// up-next/focus-timer widgets, sectioned app grid, recent-activity footer.
///
/// Apps are seeded into a `MemoryExecutionEnv` with inline-SVG manifest
/// icons (the golden font sandbox renders no emoji glyphs).
library;

import 'package:fa/apps/apps_store.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/pinned_apps_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/my_apps_shell.dart';
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

/// id → [display name, inline SVG icon, bundled flag].
/// Bundled ids match `AppsStore.demoAppIds` exactly — that's how
/// `MyAppsShell` distinguishes a demo from a user app, regardless of
/// what `bundled:` says on the manifest (AppsStore reads manifests back
/// with `bundled: false` after seeding).
Map<String, List<Object>> get _apps => {
  'weather': [
    'Weather',
    _badgeIcon(
      '#0ea5e9',
      "<circle cx='12' cy='12' r='5' fill='$_fg'/>"
          "<rect x='11' y='2' width='2' height='4' rx='1' fill='$_fg'/>"
          "<rect x='11' y='18' width='2' height='4' rx='1' fill='$_fg'/>"
          "<rect x='2' y='11' width='4' height='2' rx='1' fill='$_fg'/>"
          "<rect x='18' y='11' width='4' height='2' rx='1' fill='$_fg'/>",
    ),
    true,
  ],
  'calendar': [
    'Calendar',
    _badgeIcon(
      '#6366f1',
      "<rect x='3' y='5' width='18' height='16' rx='2' fill='none' "
          "stroke='$_fg' stroke-width='2'/><rect x='3' y='9' width='18' "
          "height='2' fill='$_fg'/><rect x='7' y='3' width='2' height='4' "
          "rx='1' fill='$_fg'/><rect x='15' y='3' width='2' height='4' "
          "rx='1' fill='$_fg'/>",
    ),
    true,
  ],
  'contacts': [
    'Contacts',
    _badgeIcon(
      '#22c55e',
      "<circle cx='12' cy='8' r='4' fill='$_fg'/>"
          "<path d='M4 20c0-4 4-6 8-6s8 2 8 6' fill='$_fg'/>",
    ),
    true,
  ],
  'reminders': [
    'Reminders',
    _badgeIcon(
      '#f43f5e',
      "<circle cx='12' cy='12' r='9' fill='none' stroke='$_fg' "
          "stroke-width='2'/><path d='M12 7v5l3 3' stroke='$_fg' "
          "stroke-width='2' fill='none' stroke-linecap='round' "
          "stroke-linejoin='round'/>",
    ),
    true,
  ],
  'fitness-trainer': [
    'Fitness Trainer',
    _badgeIcon(
      '#8b5cf6',
      "<rect x='5' y='10' width='2' height='4' rx='1' fill='$_fg'/>"
          "<rect x='17' y='10' width='2' height='4' rx='1' fill='$_fg'/>"
          "<rect x='7' y='11' width='10' height='2' rx='1' fill='$_fg'/>",
    ),
    true,
  ],
  'expense': [
    'Expense Tracker',
    _badgeIcon(
      '#059669',
      "<circle cx='12' cy='12' r='7' fill='none' stroke='$_fg' "
          "stroke-width='2'/><path d='M12 7v5l3 3' stroke='$_fg' "
          "stroke-width='2' fill='none' stroke-linecap='round'/>",
    ),
    false,
  ],
  'workout': [
    'Workout Planner',
    _badgeIcon(
      '#dc2626',
      "<rect x='5' y='9' width='14' height='6' rx='2' fill='none' "
          "stroke='$_fg' stroke-width='2'/><rect x='8' y='12' "
          "width='8' height='2' fill='$_fg'/>",
    ),
    false,
  ],
  'pomodoro': [
    'Pomodoro',
    _badgeIcon(
      '#f59e0b',
      "<circle cx='12' cy='13' r='6' fill='none' stroke='$_fg' "
          "stroke-width='2'/><rect x='10' y='4' width='4' height='2' rx='1' "
          "fill='$_fg'/><path d='M12 13 L12 9.5' stroke='$_fg' "
          "stroke-width='2' stroke-linecap='round'/>",
    ),
    false,
  ],
};

Future<MemoryExecutionEnv> _seededEnv() async {
  final env = MemoryExecutionEnv();
  for (final entry in _apps.entries) {
    await env.writeFile(
      'apps/${entry.key}/manifest.json',
      '{"id": "${entry.key}", "name": "${entry.value[0]}", '
          '"description": "${entry.value[0]} app", '
          '"icon": ${_jsonString(entry.value[1] as String)}, '
          '"bundled": ${entry.value[2]}}',
    );
    await env.writeFile('apps/${entry.key}/widget.js', '(function(){})();');
  }
  return env;
}

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

Future<void> _pumpMyAppsShell(
  WidgetTester tester, {
  ThemeData? theme,
  MyAppsShellMode mode = MyAppsShellMode.panel,
}) async {
  final env = await _seededEnv();
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
  final service = _fakeService(env);
  manager.addSession('test-session', service);
  final appsStore = AppsStore(
    env,
    readAsset: (path) async =>
        throw StateError('no bundled assets in this test'),
    seedDemoIds: const [],
  );
  await pumpGolden(
    tester,
    ManagerScope(
      manager: manager,
      child: MyAppsShell(manager: manager, appsStore: appsStore, mode: mode),
    ),
    // Right panel width (~380px) on a desktop-height surface.
    size: const Size(380, 800),
    theme: theme,
    wrap: (child) => Scaffold(body: child),
  );
}

void main() {
  setUpAll(ensureGoldenFonts);

  group('MyAppsShell goldens (my_apps_shell/)', () {
    testWidgets('apps panel — dark', (tester) async {
      await _pumpMyAppsShell(tester);
      await expectGolden(tester, 'my_apps_shell/panel_dark');
    });

    testWidgets('apps panel — light', (tester) async {
      await _pumpMyAppsShell(tester, theme: buildFahThemeLight());
      await expectGolden(tester, 'my_apps_shell/panel_light');
    });

    testWidgets('pinned filter — light', (tester) async {
      // Pin a couple of apps (one bundled, one custom) and tap the
      // Pinned filter chip — the grid should narrow to just those two.
      final env = await _seededEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      )..addSession('test-session', _fakeService(env));
      final appsStore = AppsStore(
        env,
        readAsset: (path) async =>
            throw StateError('no bundled assets in this test'),
        seedDemoIds: const [],
      );
      final pinned = PinnedAppsStore.inMemory(
        initial: {'weather', 'pomodoro'},
      );
      await pumpGolden(
        tester,
        ManagerScope(
          manager: manager,
          child: MyAppsShell(
            manager: manager,
            appsStore: appsStore,
            pinnedStore: pinned,
          ),
        ),
        size: const Size(380, 800),
        theme: buildFahThemeLight(),
        wrap: (child) => Scaffold(body: child),
      );
      // The Pinned chip is the fourth filter tab.
      await tester.tap(find.text('Pinned'));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'my_apps_shell/pinned_filter_light');
    });

    testWidgets('long-press a tile toggles the pin badge', (tester) async {
      // Confirms the gesture is wired: a long-press on an app tile
      // flips its pin state and the small pin badge appears on the
      // icon.
      final env = await _seededEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      )..addSession('test-session', _fakeService(env));
      final appsStore = AppsStore(
        env,
        readAsset: (path) async =>
            throw StateError('no bundled assets in this test'),
        seedDemoIds: const [],
      );
      final pinned = PinnedAppsStore.inMemory();
      await pumpGolden(
        tester,
        ManagerScope(
          manager: manager,
          child: MyAppsShell(
            manager: manager,
            appsStore: appsStore,
            pinnedStore: pinned,
          ),
        ),
        size: const Size(380, 800),
        theme: buildFahTheme(),
        wrap: (child) => Scaffold(body: child),
      );
      // Before long-press: no pin badges anywhere.
      expect(find.byIcon(Icons.push_pin), findsNothing);
      // Long-press the Calendar tile.
      final calendarTile = find.text('Calendar');
      expect(calendarTile, findsOneWidget);
      await tester.longPress(calendarTile);
      await tester.pumpAndSettle();
      // After long-press: one pin badge appears (on Calendar).
      expect(find.byIcon(Icons.push_pin), findsOneWidget);
      expect(pinned.isPinned('calendar'), isTrue);
      // Long-press again → unpin.
      await tester.longPress(calendarTile);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.push_pin), findsNothing);
      expect(pinned.isPinned('calendar'), isFalse);
    });
  });
}