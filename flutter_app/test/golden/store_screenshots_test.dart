/// App Store screenshot generator: real app screens at real device
/// resolutions, composited into the [StoreFrame] marketing canvas and
/// committed under `test/goldens/store/<lang>/<device>/`. The
/// `ios app_store` / `mac app_store` fastlane lanes upload these PNGs to
/// App Store Connect, so they are marketing material: full app frames,
/// real fonts, deterministic content, localized UI (en + ru).
///
/// Regenerate with:
/// `flutter test test/golden/store_screenshots_test.dart --update-goldens`
/// — then OPEN every PNG (no tofu, no overflow) before committing.
///
/// The five frames tell one continuous story — "your own apps, built by
/// chat" (the first mobile agent harness):
///  1. store_chat — THE ASK: the user asks Fa to build a personal weather
///     app with a dashboard widget; tool-call tiles write the manifest,
///     the app and the widget, then `open_app` opens it.
///  2. store_apps — THE DASHBOARD: the apps-launcher home grid with LIVE
///     widget tiles (the just-built weather app as a 4x2 widget) and the
///     mini session-chat bar docked at the bottom.
///  3. store_inapp — THE APP + FA INSIDE: the weather app open with the
///     session chat sheet pulled up over it — a follow-up ("add a weekly
///     forecast") without leaving the app.
///  4. store_media — generation capabilities: an inline generated
///     wallpaper, a video clip tile and a voice-summary player in chat.
///  5. store_providers — any provider, keys in the Keychain.
///
/// The generated wallpaper inside the media frame is a REAL picture (see
/// `test/golden/assets/store/README.md`), loaded once in `setUpAll` and
/// written into the in-memory sandbox — tests never touch the network.
///
/// Devices (App Store sizes): iPhone 6.9" 1290x2796 @3x, iPad Pro 13"
/// 2064x2752 @2x, Mac 2560x1600 @2x. All fakes and pump dances are the
/// proven patterns from the sibling golden tests (chat/launcher/apps/
/// settings) — no network, no clocks, no real JS engine.
library;

import 'dart:convert';
import 'dart:io';

import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/apps/session_chat_sheet.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/screens/providers_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_media_controllers.dart';
import 'golden_test_helper.dart';
import 'store_marketing_frame.dart';

/// App Store device targets: output pixel size + device pixel ratio.
typedef _Device = ({String name, Size physical, double dpr});

const _devices = <_Device>[
  (name: 'ios', physical: Size(1290, 2796), dpr: 3.0),
  (name: 'ipad', physical: Size(2064, 2752), dpr: 2.0),
  (name: 'mac', physical: Size(2560, 1600), dpr: 2.0),
];

const _locales = [Locale('en'), Locale('ru')];

/// The real photo inside the media frame (see assets/store/README.md),
/// written into the in-memory sandbox as the "generated" wallpaper.
late Uint8List _wallpaperBytes;

// --- Service fakes (verbatim patterns from chat/launcher golden tests) -----

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

// --- Story scaffolding ------------------------------------------------------

/// The story session ids.
const _weatherSessionId = 'a11ce001-weather-app';
const _wallpaperSessionId = 'b22ce002-wallpaper';
const _notesSessionId = 'c33ce003-notes';

/// The story sessions shown in the chat sheet header (and kept in the
/// manager for realism): the app-build chat, the wallpaper session and a
/// persisted one. Titles ride the `session_names.json` overlay the stores
/// load from the env (or `SessionNamesStore.inMemory` where a store can be
/// injected).
Map<String, String> _sessionNames(String lang) => lang == 'ru'
    ? {
        _weatherSessionId: 'Приложение погоды',
        _wallpaperSessionId: 'Обои для дашборда',
        _notesSessionId: 'Идеи виджета заметок',
      }
    : {
        _weatherSessionId: 'Weather app',
        _wallpaperSessionId: 'Dashboard wallpaper',
        _notesSessionId: 'Notes widget ideas',
      };

