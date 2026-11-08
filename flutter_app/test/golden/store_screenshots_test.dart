/// App Store screenshot generator: real app screens at real device
/// resolutions, composited into the [StoreFrame] marketing canvas and
/// committed under `test/golden/goldens/store/<lang>/<device>/`. The
/// `ios app_store` / `mac app_store` fastlane lanes upload these PNGs to
/// App Store Connect, so they are marketing material: full app frames,
/// real fonts, deterministic content, localized UI (en + ru).
///
/// Regenerate with:
/// `flutter test test/golden/store_screenshots_test.dart --update-goldens`
/// — then OPEN every PNG (no tofu, no overflow) before committing.
///
/// The five frames tell one continuous story — "your own apps, built by
/// chat" (a mobile agent harness — banned-claim copy is gated by
/// test/store_copy_compliance_test.dart, issue #643):
///  1. store_chat — THE ASK: the user asks Fa to build a playable
///     Minecraft-style voxel game with a live world widget.
///  2. store_apps — THE DASHBOARD: the selected Apps grid with LIVE widget
///     tiles (the just-built Fa Craft as a 4x2 world widget).
///  3. store_inapp — THE FOLLOW-UP: the real FaChatOverlay adds crafting
///     and survival UI over the running voxel world.
///  4. store_media — generation capabilities: an inline generated travel
///     wallpaper and a voice-summary player in chat.
///  5. store_providers — any provider, keys in the Keychain.
///
/// The generated wallpaper inside the media frame is a REAL picture (see
/// `test/golden/assets/store/README.md`), loaded once in `setUpAll` and
/// written into the in-memory sandbox — tests never touch the network.
///
/// Devices (App Store sizes): iPhone 6.9" 1290x2796 @3x, iPad Pro 13"
/// 2064x2752 @2x, Mac 2560x1600 @2x. Phone captures use the focused screen;
/// iPad/Mac captures use the production [WideLayoutShell] (rail, session or
/// category sidebar, adaptive content) and the real JS-app presentation
/// pane. All fakes and pump dances are the proven patterns from the sibling
/// golden tests — no network or wall-clock dependency.
library;

import 'dart:convert';
import 'dart:io';

import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/fa_chat_overlay.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/screens/providers_section.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa_ui/fa_ui.dart'
    show
        FaChatScreen,
        FaVisualDirection,
        MediaModelsScope,
        MediaModelsSection,
        MediaModelsStore,
        MediaSlot,
        MediaSlotOverride,
        TaskModelsScope,
        TaskModelsStore,
        TaskRole,
        TaskRoleConfig,
        buildFaTheme;
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

/// iPad and Mac captures must exercise the production wide messenger, not
/// a phone screen scaled to a larger viewport.
bool _isWideDevice(_Device device) =>
    device.name == 'ipad' || device.name == 'mac';

// ── Google Play listing targets (issue #289) ─────────────────────────────
// The same story frames at Play Console sizes, snapshotted DIRECTLY into
// the supply metadata tree (fastlane/metadata/android/<locale>/images/…),
// so the listing screenshots are committed goldens like the App Store set.
//
// Play accepts ONLY 9:16 or 16:9 screenshots (each side 320–3840 for the
// phone / 7-inch sets, 1080–7680 for the 10-inch set):
//   * phone: 1080×1920 — exact 9:16, both sides inside 320–3840; localized
//     en-US + ru-RU listings (repo convention: localized store shots);
//   * 10-inch: 1440×2560 — exact 9:16 with sides ≥1080. (The classic
//     1600×2560 tablet res is 10:16 and Play REJECTS it; the guard test
//     test/play_store_listing_guard_test.dart enforces the ratio.)
//     en-US only — the tablet set is optional and the ru listing falls
//     back to its phone shots on tablets.
const _Device _playPhone = (name: 'play', physical: Size(1080, 1920), dpr: 2.0);
const _Device _playTenInch = (
  name: 'tenInch',
  physical: Size(1440, 2560),
  dpr: 2.0,
);

