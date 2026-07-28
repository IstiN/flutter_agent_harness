/// Golden (screenshot) tests for the apps launcher home:
/// `lib/ui/screens/app_launcher_screen.dart` (grid, folders, system tiles)
/// and, hosted over it, `lib/apps/session_chat_sheet.dart`.
///
/// Apps are seeded straight into a `MemoryExecutionEnv` (no bundled-asset
/// seeding) with inline-SVG manifest icons — the golden font sandbox renders
/// no emoji glyphs (see `apps_golden_test.dart`).
library;

import 'dart:async';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/session_chat_sheet.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/widgets/chat_composer.dart';
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
      systemPrompt: 'You are fah.',
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

Future<MemoryExecutionEnv> _seededEnv() async {
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

AppsStore _appsStore(MemoryExecutionEnv env) => AppsStore(
  env,
  readAsset: (path) async => throw StateError('no bundled assets in this test'),
  seedDemoIds: const [],
);

/// Pumps the launcher as the full app home at phone size. [folders] seeds a
/// pre-made folder layout (default: the four apps + system tiles).
/// [sessions] maps session ids to seeded transcript messages (the LAST id
/// is the active session).
Future<void> _pumpLauncher(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  ThemeData? theme,
  List<String>? order,
  List<LauncherFolder>? folders,
  Map<String, List<FahChatMessage>>? sessions,
  StreamFunction? streamFunction,
}) async {
  final env = await _seededEnv();
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
  for (final entry
      in (sessions ?? const {'fake-session': <FahChatMessage>[]}).entries) {
    final service = _fakeService(env, streamFunction);
    service.messages.addAll(entry.value);
    manager.addSession(entry.key, service);
  }
  await pumpGolden(
    tester,
    AppLauncherScreen(
      manager: manager,
      layoutStore: LauncherLayoutStore.inMemory(
        order:
            order ??
            [
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
    ),
    size: goldenSizePhone,
    locale: locale,
    theme: theme,
    wrap: (child) => child,
  );
}

void main() {
  setUpAll(ensureGoldenFonts);

  group('AppLauncherScreen goldens', () {
    testWidgets('launcher grid — phone', (tester) async {
      await _pumpLauncher(tester);
      await expectGolden(tester, 'launcher_grid');
    });

    testWidgets('launcher grid — phone, ru', (tester) async {
      await _pumpLauncher(tester, locale: const Locale('ru'));
      await expectGolden(tester, 'launcher_grid_ru');
    });

    testWidgets('folder open — phone', (tester) async {
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
      await expectGolden(tester, 'launcher_folder_open');
    });
  });

  group('SessionChatSheet goldens (over the launcher)', () {
    /// The seeded conversation for the expanded-sheet shots.
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

    Future<void> expandSheet(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('sessionChatFaButton')));
      await tester.pumpAndSettle();
    }

    testWidgets('sheet collapsed while streaming shows the work bar', (
      tester,
    ) async {
      await _pumpLauncher(
        tester,
        sessions: {'sess-b': twoSessions()['sess-b']!},
        streamFunction: _hungResponse(),
      );
      // Start the run, then freeze on fixed frames: the work bar's orbit
      // animation repeats forever, so pumpAndSettle would time out.
      final service = tester
          .widget<AppLauncherScreen>(find.byType(AppLauncherScreen))
          .manager
          .active!
          .service;
      await tester.runAsync(() async {
        unawaited(service.sendText('roll a d20'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await expectGolden(tester, 'launcher_sheet_streaming');
    });

    testWidgets('sheet expanded — transcript, header, composer', (
      tester,
    ) async {
      await _pumpLauncher(tester, sessions: twoSessions());
      await expandSheet(tester);
      expect(find.byType(SessionChatSheet), findsOneWidget);
      expect(find.byType(ChatComposer), findsOneWidget);
      await expectGolden(tester, 'launcher_sheet_expanded');
    });

    testWidgets('sheet expanded — ru', (tester) async {
      await _pumpLauncher(
        tester,
        locale: const Locale('ru'),
        sessions: twoSessions(),
      );
      await expandSheet(tester);
      await expectGolden(tester, 'launcher_sheet_expanded_ru');
    });

    testWidgets('sheet expanded — light theme (safe-area handle visible)', (
      tester,
    ) async {
      await _pumpLauncher(
        tester,
        sessions: twoSessions(),
        theme: buildFahThemeLight(),
      );
      await expandSheet(tester);
      await expectGolden(tester, 'launcher_sheet_expanded_light');
    });

    testWidgets('sheet pager — second session', (tester) async {
      await _pumpLauncher(tester, sessions: twoSessions());
      await expandSheet(tester);
      await tester.fling(
        find.byKey(const ValueKey('sessionChatPager')),
        const Offset(-300, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.text('session sess-a'), findsOneWidget);
      await expectGolden(tester, 'launcher_sheet_pager2');
    });
  });
}