/// Writes the session-titles overlay exactly where `SessionNamesStore`
/// reads it (`<cwd>/session_names.json`, envelope version 1).
Future<void> _seedSessionNames(MemoryExecutionEnv env, String lang) {
  return env.writeFile(
    '${env.cwd}/session_names.json',
    jsonEncode({'version': 1, 'names': _sessionNames(lang)}),
  );
}

/// A session manager with the story sessions: [activeId]/[active] holds
/// the hero conversation, one more live session, one persisted on disk.
Future<FlutterSessionManager> _storyManager(
  MemoryExecutionEnv env,
  String activeId,
  AgentService active,
) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  await repo.create(
    JsonlSessionCreateOptions(
      id: _notesSessionId,
      cwd: 'apps',
      metadata: const {'agent': 'fa', 'model': 'old-model'},
    ),
  );
  final otherId = activeId == _weatherSessionId
      ? _wallpaperSessionId
      : _weatherSessionId;
  return FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession(otherId, _fakeService(env))
    ..addSession(activeId, active);
}

// --- Frame pump helpers -----------------------------------------------------

/// Pumps [child] inside the [StoreFrame] at the device's exact App Store
/// pixel size, with the app's theme + localization at [locale].
Future<void> _pumpStore(
  WidgetTester tester,
  Widget child, {
  required _Device device,
  required Locale locale,
  required String screen,
}) async {
  tester.view.physicalSize = device.physical;
  tester.view.devicePixelRatio = device.dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      // A fresh key per capture: looped captures reuse the widget position,
      // and without a new key the ChatScreen state (and its message
      // controller) would survive and show the previous capture's messages.
      key: ValueKey('store-${device.name}-${locale.languageCode}-$screen'),
      debugShowCheckedModeBanner: false,
      theme: buildFahTheme(),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: StoreFrame(screen: screen, lang: locale.languageCode, child: child),
    ),
  );
}

Future<void> _expectStore(
  WidgetTester tester,
  _Device device,
  Locale locale,
  String screen,
) {
  return expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile(
      '../goldens/store/${locale.languageCode}/${device.name}/$screen.png',
    ),
  );
}

/// Lets sandbox reads + image codec decodes (real async hops) land: the
/// fake-zone `pumpAndSettle` never waits for them, so alternate real
/// event-loop delays with pumps.
Future<void> _settleRealAsync(
  WidgetTester tester, {
  int rounds = 24,
  int stepMs = 100,
}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration(milliseconds: stepMs));
      await tester.pump();
    }
  });
}

/// Pins every Scrollable to its tail (the chat list after image loads grew
/// the content; short side lists are unaffected).
void _jumpScrollablesToTail(WidgetTester tester) {
  for (final element in find.byType(Scrollable).evaluate()) {
    final state = (element as StatefulElement).state as ScrollableState;
    state.position.jumpTo(state.position.maxScrollExtent);
  }
}

// --- The story conversations ------------------------------------------------

/// Frame 1 (and the dashboard mini bar): the user asks Fa to build a
/// personal weather app; the tool tiles write the manifest, the app and
/// the live widget, then `open_app` opens the result.
List<FahChatMessage> _weatherBuildConversation(String lang) {
  final ru = lang == 'ru';
  return [
    FahChatMessage(
      role: 'user',
      content: ru
          ? 'Сделай приложение погоды для Минска с живым виджетом '
                'на дашборд.'
          : 'Build me a weather app for Minsk with a live dashboard widget.',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'write',
      content: 'apps/weather/manifest.json (214 bytes)',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'write',
      content: 'apps/weather/widget.js (1841 bytes)',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'write',
      content: 'apps/weather/widget_tile.js (967 bytes)',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'open_app',
      content: 'Opened "Weather" (apps/weather).',
    ),
    FahChatMessage(
      role: 'assistant',
      content: ru
          ? 'Готово — **Погода** собрана и уже на домашнем экране. Виджет '
                '4×2 показывает Минск: 21°, переменная облачность. Нажмите '
                'на виджет, чтобы открыть весь прогноз.'
          : 'Done — **Weather** is built and already on your home screen. '
                'The 4×2 widget shows Minsk: 21°, partly cloudy. Tap the '
                'tile to open the full forecast.',
    ),
  ];
}