/// Listing screenshot order — the Play Console sorts by file name.
const _playOrder = {
  'store_chat': '01',
  'store_apps': '02',
  'store_inapp': '03',
  'store_media': '04',
  'store_providers': '05',
};

/// The supply images dir for [lang] ('en'/'ru') relative to this test.
String _playImagesDir(String lang) =>
    '../../fastlane/metadata/android/${lang == 'ru' ? 'ru-RU' : 'en-US'}/'
    'images';

/// The real photo inside the media frame (see assets/store/README.md),
/// written into the in-memory sandbox as the "generated" wallpaper.
late Uint8List _wallpaperBytes;

/// Fa Craft sources read once in real async setup; widget-test fake zones
/// must never await host file I/O before the first frame.
late Map<String, String> _craftSourceFiles;

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

AgentService _fakeService(
  ExecutionEnv env, {
  String modelId = 'test-model',
  String baseUrl = 'https://example.com',
}) {
  return AgentService(
    agent: Agent(
      model: Model(
        id: modelId,
        api: 'test-api',
        provider: 'test',
        baseUrl: baseUrl,
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
      modelId: modelId,
      baseUrl: baseUrl,
      apiKey: '',
    ),
  );
}

// --- Story scaffolding ------------------------------------------------------

/// The story session ids.
const _craftSessionId = 'a11ce001-fa-craft';
const _wallpaperSessionId = 'b22ce002-wallpaper';
const _notesSessionId = 'c33ce003-notes';

/// The story sessions shown in the chat sheet header (and kept in the
/// manager for realism): the app-build chat, the wallpaper session and a
/// persisted one. Titles ride the `session_names.json` overlay the stores
/// load from the env (or an in-memory session-names store where one can be
/// injected).
Map<String, String> _sessionNames(String lang) => lang == 'ru'
    ? {
        _craftSessionId: 'Fa Craft — свой мир',
        _wallpaperSessionId: 'Постер путешествия',
        _notesSessionId: 'Идеи виджета заметок',
      }
    : {
        _craftSessionId: 'Fa Craft world',
        _wallpaperSessionId: 'Travel wallpaper',
        _notesSessionId: 'Notes widget ideas',
      };

/// Writes the session-titles overlay exactly where the session-names store
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
  final otherId = activeId == _craftSessionId
      ? _wallpaperSessionId
      : _craftSessionId;
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
      theme: buildFaTheme(
        direction: FaVisualDirection.porcelain,
        brightness: Brightness.light,
      ),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: StoreFrame(screen: screen, lang: locale.languageCode, child: child),
    ),
  );
  // Issue #947: no Ahem placeholder blocks may reach a store golden —
  // a family-less label style falls back to the test font.
  expectRealFontText(tester);
  for (final element in find.byType(EditableText).evaluate()) {
    final input = element.widget as EditableText;
    expect(
      input.style.fontFamily,
      isNotNull,
      reason:
          'Store input/placeholder text must use a real loaded font, not '
          'the Ahem test fallback ($screen, ${device.name}, $locale).',
    );
  }
}