/// Frame 3 (the sheet over the open app): a follow-up tweak without
/// leaving the weather app.
List<FahChatMessage> _inappConversation(String lang) {
  final ru = lang == 'ru';
  return [
    FahChatMessage(
      role: 'user',
      content: ru
          ? 'Добавь в приложение прогноз на неделю'
          : 'Add a weekly forecast to the app',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'write',
      content: 'apps/weather/widget.js (2310 bytes)',
    ),
    FahChatMessage(
      role: 'assistant',
      content: ru
          ? 'Готово — теперь в приложении прогноз на всю неделю, а виджет '
                'на дашборде уже обновился.'
          : 'Done — the app now shows the whole week, and the dashboard '
                'widget picked up the update too.',
    ),
  ];
}

/// Frame 4: the generation tools — a wallpaper image inline, a video clip
/// tile and a voice-summary player.
List<FahChatMessage> _mediaConversation(String lang) {
  final ru = lang == 'ru';
  return [
    FahChatMessage(
      role: 'user',
      content: ru
          ? 'Дашборд выглядит пустовато — сгенерируй спокойные обои для '
                'него, короткий ролик с облаками и зачитай прогноз на '
                'сегодня.'
          : 'My dashboard feels plain — generate a calm wallpaper for it, '
                'a short clouds clip, and read me today\'s forecast aloud.',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'generate_video',
      content: 'Video saved to generated/clouds-loop.mp4 (~4 s, 1280x720).',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'generate_image',
      content:
          'Generated image saved to generated/dashboard-wallpaper.png '
          '(41934 bytes, 900x600). Reference it as '
          '![image](generated/dashboard-wallpaper.png) to display it inline '
          'in the chat.',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'speak',
      content: 'Speech saved to generated/forecast.mp3 (voice "alloy", ~7 s).',
    ),
    FahChatMessage(
      role: 'assistant',
      content: ru
          ? 'Всё готово:\n\n'
                '- **Обои** — спокойное озеро выше, нажмите для просмотра\n'
                '- **Ролик с облаками** — 4 секунды, для фона виджета\n'
                '- **Прогноз** — голосовая сводка прямо над этим сообщением'
          : 'All set:\n\n'
                '- **Wallpaper** — the calm lake above; tap to preview\n'
                '- **Clouds clip** — a 4 s loop for the widget background\n'
                '- **Forecast** — the audio summary is right above this',
    ),
  ];
}

// --- Frame 1: store_chat — the ask ------------------------------------------

/// store_chat: the full ChatScreen with the app-build conversation (the
/// session sidebar is gone — sessions live in the launcher's chat sheet —
/// so the shot is the pure conversation on every device).
Future<void> _chatShot(
  WidgetTester tester,
  _Device device,
  Locale locale,
) async {
  final env = MemoryExecutionEnv();
  await _seedSessionNames(env, locale.languageCode);
  final service = _fakeService(env);
  service.messages.addAll(_weatherBuildConversation(locale.languageCode));
  final manager = await _storyManager(env, _weatherSessionId, service);

  await _pumpStore(
    tester,
    ChatScreen(manager: manager),
    device: device,
    locale: locale,
    screen: 'store_chat',
  );
  // Flush fake-time debounces (the message sync) with bounded pumps —
  // pumpAndSettle is not safe here (intermittent settle timeouts).
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  _jumpScrollablesToTail(tester);
  await tester.pump();
  // Let the list's scroll-to-bottom button fade out after the tail jump.
  await tester.pump(const Duration(milliseconds: 400));
  await _expectStore(tester, device, locale, 'store_chat');
}

// --- Frame 2: store_apps — the dashboard ------------------------------------

/// A rounded-square badge icon with a white glyph shape (renders with the
/// golden fonts — no emoji; the launcher golden test pattern).
String _badgeIcon(String bg, String shape) =>
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'>"
    "<rect x='1' y='1' width='22' height='22' rx='6' fill='$bg'/>"
    '$shape</svg>';