Future<void> _expectStore(
  WidgetTester tester,
  _Device device,
  Locale locale,
  String screen, {
  bool disposeAfter = false,
}) async {
  // App Store devices land in test/golden/goldens/store/<lang>/<device>/; the
  // Play devices land straight in the supply metadata tree with their
  // listing order prefix (Play sorts screenshots by file name).
  final String golden;
  switch (device.name) {
    case 'play':
      golden =
          '${_playImagesDir(locale.languageCode)}/phoneScreenshots/'
          '${_playOrder[screen]}_$screen.png';
    case 'tenInch':
      golden =
          '${_playImagesDir(locale.languageCode)}/tenInchScreenshots/'
          '${_playOrder[screen]}_$screen.png';
    default:
      golden =
          '../goldens/store/${locale.languageCode}/${device.name}/$screen.png';
  }
  await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden));
  if (_isWideDevice(device) || disposeAfter) {
    // The real shell and every presented JS app can arm delayed load/watchdog
    // futures. Dispose them before the next capture in the device loop.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }
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

/// Pins each Scrollable to its semantic story end. ChatAnimatedList is
/// reversed (newest at offset zero); regular lists and the app overlay use
/// their maximum extent. Treating every list alike hid the assistant answer
/// behind the composer in the original store captures.
void _jumpScrollablesToStoryEnd(WidgetTester tester) {
  for (final element in find.byType(Scrollable).evaluate()) {
    final state = (element as StatefulElement).state as ScrollableState;
    // Exact-type ScrollView never matches the transcript's
    // CustomScrollView (nor a ListView): both are subclasses, so the old
    // check silently pinned the "reversed" chat to its OLDEST offset.
    final custom = element.findAncestorWidgetOfExactType<CustomScrollView>();
    final list = element.findAncestorWidgetOfExactType<ListView>();
    final reverse = custom?.reverse ?? list?.reverse ?? false;
    final extent = reverse
        ? state.position.minScrollExtent
        : state.position.maxScrollExtent;
    state.position.jumpTo(extent);
  }
}

// --- The story conversations ------------------------------------------------

/// Frame 1 (and the dashboard mini bar): the user asks Fa to build a
/// playable voxel world. One representative write plus `open_app` keeps
/// the request, tool work and finished result visible.
List<FahChatMessage> _craftBuildConversation(String lang) {
  final ru = lang == 'ru';
  return [
    FahChatMessage(
      role: 'user',
      content: ru
          ? 'Создай игру в стиле Minecraft с живым виджетом мира.'
          : 'Build a Minecraft-style voxel game with a live world widget.',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'write',
      content: 'apps/fa-craft/game/main.js (24 KB)',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'open_app',
      content: 'Opened "Fa Craft" (apps/fa-craft).',
    ),
    FahChatMessage(
      role: 'assistant',
      content: ru
          ? 'Готово — **Fa Craft**: 3D-мир, блоки и живой виджет 4×2 '
                'на домашнем экране.'
          : 'Done — **Fa Craft** with a 3D world, blocks and a live 4×2 '
                'widget on your home screen.',
    ),
  ];
}

/// Frame 3 (the sheet over the open app): a follow-up tweak without
/// leaving the voxel world.
List<FahChatMessage> _inappConversation(String lang) {
  final ru = lang == 'ru';
  return [
    FahChatMessage(
      role: 'user',
      content: ru
          ? 'Добавь крафт, инвентарь и сердечки выживания'
          : 'Add crafting, an inventory and survival hearts',
    ),
    FahChatMessage(
      role: 'assistant',
      content: ru
          ? 'Готово — крафт и хотбар добавлены, а мир сохраняется '
                'локально на устройстве.'
          : 'Done — crafting and a hotbar are in. Your world saves '
                'locally on the device.',
    ),
  ];
}

/// Frame 4: a real generated Lisbon wallpaper and a voice-summary player.
List<FahChatMessage> _mediaConversation(String lang) {
  final ru = lang == 'ru';
  return [
    FahChatMessage(
      role: 'user',
      content: ru
          ? 'Создай обои Лиссабона и озвучь маршрут субботы.'
          : 'Create a Lisbon wallpaper and narrate Saturday.',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'generate_image',
      content:
          'Generated image saved to generated/lisbon-wallpaper.png '
          '(1200x320).',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'speak',
      content:
          'Speech saved to generated/saturday-itinerary.mp3 '
          '(voice "alloy", ~8 s).',
    ),
  ];
}

// --- Frame 1: store_chat — the ask ------------------------------------------

/// store_chat: the full current ChatScreen with the app-build conversation.
Future<void> _chatShot(
  WidgetTester tester,
  _Device device,
  Locale locale,
) async {
  final env = MemoryExecutionEnv();
  await _seedSessionNames(env, locale.languageCode);
  final service = _fakeService(env);
  service.messages.addAll(_craftBuildConversation(locale.languageCode));
  final manager = await _storyManager(env, _craftSessionId, service);

  await _pumpStore(
    tester,
    _isWideDevice(device)
        ? WideLayoutShell(
            manager: manager,
            sessionNamesStore: SessionNamesStore.inMemory(
              _sessionNames(locale.languageCode),
            ),
          )
        : ChatScreen(manager: manager),
    device: device,
    locale: locale,
    screen: 'store_chat',
  );
  // Flush fake-time debounces (the message sync) with bounded pumps —
  // pumpAndSettle is not safe here (intermittent settle timeouts).
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  _jumpScrollablesToStoryEnd(tester);
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

/// The canonical Fa Craft voxel-block icon (fa-craft 0.2.32, MIT).
const _craftSvgIcon = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
  <rect width="64" height="64" rx="12" fill="#1b2432"/>
  <g stroke="#101722" stroke-width="1.5" stroke-linejoin="round">
    <polygon points="32,10 54,22 32,34 10,22" fill="#7ec850"/>
    <polygon points="10,22 32,34 32,56 10,44" fill="#5c9a38"/>
    <polygon points="54,22 32,34 32,56 54,44" fill="#41702a"/>
  </g>
  <g fill="#8d6e4f" stroke="#101722" stroke-width="1.5" stroke-linejoin="round">
    <polygon points="32,22 43,28 32,34 21,28"/>
    <polygon points="21,28 32,34 32,45 21,39"/>
    <polygon points="43,28 32,34 32,45 43,39"/>
  </g>
</svg>''';

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

/// Installs the pinned fa-craft 0.2.32 fixture into the in-memory app
/// sandbox, preserving relative imports under `game/`.
Future<void> _installCraftAppSources(MemoryExecutionEnv env) async {
  for (final entry in _craftSourceFiles.entries) {
    await env.writeFile('apps/fa-craft/${entry.key}', entry.value);
  }
}

/// Seeds the launcher's apps into the env (no bundled-asset seeding):
/// Fa Craft with a live 4x2 world tile, a reminders app with a 2x2 tile,
/// and eight static-icon apps.
Future<MemoryExecutionEnv> _seededLauncherEnv([String lang = 'en']) async {
  final env = MemoryExecutionEnv();
  Future<void> app(String id, String manifest) async {
    await env.writeFile('apps/$id/manifest.json', manifest);
    await env.writeFile('apps/$id/widget.js', '(function(){})();');
  }

  await app(
    'fa-craft',
    '{"id": "fa-craft", "name": "Fa Craft", '
        '"description": "A playable voxel sandbox", '
        '"version": "0.2.32", '
        '"icon": ${_jsonString(_craftSvgIcon)}, '
        '"widget": {"entry": "widget_tile.js", "size": "4x2", '
        '"refreshSeconds": 900}}',
  );
  await env.writeFile('apps/fa-craft/widget_tile.js', '(function(){})();');
  await _installCraftAppSources(env);
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

  Map<String, dynamic> get _craftTree => {
    'type': 'container',
    'padding': [18, 12, 18, 12],
    'child': {
      'type': 'row',
      'crossAxisAlignment': 'center',
      'children': [
        {
          'type': 'column',
          'mainAxisSize': 'min',
          'crossAxisAlignment': 'start',
          'children': [
            {
              'type': 'icon',
              'name': 'sports_esports',
              'color': '#7EC850',
              'size': 32,
            },
            {'type': 'sizedBox', 'height': 5},
            {
              'type': 'text',
              'data': 'Fa Craft',
              'style': {'fontSize': 18, 'fontWeight': 'w700'},
            },
            {
              'type': 'text',
              'data': lang == 'ru' ? '3D-МИР ИЗ БЛОКОВ' : 'VOXEL WORLD',
              'style': {'fontSize': 10, 'color': '#A8B3C7'},
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
              'data': lang == 'ru' ? 'ТВОРЧЕСКИЙ РЕЖИМ' : 'CREATIVE MODE',
              'style': {
                'fontSize': 10,
                'fontWeight': 'w700',
                'color': '#7EC850',
              },
            },
            {'type': 'sizedBox', 'height': 5},
            {
              'type': 'text',
              'data': lang == 'ru' ? 'Мир 07' : 'World 07',
              'style': {'fontSize': 14, 'fontWeight': 'w600'},
            },
            {
              'type': 'text',
              'data': lang == 'ru'
                  ? '9 чанков • локальное сохранение'
                  : '9 chunks • local save',
              'style': {'fontSize': 10, 'color': '#A8B3C7'},
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
      'fa-craft' => _craftTree,
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

/// JSON-encodes [value] as a string literal (including multiline SVG icons).
String _jsonString(String value) => jsonEncode(value);

/// store_apps: the selected Apps surface — live widget tiles (Fa Craft as
/// a 4x2 world, reminders 2x2), static app icons and the system tiles. Also
/// serves the square promo shot ([golden] = `store_promo`).
Future<void> _appsShot(
  WidgetTester tester,
  _Device device,
  Locale locale, {
  String golden = 'store_apps',
}) async {
  final lang = locale.languageCode;
  final env = await _seededLauncherEnv(lang);
  final service = _fakeService(env);
  service.messages.addAll(_craftBuildConversation(lang));
  final manager = await _storyManager(env, _craftSessionId, service);
  final layoutStore = LauncherLayoutStore.inMemory(
    order: const [
      'app:fa-craft',
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
  );
  final appsStore = AppsStore(
    env,
    readAsset: (path) async =>
        throw StateError('no bundled assets in this test'),
    seedDemoIds: const [],
  );
  final tileEngineFactory = _fakeTileEngineFactory(lang);

  await _pumpStore(
    tester,
    _isWideDevice(device)
        ? WideLayoutShell(
            manager: manager,
            sessionNamesStore: SessionNamesStore.inMemory(_sessionNames(lang)),
            layoutStore: layoutStore,
            appsStore: appsStore,
            tileEngineFactory: tileEngineFactory,
          )
        : AppLauncherScreen(
            manager: manager,
            layoutStore: layoutStore,
            appsStore: appsStore,
            tileEngineFactory: tileEngineFactory,
          ),
    device: device,
    locale: locale,
    screen: golden,
  );
  await tester.pumpAndSettle();
  if (_isWideDevice(device)) {
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    expect(find.text('Fa Craft'), findsWidgets);
    expect(find.text(lang == 'ru' ? 'Мир 07' : 'World 07'), findsWidgets);
  } else {
    // The newly built app is the hero: never scroll its first row away.
    expect(find.text('Fa Craft'), findsOneWidget);
    expect(find.text(lang == 'ru' ? 'Мир 07' : 'World 07'), findsOneWidget);
  }
  await tester.pump();
  await _expectStore(tester, device, locale, golden);
}

/// The square marketing promo (App Review / social artwork): the same
/// dashboard composition as store_apps at 1024×1024.
Future<void> _promoShot(WidgetTester tester, Locale locale) {
  const device = (name: 'promo', physical: Size(1024, 1024), dpr: 1.0);
  return _appsShot(tester, device, locale, golden: 'store_promo');
}

// --- Frame 3: store_inapp — the follow-up inside the open app -----------

JsAppInfo _craftAppInfo() => JsAppInfo.fromManifest(
  {
    'id': 'fa-craft',
    'name': 'Fa Craft',
    'description': 'A playable voxel sandbox',
    'version': '0.2.32',
    'icon': _craftSvgIcon,
  },
  bundled: false,
  fallbackId: 'fa-craft',
);

/// The production standalone app host with its expanded Fa overlay. The
/// pinned game boots inside the real JS/voxel engine on every form factor.
Future<Widget> _inappCraftHost(
  AgentService service,
  MemoryExecutionEnv env, {
  double overlayHeight = 0.58,
}) async {
  final permissions = await AppPermissionsStore.load(env);
  return LayoutBuilder(
    builder: (context, constraints) => Stack(
      children: [
        Positioned.fill(
          child: JsAppView(
            app: _craftAppInfo(),
            env: env,
            permissionsStore: permissions,
            agentService: service,
            onSendToAgent: (_) async => service,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: constraints.maxHeight * overlayHeight,
          child: FaChatOverlay(
            service: service,
            onSend: (_) async {},
            onCollapse: () {},
            onOpenFullChat: () {},
          ),
        ),
      ],
    ),
  );
}

/// store_inapp: a crafting/survival follow-up without leaving Fa Craft.
Future<void> _inappShot(
  WidgetTester tester,
  _Device device,
  Locale locale,
) async {
  final lang = locale.languageCode;
  final env = await _seededLauncherEnv(lang);
  final service = _fakeService(env);
  service.messages.addAll(_inappConversation(lang));
  final wide = _isWideDevice(device);
  final wideShell = wide && device.name != 'ipad';
  final manager = wideShell
      ? await _storyManager(env, _craftSessionId, service)
      : null;

  await _pumpStore(
    tester,
    wideShell
        ? WideLayoutShell(
            manager: manager!,
            sessionNamesStore: SessionNamesStore.inMemory(_sessionNames(lang)),
          )
        : await _inappCraftHost(
            service,
            env,
            overlayHeight: wide ? 0.42 : 0.58,
          ),
    device: device,
    locale: locale,
    screen: 'store_inapp',
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  if (wideShell) {
    await pushJsApp(
      tester.element(find.byType(ChatScreen)),
      manager: manager!,
      app: _craftAppInfo(),
      source: 'store_golden',
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(
      find.byKey(const ValueKey('messengerPrimaryNav-apps')),
      findsOneWidget,
    );
  } else {
    expect(find.byType(FaChatOverlay), findsOneWidget);
  }
  await _settleRealAsync(tester);
  _jumpScrollablesToStoryEnd(tester);
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.byType(JsAppView), findsOneWidget);
  expect(find.text('Craft'), findsWidgets);
  expect(
    find.text(
      lang == 'ru'
          ? 'Добавь крафт, инвентарь и сердечки выживания'
          : 'Add crafting, an inventory and survival hearts',
    ),
    findsOneWidget,
  );
  await _expectStore(tester, device, locale, 'store_inapp', disposeAfter: true);
}

// --- Frame 4: store_media — generated image and voice -----------------------

/// store_media: the production embedded FaChatScreen with a compact host
/// app bar — generated Lisbon wallpaper and voice player fit instead of
/// spending the viewport on the adaptive chat header.
Future<void> _mediaShot(
  WidgetTester tester,
  _Device device,
  Locale locale,
) async {
  final env = MemoryExecutionEnv();
  await env.writeBinaryFile('generated/lisbon-wallpaper.png', _wallpaperBytes);
  await env.writeBinaryFile(
    'generated/saturday-itinerary.mp3',
    Uint8List.fromList(List<int>.filled(64, 7)),
  );
  final service = _fakeService(env);
  service.messages.addAll(_mediaConversation(locale.languageCode));
  final wide = _isWideDevice(device);
  final manager = wide
      ? await _storyManager(env, _wallpaperSessionId, service)
      : null;
  FakeAudioController audioFactory(Uint8List bytes) =>
      FakeAudioController(duration: const Duration(seconds: 8));

  await _pumpStore(
    tester,
    wide
        ? WideLayoutShell(
            manager: manager!,
            sessionNamesStore: SessionNamesStore.inMemory(
              _sessionNames(locale.languageCode),
            ),
            audioControllerFactory: audioFactory,
          )
        : Scaffold(
            extendBodyBehindAppBar: false,
            appBar: AppBar(
              centerTitle: false,
              title: const Row(
                children: [
                  Icon(Icons.map_outlined, color: Color(0xFFFB923C)),
                  SizedBox(width: 9),
                  Text('Lisbon Weekend'),
                ],
              ),
            ),
            body: FaChatScreen(
              service: service,
              showAppBar: false,
              audioControllerFactory: audioFactory,
            ),
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
  _jumpScrollablesToStoryEnd(tester);
  await tester.pump();
  await _settleRealAsync(tester, rounds: 12);
  _jumpScrollablesToStoryEnd(tester);
  await tester.pump();
  // Let the list's scroll-to-bottom button fade out after the tail jump.
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.textContaining('lisbon-wallpaper.png'), findsWidgets);
  expect(find.textContaining('saturday-itinerary.mp3'), findsWidgets);
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
        child: Align(
          alignment: Alignment.topCenter,
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

/// store_providers: hosted OpenRouter/Kimi/OpenAI, local Ollama, a default
/// chat model from the active connection, and real media-model overrides.
Future<void> _providersShot(
  WidgetTester tester,
  _Device device,
  Locale locale,
) async {
  final registry = ProviderRegistry.inMemory();
  await registry.add(
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    modelId: 'moonshotai/kimi-k2.6',
  );
  await registry.add(
    name: 'Kimi',
    baseUrl: 'https://api.kimi.com/coding/v1',
    modelId: 'kimi-for-coding',
  );
  await registry.add(
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    modelId: 'gpt-4o-mini',
  );
  await registry.add(
    name: 'Ollama',
    baseUrl: 'http://localhost:11434/v1',
    modelId: 'qwen3:32b',
  );
  final mediaStore = MediaModelsStore.inMemory();
  const openAi = 'https://api.openai.com/v1';
  for (final (slot, model) in [
    (MediaSlot.imageGeneration, 'gpt-image-1'),
    (MediaSlot.audioTts, 'tts-1'),
    (MediaSlot.vision, 'gpt-4o'),
    (MediaSlot.transcription, 'whisper-1'),
  ]) {
    await mediaStore.setOverride(
      slot,
      MediaSlotOverride(
        providerKind: 'openai-completions',
        baseUrl: openAi,
        modelId: model,
        voice: slot == MediaSlot.audioTts ? 'alloy' : null,
      ),
    );
  }
  final taskStore = TaskModelsStore.inMemory({
    TaskRole.smol: const TaskRoleConfig(
      providerKind: 'openai-completions',
      baseUrl: 'https://openrouter.ai/api/v1',
      modelId: 'google/gemini-3.5-flash-lite',
    ),
    TaskRole.subagent: const TaskRoleConfig(
      providerKind: 'openai-completions',
      baseUrl: 'https://openrouter.ai/api/v1',
      modelId: 'moonshotai/kimi-k2.6',
    ),
  });
  final env = MemoryExecutionEnv();
  final service = _fakeService(
    env,
    modelId: 'moonshotai/kimi-k2.6',
    baseUrl: 'https://openrouter.ai/api/v1',
  );
  final wide = _isWideDevice(device);
  final manager = wide
      ? await _storyManager(env, _craftSessionId, service)
      : null;
  await _pumpStore(
    tester,
    wide
        ? MediaModelsScope(
            store: mediaStore,
            child: TaskModelsScope(
              store: taskStore,
              child: WideLayoutShell(
                manager: manager!,
                registry: registry,
                sessionNamesStore: SessionNamesStore.inMemory(
                  _sessionNames(locale.languageCode),
                ),
              ),
            ),
          )
        : Builder(
            builder: (context) => _settingsFrame(
              context,
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ProvidersSection(registry: registry),
                  const SizedBox(height: 24),
                  const Divider(),
                  const SizedBox(height: 16),
                  DefaultChatModelSection(service: service, registry: registry),
                  const SizedBox(height: 24),
                  MediaModelsSection(
                    store: mediaStore,
                    mainBaseUrl: 'https://openrouter.ai/api/v1',
                    registry: registry,
                  ),
                ],
              ),
            ),
          ),
    device: device,
    locale: locale,
    screen: 'store_providers',
  );
  await tester.pumpAndSettle();
  if (wide) {
    await tester.tap(find.byKey(const ValueKey('railSettingsRow')));
    await tester.pumpAndSettle();
  }
  expect(find.text('OpenRouter'), findsOneWidget);
  expect(find.text('Kimi'), findsOneWidget);
  expect(find.text('OpenAI'), findsOneWidget);
  expect(find.text('Ollama'), findsOneWidget);
  expect(find.textContaining('moonshotai/kimi-k2.6'), findsWidgets);
  if (!wide) {
    expect(find.textContaining('gpt-image-1'), findsOneWidget);
    expect(find.textContaining('tts-1'), findsOneWidget);
  }
  await _expectStore(tester, device, locale, 'store_providers');
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    _wallpaperBytes = await File(
      'test/golden/assets/store/lisbon_wallpaper.png',
    ).readAsBytes();
    _craftSourceFiles = {};
    final craftRoot = Directory('test/golden/assets/store/fa_craft');
    await for (final entity in craftRoot.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.js')) continue;
      final rel = entity.path.substring(craftRoot.path.length + 1);
      _craftSourceFiles[rel] = await entity.readAsString();
    }
  });

  group('App Store screenshots — the "your own apps, built by chat" story', () {
    testWidgets('store_chat — the ask: build a voxel game with a widget', (
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

    testWidgets('store_inapp — the follow-up in the current ChatScreen', (
      tester,
    ) async {
      for (final device in _devices) {
        for (final locale in _locales) {
          await _inappShot(tester, device, locale);
        }
      }
    });

    testWidgets('store_media — wallpaper and voice itinerary in chat', (
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

  // ── Google Play listing screenshots (issue #289) ──────────────────────
  // The same five story frames, golden-verified straight into the supply
  // tree: phone 1080×1920 (en-US + ru-RU) and 10-inch 1440×2560 (en-US).
  // Regeneration note: `--update-goldens` also refreshes the App Store
  // goldens above on a non-canonical host — restore those
  // (`git checkout -- test/golden/goldens/store`) so only the intended files
  // change; the committed listing files are then guarded by
  // test/play_store_listing_guard_test.dart.
  group('Google Play listing screenshots — the story at Play sizes', () {
    testWidgets('play store_chat — the ask at 1080×1920 / 1440×2560', (
      tester,
    ) async {
      for (final locale in _locales) {
        await _chatShot(tester, _playPhone, locale);
      }
      await _chatShot(tester, _playTenInch, const Locale('en'));
    });

    testWidgets('play store_apps — the dashboard at Play sizes', (
      tester,
    ) async {
      for (final locale in _locales) {
        await _appsShot(tester, _playPhone, locale);
      }
      await _appsShot(tester, _playTenInch, const Locale('en'));
    });

    testWidgets('play store_inapp — the follow-up edit at Play sizes', (
      tester,
    ) async {
      for (final locale in _locales) {
        await _inappShot(tester, _playPhone, locale);
      }
      await _inappShot(tester, _playTenInch, const Locale('en'));
    });

    testWidgets('play store_media — generation tools at Play sizes', (
      tester,
    ) async {
      for (final locale in _locales) {
        await _mediaShot(tester, _playPhone, locale);
      }
      await _mediaShot(tester, _playTenInch, const Locale('en'));
    });

    testWidgets('play store_providers — the settings frame at Play sizes', (
      tester,
    ) async {
      for (final locale in _locales) {
        await _providersShot(tester, _playPhone, locale);
      }
      await _providersShot(tester, _playTenInch, const Locale('en'));
    });
  });
}