const _fg = '#f8fafc';

/// The sun badge of the story's weather app (icon + live 4x2 widget).
final _weatherSvgIcon = _badgeIcon(
  '#0ea5e9',
  "<circle cx='12' cy='12' r='5' fill='$_fg'/>"
      "<rect x='11' y='2' width='2' height='4' rx='1' fill='$_fg'/>"
      "<rect x='11' y='18' width='2' height='4' rx='1' fill='$_fg'/>"
      "<rect x='2' y='11' width='4' height='2' rx='1' fill='$_fg'/>"
      "<rect x='18' y='11' width='4' height='2' rx='1' fill='$_fg'/>",
);

final _bellSvgIcon = _badgeIcon(
  '#f59e0b',
  "<path d='M12 4a6 6 0 0 0-6 6v3l-2 4h16l-2-4v-3a6 6 0 0 0-6-6z' "
      "fill='$_fg'/><circle cx='12' cy='19' r='2' fill='$_fg'/>",
);

/// id → [display name, inline SVG icon] for the static app tiles.
Map<String, List<String>> get _staticApps => {
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
  'calendar': [
    'Calendar',
    _badgeIcon(
      '#3b82f6',
      "<rect x='6' y='6' width='12' height='2.6' rx='1.3' fill='$_fg'/>"
          "<circle cx='8.5' cy='12' r='1.3' fill='$_fg'/>"
          "<circle cx='12' cy='12' r='1.3' fill='$_fg'/>"
          "<circle cx='15.5' cy='12' r='1.3' fill='$_fg'/>"
          "<circle cx='8.5' cy='16' r='1.3' fill='$_fg'/>"
          "<circle cx='12' cy='16' r='1.3' fill='$_fg'/>",
    ),
  ],
  'map': [
    'Map',
    _badgeIcon(
      '#ef4444',
      "<path d='M12 5 C9.2 5 7 7.2 7 10 C7 13.6 12 19 12 19 C12 19 17 13.6 "
          "17 10 C17 7.2 14.8 5 12 5 Z' fill='$_fg'/>"
          "<circle cx='12' cy='10' r='2' fill='#ef4444'/>",
    ),
  ],
  'stocks': [
    'Stocks',
    _badgeIcon(
      '#10b981',
      "<path d='M6 16.5 L10 11.5 L13 14 L18 7.5' stroke='$_fg' "
          "stroke-width='2' fill='none' stroke-linecap='round' "
          "stroke-linejoin='round'/><circle cx='18' cy='7.5' r='1.6' "
          "fill='$_fg'/>",
    ),
  ],
  'crypto': [
    'Crypto',
    _badgeIcon(
      '#f97316',
      "<circle cx='12' cy='12' r='6.2' fill='none' stroke='$_fg' "
          "stroke-width='1.8'/><path d='M12.9 7.5 L10.2 12.3 L12.1 12.3 "
          "L11.1 16.5 L13.8 11.7 L11.9 11.7 Z' fill='$_fg'/>",
    ),
  ],
};

/// Seeds the launcher's apps into the env (no bundled-asset seeding):
/// the story's weather app with a live 4x2 widget tile, a reminders app
/// with a 2x2 tile, and eight static-icon apps.
Future<MemoryExecutionEnv> _seededLauncherEnv() async {
  final env = MemoryExecutionEnv();
  Future<void> app(String id, String manifest) async {
    await env.writeFile('apps/$id/manifest.json', manifest);
    await env.writeFile('apps/$id/widget.js', '(function(){})();');
  }

  await app(
    'weather',
    '{"id": "weather", "name": "Weather", "description": "Weather app", '
        '"icon": ${_jsonString(_weatherSvgIcon)}, '
        '"widget": {"entry": "widget_tile.js", "size": "4x2", '
        '"refreshSeconds": 900}}',
  );
  await env.writeFile('apps/weather/widget_tile.js', '(function(){})();');
  await app(
    'reminders',
    '{"id": "reminders", "name": "Reminders", '
        '"description": "Reminders app", '
        '"icon": ${_jsonString(_bellSvgIcon)}, '
        '"widget": {"entry": "widget_tile.js", "size": "2x2"}}',
  );
  await env.writeFile('apps/reminders/widget_tile.js', '(function(){})();');
  for (final entry in _staticApps.entries) {
    await app(
      entry.key,
      '{"id": "${entry.key}", "name": "${entry.value[0]}", '
      '"description": "${entry.value[0]} app", '
      '"icon": ${_jsonString(entry.value[1])}}',
    );
  }
  return env;
}

/// Fake tile engine emitting deterministic per-app tile trees so the
/// live-tile goldens stay pixel-stable (no JavaScriptCore boot) — the
/// launcher golden test pattern, localized for the store frames.
final class _FakeTileEngine extends JsAppEngine {
  _FakeTileEngine({
    required super.app,
    required super.env,
    required super.permissions,
    super.initialTheme,
    required this.lang,
  });

  final String lang;

  Map<String, dynamic> get _weatherTree => {
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
              'data': lang == 'ru' ? 'Минск' : 'Minsk',
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
              'data': lang == 'ru' ? 'Переменная облачность' : 'Partly cloudy',
              'style': {'fontSize': 11},
            },
          ],
        },
      ],
    },
  };

  Map<String, dynamic> get _remindersTree => {
    'type': 'container',
    'padding': [12, 10, 12, 10],
    'child': {
      'type': 'column',
      'mainAxisAlignment': 'center',
      'crossAxisAlignment': 'stretch',
      'children': [
        for (final item
            in lang == 'ru'
                ? [('Стоматолог', '25м'), ('Звонок Ане', '1ч 10м')]
                : [('Dentist', '25m'), ('Call Anna', '1h 10m')]) ...[
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
                  'data': item.$1,
                  'maxLines': 1,
                  'overflow': 'ellipsis',
                  'style': {'fontSize': 12, 'fontWeight': 'w600'},
                },
              },
              {
                'type': 'text',
                'data': item.$2,
                'style': {'fontSize': 10},
              },
            ],
          },
          if (item.$1 != (lang == 'ru' ? 'Звонок Ане' : 'Call Anna'))
            {'type': 'sizedBox', 'height': 8},
        ],
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

TileEngineFactory _fakeTileEngineFactory(String lang) =>
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
      lang: lang,
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

/// store_apps: the apps-launcher home — live widget tiles (the just-built
/// weather app as a 4x2 widget, reminders 2x2), static app icons, the
/// system tiles and the mini session-chat bar docked at the bottom. Also
/// serves the square promo shot ([golden] = `store_promo`).
Future<void> _appsShot(
  WidgetTester tester,
  _Device device,
  Locale locale, {
  String golden = 'store_apps',
}) async {
  final lang = locale.languageCode;
  final env = await _seededLauncherEnv();
  final service = _fakeService(env);
  service.messages.addAll(_weatherBuildConversation(lang));
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession(_weatherSessionId, service);

  await _pumpStore(
    tester,
    AppLauncherScreen(
      manager: manager,
      layoutStore: LauncherLayoutStore.inMemory(
        order: const [
          'app:weather',
          'app:reminders',
          'app:notes',
          'app:pomodoro',
          'app:habits',
          'app:dice',
          'app:calendar',
          'app:map',
          'app:stocks',
          'app:crypto',
          LauncherLayoutStore.settingsKey,
          LauncherLayoutStore.filesKey,
        ],
      ),
      appsStore: AppsStore(
        env,
        readAsset: (path) async =>
            throw StateError('no bundled assets in this test'),
        seedDemoIds: const [],
      ),
      sessionNamesStore: SessionNamesStore.inMemory(_sessionNames(lang)),
      tileEngineFactory: _fakeTileEngineFactory(lang),
    ),
    device: device,
    locale: locale,
    screen: 'store_apps',
  );
  await tester.pumpAndSettle();
  await _expectStore(tester, device, locale, golden);
}

/// The square marketing promo (App Review / social artwork): the same
/// dashboard composition as store_apps at 1024×1024.
Future<void> _promoShot(WidgetTester tester, Locale locale) {
  const device = (name: 'promo', physical: Size(1024, 1024), dpr: 1.0);
  return _appsShot(tester, device, locale, golden: 'store_promo');
}

// --- Frame 3: store_inapp — Fa inside the weather app -----------------------

/// One hourly-forecast cell in the hand-built weather canvas.
Widget _hourCell(FahColors colors, String hour, IconData icon, String temp) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(hour, style: TextStyle(fontSize: 11, color: colors.dim)),
      const SizedBox(height: 6),
      Icon(icon, size: 20, color: FahPalette.text),
      const SizedBox(height: 6),
      Text(
        temp,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ],
  );
}

/// One daily-forecast row in the weather canvas.
Widget _dayRow(
  FahColors colors,
  String day,
  IconData icon,
  Color iconColor,
  String temps,
) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
    child: Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            day,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        Icon(icon, size: 18, color: iconColor),
        const Spacer(),
        Text(temps, style: TextStyle(fontSize: 13, color: colors.dim)),
      ],
    ),
  );
}

/// The hand-built weather app canvas (same trick as the calculator canvas
/// in the apps golden tests — no JS engine): hero block on top, an hourly
/// strip and the week the frame-3 follow-up added.
Widget _weatherCanvas(String lang) {
  const colors = FahColors.dark;
  final ru = lang == 'ru';
  return ColoredBox(
    color: colors.bg,
    child: SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  FahPalette.indigo.withValues(alpha: 0.28),
                  colors.bg.withValues(alpha: 0),
                ],
              ),
            ),
            child: Column(
              children: [
                Text(
                  ru ? 'Минск' : 'Minsk',
                  style: TextStyle(fontSize: 15, color: colors.dim),
                ),
                const SizedBox(height: 2),
                const Text(
                  '21°',
                  style: TextStyle(fontSize: 64, fontWeight: FontWeight.w700),
                ),
                Text(
                  ru ? 'Переменная облачность' : 'Partly cloudy',
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  ru ? 'Макс. 23° · мин. 15°' : 'H 23° · L 15°',
                  style: TextStyle(fontSize: 12, color: colors.dim),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _hourCell(colors, ru ? 'Сейчас' : 'Now', Icons.wb_sunny, '21°'),
                _hourCell(colors, '15:00', Icons.wb_sunny, '22°'),
                _hourCell(colors, '16:00', Icons.wb_cloudy, '22°'),
                _hourCell(colors, '17:00', Icons.cloud, '20°'),
                _hourCell(colors, '18:00', Icons.cloud, '19°'),
              ],
            ),
          ),
          Divider(height: 16, color: colors.border),
          _dayRow(
            colors,
            ru ? 'Вт' : 'Tue',
            Icons.wb_sunny,
            const Color(0xFFFBBF24),
            '24° / 16°',
          ),
          _dayRow(
            colors,
            ru ? 'Ср' : 'Wed',
            Icons.wb_cloudy,
            const Color(0xFF94A3B8),
            '21° / 14°',
          ),
          _dayRow(
            colors,
            ru ? 'Чт' : 'Thu',
            Icons.umbrella,
            const Color(0xFF60A5FA),
            '18° / 12°',
          ),
          _dayRow(
            colors,
            ru ? 'Пт' : 'Fri',
            Icons.wb_sunny,
            const Color(0xFFFBBF24),
            '23° / 15°',
          ),
        ],
      ),
    ),
  );
}

/// A JsAppView-like scaffold for the weather app with the session chat
/// sheet hosted over the canvas (the launcher pattern, reused in-app).
/// The sheet sizes itself off `MediaQuery` (expanded = 92% of the reported
/// height), so the inner MediaQuery reports a height that lands the
/// expanded sheet's top edge right below the canvas's hourly strip
/// ([_kSheetTopInset] px from the body top) — the hero block and the
/// hourly forecast stay fully visible above the sheet on every device.
Widget _weatherAppHost(
  MemoryExecutionEnv env,
  FlutterSessionManager manager,
  String lang,
) {
  final weatherApp = JsAppInfo.fromManifest(
    {'id': 'weather', 'name': 'Weather', 'icon': _weatherSvgIcon},
    bundled: false,
    fallbackId: 'weather',
  );
  return Scaffold(
    appBar: AppBar(
      title: Row(
        children: [
          AppIcon(app: weatherApp, env: env, size: 24),
          const SizedBox(width: 8),
          const Flexible(
            child: Text('Weather', overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      actions: [
        IconButton(icon: const Icon(Icons.shield_outlined), onPressed: () {}),
        IconButton(icon: const Icon(Icons.refresh), onPressed: () {}),
      ],
    ),
    body: LayoutBuilder(
      builder: (context, constraints) {
        // expandedH = 0.92 * reported height = body height minus the inset.
        final mediaHeight = (constraints.maxHeight - _kSheetTopInset) / 0.92;
        return Stack(
          children: [
            Positioned.fill(child: _weatherCanvas(lang)),
            Positioned.fill(
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(size: Size(constraints.maxWidth, mediaHeight)),
                child: SessionChatSheet(
                  manager: manager,
                  sessionNamesStore: SessionNamesStore.inMemory(
                    _sessionNames(lang),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// Body-top inset where the expanded chat sheet's top edge lands in the
/// store_inapp frame: just below the weather canvas's hourly strip
/// (hero block + hourly row + divider).
const _kSheetTopInset = 292.0;

/// store_inapp: the follow-up edit ("add a weekly forecast") done from the
/// session chat sheet pulled up over the weather app.
Future<void> _inappShot(
  WidgetTester tester,
  _Device device,
  Locale locale,
) async {
  final lang = locale.languageCode;
  final env = MemoryExecutionEnv();
  final service = _fakeService(env);
  service.messages.addAll(_inappConversation(lang));
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession(_weatherSessionId, service);

  await _pumpStore(
    tester,
    _weatherAppHost(env, manager, lang),
    device: device,
    locale: locale,
    screen: 'store_inapp',
  );
  await tester.pumpAndSettle();
  // From the mini bar (the default resting state), a tap opens the sheet —
  // the mini bar has no handle, the drag zone key is a stable tap target.
  await tester.tap(find.byKey(const ValueKey('sessionChatMiniDragZone')));
  await tester.pumpAndSettle();
  _jumpScrollablesToTail(tester);
  await tester.pump();
  await _expectStore(tester, device, locale, 'store_inapp');
}

// --- Frame 4: store_media — generated image, clip and voice -----------------

/// store_media: the full ChatScreen with the media conversation — the
/// generated wallpaper inline, the clouds-clip video tile and the
/// voice-summary player (fake media controllers, real image bytes staged
/// in the in-memory sandbox).
Future<void> _mediaShot(
  WidgetTester tester,
  _Device device,
  Locale locale,
) async {
  final env = MemoryExecutionEnv();
  await env.writeBinaryFile(
    'generated/dashboard-wallpaper.png',
    _wallpaperBytes,
  );
  await env.writeBinaryFile(
    'generated/forecast.mp3',
    Uint8List.fromList(List<int>.filled(64, 7)),
  );
  await env.writeBinaryFile(
    'generated/clouds-loop.mp4',
    Uint8List.fromList(List<int>.filled(64, 9)),
  );
  await _seedSessionNames(env, locale.languageCode);
  final service = _fakeService(env);
  service.messages.addAll(_mediaConversation(locale.languageCode));
  final manager = await _storyManager(env, _wallpaperSessionId, service);

  await _pumpStore(
    tester,
    ChatScreen(
      manager: manager,
      audioControllerFactory: (bytes) =>
          FakeAudioController(duration: const Duration(seconds: 7)),
      videoControllerFactory: (path, bytes) =>
          FakeVideoController(duration: const Duration(seconds: 4)),
    ),
    device: device,
    locale: locale,
    screen: 'store_media',
  );
  // The env image reads + codec resolve on the real event loop.
  await _settleRealAsync(tester);
  // Flush fake-time debounces (the message sync) with bounded pumps —
  // pumpAndSettle is not safe here (intermittent settle timeouts).
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  // The inline image inside the tool tile starts loading only after the
  // tile's first frame — give the real event loop more time.
  await _settleRealAsync(tester, rounds: 12);
  // Pin the chat to the tail: image loads grew the content after the last
  // follow-scroll, so jump deterministically, let the newly built tail
  // decode, then jump again (the content grew meanwhile).
  _jumpScrollablesToTail(tester);
  await tester.pump();
  await _settleRealAsync(tester, rounds: 12);
  _jumpScrollablesToTail(tester);
  await tester.pump();
  // Let the list's scroll-to-bottom button fade out after the tail jump.
  await tester.pump(const Duration(milliseconds: 400));
  await _expectStore(tester, device, locale, 'store_media');
}

// --- Frame 5: store_providers — any provider, keys in the Keychain ----------

/// The settings frame: app bar + padded scroll view with a max-width column,
/// like `SettingsScreen` does; the FilledButton label font pinned to Inter
/// (see settings_golden_test.dart for why).
Widget _settingsFrame(BuildContext context, Widget child) {
  final theme = Theme.of(context);
  return Theme(
    data: theme.copyWith(
      filledButtonTheme: FilledButtonThemeData(
        style: theme.filledButtonTheme.style?.copyWith(
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
          ),
        ),
      ),
    ),
    child: Scaffold(
      appBar: AppBar(title: Text(context.l10n.settingsTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

/// store_providers: the providers-first settings list — the OpenRouter
/// preset marked current, one saved custom provider, the add row, and the
/// default chat model row.
Future<void> _providersShot(
  WidgetTester tester,
  _Device device,
  Locale locale,
) async {
  final registry = ProviderRegistry.inMemory();
  await registry.add(
    name: 'Acme',
    baseUrl: 'https://acme.example/v1',
    modelId: 'acme-1',
  );
  final service = _fakeService(MemoryExecutionEnv());
  await _pumpStore(
    tester,
    Builder(
      builder: (context) => _settingsFrame(
        context,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ProvidersSection(service: service, registry: registry),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            DefaultChatModelSection(service: service, registry: registry),
          ],
        ),
      ),
    ),
    device: device,
    locale: locale,
    screen: 'store_providers',
  );
  await tester.pumpAndSettle();
  await _expectStore(tester, device, locale, 'store_providers');
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    _wallpaperBytes = await File(
      'test/golden/assets/store/dashboard_wallpaper.jpg',
    ).readAsBytes();
  });

  group('App Store screenshots — the "your own apps, built by chat" story', () {
    testWidgets('store_chat — the ask: build a weather app with a widget', (
      tester,
    ) async {
      for (final device in _devices) {
        for (final locale in _locales) {
          await _chatShot(tester, device, locale);
        }
      }
    });

    testWidgets('store_apps — the launcher dashboard with live widgets', (
      tester,
    ) async {
      for (final device in _devices) {
        for (final locale in _locales) {
          await _appsShot(tester, device, locale);
        }
      }
    });

    testWidgets('store_promo — square marketing artwork', (tester) async {
      for (final locale in _locales) {
        await _promoShot(tester, locale);
      }
    });

    testWidgets('store_inapp — the session chat sheet over the weather app', (
      tester,
    ) async {
      for (final device in _devices) {
        for (final locale in _locales) {
          await _inappShot(tester, device, locale);
        }
      }
    });

    testWidgets('store_media — wallpaper, clip and voice summary in chat', (
      tester,
    ) async {
      for (final device in _devices) {
        for (final locale in _locales) {
          await _mediaShot(tester, device, locale);
        }
      }
    });

    testWidgets('store_providers — any provider, keys in the Keychain', (
      tester,
    ) async {
      for (final device in _devices) {
        for (final locale in _locales) {
          await _providersShot(tester, device, locale);
        }
      }
    });
  });
}
