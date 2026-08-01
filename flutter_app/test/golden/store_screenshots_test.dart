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
/// The five frames tell one continuous story — a parent asks Fa to plan
/// their kid Makar's week:
///  1. store_chat — the ask: a plan, a recurring `calendar_add` call, an
///     inline "AI-generated" birthday card and a voice-summary player.
///  2. store_calendar — the recurring events and alarms in the calendar.
///  3. store_apps — the sidebar: story sessions next to the apps gallery.
///  4. store_inapp — the expanded Fa chat overlay over the map app: a
///     follow-up ("move swimming to 11:30") without leaving the app.
///  5. store_providers — any provider, keys in the Keychain.
///
/// The photos inside the frames are REAL pictures (see
/// `test/golden/assets/store/README.md`), loaded once in `setUpAll` and
/// written into the in-memory sandbox — tests never touch the network.
///
/// Devices (App Store sizes): iPhone 6.9" 1290x2796 @3x, iPad Pro 13"
/// 2064x2752 @2x, Mac 2560x1600 @2x. All fakes and pump dances are the
/// proven patterns from the sibling golden tests (chat/sidebar/apps/
/// settings) — no network, no clocks, no real JS engine.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/apps_store.dart' show JsAppInfo;
import 'package:fa/apps/fa_chat_overlay.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/screens/providers_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

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

/// The real photos inside the frames (see assets/store/README.md), plus
/// the offline map tile fixture shared with the apps golden tests.
late Uint8List _birthdayCardBytes;
late Uint8List _clubPhotoBytes;
late Uint8List _weekHeaderBytes;
late Uint8List _mapTileBytes;

// --- Service fakes (verbatim patterns from chat/apps golden tests) ---------

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

/// Off the web, `chatImageMessageSource` writes attached-image bytes into
/// path_provider's temp directory. There is no plugin implementation in a
/// widget test, so the platform interface is replaced outright (same fake
/// as chat_golden_test.dart).
class _FakePathProviderPlatform extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProviderPlatform(this._tempPath);

  final String _tempPath;

  @override
  Future<String?> getTemporaryPath() async => _tempPath;
}

/// Serves `rootBundle` from the asset tree `flutter test` builds into
/// `build/unit_test_assets/` (see sidebar_golden_test.dart for why both the
/// per-test mock handler and `rootBundle.clear()` are needed).
void _mockBundledAppAssets() {
  rootBundle.clear();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (message) async {
        if (message == null) return null;
        final key = utf8.decode(message.buffer.asUint8List());
        final file = File('build/unit_test_assets/$key');
        if (!file.existsSync()) return null;
        return ByteData.sublistView(await file.readAsBytes());
      });
}

/// Waits until the sidebar's apps section finished seeding + loading: the
/// seeding is real async I/O `pumpAndSettle` does not wait for, so alternate
/// real event-loop delays with pumps until the demo apps rendered.
Future<void> _settleSidebarApps(WidgetTester tester) async {
  for (var i = 0; i < 200 && find.text('Calculator').evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(find.text('Calculator'), findsOneWidget);
}

// --- Story scaffolding ------------------------------------------------------

/// The story sessions shown in the sidebar (frames 1 and 3): the active
/// planning chat, the card session and a persisted pool session. Titles
/// ride the `session_names.json` overlay the sidebar loads from the env.
Map<String, String> _sessionNames(String lang) => lang == 'ru'
    ? {
        'a1b2c3d4-makars-week': 'Неделя Макара',
        'e5f6a7b8-birthday-card': 'Открытка Макару',
        'c0ffee01-pool-schedule': 'Расписание бассейна',
      }
    : {
        'a1b2c3d4-makars-week': "Makar's week",
        'e5f6a7b8-birthday-card': 'Birthday card',
        'c0ffee01-pool-schedule': 'Pool schedule',
      };

/// Writes the session-titles overlay exactly where `SessionNamesStore`
/// reads it (`<cwd>/session_names.json`, envelope version 1).
Future<void> _seedSessionNames(MemoryExecutionEnv env, String lang) {
  return env.writeFile(
    '${env.cwd}/session_names.json',
    jsonEncode({'version': 1, 'names': _sessionNames(lang)}),
  );
}

/// A session manager with the three story sessions: [active] holds the
/// hero conversation, one more live session, one persisted on disk.
Future<FlutterSessionManager> _storyManager(
  MemoryExecutionEnv env,
  AgentService active,
) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  await repo.create(
    JsonlSessionCreateOptions(
      id: 'c0ffee01-pool-schedule',
      cwd: 'family',
      metadata: const {'agent': 'fa', 'model': 'old-model'},
    ),
  );
  return FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('e5f6a7b8-birthday-card', _fakeService(env))
    ..addSession('a1b2c3d4-makars-week', active);
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

// --- Frame 1: store_chat — the ask ------------------------------------------

/// The hero conversation: the parent's planning ask with a real photo
/// attached, the generated birthday card, the voice-summary player, and the
/// recurring speech-therapy `calendar_add` call last so the visible tail
/// holds all four story beats (recurring call, player, plan, card) even on
/// the shortest (Mac) viewport.
List<FahChatMessage> _makarConversation(String lang) {
  final ru = lang == 'ru';
  return [
    FahChatMessage(
      role: 'user',
      content: ru
          ? 'Макару очень понравился субботний кружок. Спланируй его неделю: '
                'логопед в пн и чт в 18:10, плавание в субботу утром. И нарисуй '
                'ему открытку — в воскресенье ему исполняется семь.'
          : 'Makar loved the art club on Saturday. Plan his week: speech '
                'therapy Mon & Thu 18:10, swimming Saturday morning. And draw '
                'him a birthday card — he turns seven on Sunday.',
      imageBytes: _clubPhotoBytes,
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'generate_image',
      content:
          'Generated image saved to generated/makar-birthday-card.png '
          '(361177 bytes, 900x600). Reference it as '
          '![image](generated/makar-birthday-card.png) to display it inline '
          'in the chat.',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'speak',
      content:
          'Speech saved to generated/makar-week.mp3 (voice "alloy", ~9 s).',
    ),
    FahChatMessage(
      role: 'system',
      content:
          '[calendar_add] {"title": "Speech therapy (Makar)", "start": '
          '"18:10", "recurrence": {"frequency": "weekly", "daysOfWeek": '
          '["MO", "TH"], "until": "2026-12-31"}, "alarms": [30]}',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'calendar_add',
      content:
          'Event "Speech therapy" added: Mon & Thu 18:10–18:50, weekly '
          'MO,TH until 2026-12-31, alarm 30 min before (calendar "Family").',
    ),
    FahChatMessage(
      role: 'assistant',
      content: ru
          ? 'Вот неделя Макара:\n\n'
                '- **Логопед** — пн и чт, 18:10–18:50 (повтор до 31 декабря, '
                'напоминание за 30 минут)\n'
                '- **Плавание** — суббота 10:00 (напоминание за час)\n\n'
                'А вот и открытка к воскресенью:\n\n'
                '![Открытка для Макара](generated/makar-birthday-card.png)\n\n'
                'Выше — голосовая сводка недели, удобно слушать в машине.'
          : 'Here is Makar\'s week:\n\n'
                '- **Speech therapy** — Mon & Thu, 18:10–18:50 (repeats until '
                'Dec 31, alarm 30 min before)\n'
                '- **Swimming** — Saturday 10:00 (alarm 1 hour before)\n\n'
                'And the birthday card for Sunday:\n\n'
                '![Makar\'s birthday card](generated/makar-birthday-card.png)\n\n'
                'There is a voice summary of the week above — handy in the car.',
    ),
  ];
}

/// store_chat: the full ChatScreen with the hero conversation. Wide layouts
/// dock the session sidebar; the phone layout keeps its drawer closed.
Future<void> _chatShot(
  WidgetTester tester,
  _Device device,
  Locale locale,
) async {
  _mockBundledAppAssets();
  // The user message carries a real photo attachment — its bytes are staged
  // via path_provider's temp dir, faked here (see _FakePathProviderPlatform).
  final tmp = Directory.systemTemp.createTempSync('fah_store_chat');
  addTearDown(() => tmp.deleteSync(recursive: true));
  final previous = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _FakePathProviderPlatform(tmp.path);
  addTearDown(() => PathProviderPlatform.instance = previous);

  final env = MemoryExecutionEnv();
  await env.writeBinaryFile(
    'generated/makar-birthday-card.png',
    _birthdayCardBytes,
  );
  await env.writeBinaryFile(
    'generated/makar-week.mp3',
    Uint8List.fromList(List<int>.filled(64, 7)),
  );
  await _seedSessionNames(env, locale.languageCode);
  final service = _fakeService(env);
  service.messages.addAll(_makarConversation(locale.languageCode));
  final manager = await _storyManager(env, service);

  await _pumpStore(
    tester,
    ChatScreen(
      manager: manager,
      audioControllerFactory: (bytes) =>
          FakeAudioController(duration: const Duration(seconds: 9)),
    ),
    device: device,
    locale: locale,
    screen: 'store_chat',
  );
  // The env image reads + codec resolve on the real event loop; the sidebar
  // seeds its demo apps there too.
  await _settleRealAsync(tester);
  // Flush fake-time debounces (the message sync) with bounded pumps —
  // pumpAndSettle is not safe here (intermittent settle timeouts).
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  // The markdown image inside the assistant bubble starts loading only
  // after the bubble's first frame — give the real event loop more time.
  await _settleRealAsync(tester, rounds: 12);
  // Pin the chat to the tail: image loads grew the content after the last
  // follow-scroll, so jump deterministically. The tail bubble's markdown
  // image only STARTS loading once it is built here, so give the real event
  // loop time to decode it, then jump again (the content grew meanwhile).
  _jumpScrollablesToTail(tester);
  await tester.pump();
  await _settleRealAsync(tester, rounds: 12);
  _jumpScrollablesToTail(tester);
  await tester.pump();
  // The sidebar (and its demo apps) only exists on wide layouts; on the
  // phone it is a lazy drawer that stays closed for the chat shot.
  if (device.name != 'ios') await _settleSidebarApps(tester);
  _jumpScrollablesToTail(tester);
  await tester.pump();
  // Let the list's scroll-to-bottom button fade out after the tail jump.
  await tester.pump(const Duration(milliseconds: 400));
  await _expectStore(tester, device, locale, 'store_chat');
}

// --- Frame 2: store_calendar — recurring events, in the calendar ------------

/// The bundled Calendar demo's inline SVG icon (from
/// `assets/apps/calendar/manifest.json`).
const _calendarSvgIcon =
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'>"
    "<rect x='3' y='5' width='18' height='16' rx='3' fill='#3b82f6'/>"
    "<rect x='3' y='5' width='18' height='5' rx='2.5' fill='#1d4ed8'/>"
    "<rect x='7' y='2.5' width='2' height='5' rx='1' fill='#93c5fd'/>"
    "<rect x='15' y='2.5' width='2' height='5' rx='1' fill='#93c5fd'/>"
    "<circle cx='8' cy='13.5' r='1.4' fill='#dbeafe'/>"
    "<circle cx='12' cy='13.5' r='1.4' fill='#dbeafe'/>"
    "<circle cx='16' cy='13.5' r='1.4' fill='#fbbf24'/>"
    "<circle cx='8' cy='17' r='1.4' fill='#dbeafe'/>"
    "<circle cx='12' cy='17' r='1.4' fill='#dbeafe'/></svg>";

/// A JsAppView-like scaffold for the hand-built calendar week canvas (same
/// trick as the calculator canvas in the apps golden tests — no JS engine).
Widget _calendarHost(MemoryExecutionEnv env, String lang) {
  final calApp = JsAppInfo.fromManifest(
    const {'id': 'calendar', 'name': 'Calendar', 'icon': _calendarSvgIcon},
    bundled: false,
    fallbackId: 'calendar',
  );
  return Scaffold(
    appBar: AppBar(
      title: Row(
        children: [
          AppIcon(app: calApp, env: env, size: 24),
          const SizedBox(width: 8),
          const Flexible(
            child: Text('Calendar', overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      actions: [
        IconButton(icon: const Icon(Icons.shield_outlined), onPressed: () {}),
        IconButton(icon: const Icon(Icons.refresh), onPressed: () {}),
      ],
    ),
    body: _calendarCanvas(lang),
  );
}

/// One story event chip in the week grid. Phone columns are ~50pt wide, so
/// fonts and padding are tiny and titles stay short enough to never wrap
/// mid-word.
Widget _eventChip(
  FahColors colors, {
  required String title,
  required Color color,
  String? time,
  IconData? icon,
}) {
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 2),
    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(7),
      border: Border(left: BorderSide(color: color, width: 3)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 9, color: color),
              const SizedBox(width: 3),
            ],
            if (time != null)
              Flexible(
                child: Text(
                  time,
                  style: colors.mono(fontSize: 8),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (time != null) ...[
              const SizedBox(width: 2),
              Icon(Icons.notifications_active, size: 8, color: color),
            ],
          ],
        ),
        const SizedBox(height: 1),
        Text(
          title,
          style: const TextStyle(fontSize: 9, height: 1.15),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    ),
  );
}

/// The week of Mon 27 Jul – Sun 2 Aug 2026 with Makar's events: recurring
/// speech therapy (Mon & Thu 18:10), swimming (Sat 11:30 — after the frame-4
/// move) and the Sunday birthday. A real photo strip heads the canvas.
Widget _calendarCanvas(String lang) {
  const colors = FahColors.dark;
  final ru = lang == 'ru';
  final dayNames = ru
      ? ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс']
      : ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const dates = [27, 28, 29, 30, 31, 1, 2];
  final events = <int, List<Widget>>{
    0: [
      _eventChip(
        colors,
        time: '18:10',
        title: ru ? 'Логопед' : 'Speech',
        color: FahPalette.teal,
      ),
    ],
    3: [
      _eventChip(
        colors,
        time: '18:10',
        title: ru ? 'Логопед' : 'Speech',
        color: FahPalette.teal,
      ),
    ],
    5: [
      _eventChip(
        colors,
        time: '11:30',
        title: ru ? 'Бассейн' : 'Swim',
        color: FahPalette.indigo,
      ),
    ],
    6: [
      _eventChip(
        colors,
        title: ru ? 'Макару — 7!' : 'Makar turns 7!',
        color: const Color(0xFFF59E0B),
        icon: Icons.cake,
      ),
    ],
  };

  return ColoredBox(
    color: colors.bg,
    child: Column(
      children: [
        SizedBox(
          height: 120,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(
                _weekHeaderBytes,
                fit: BoxFit.cover,
                width: double.infinity,
                height: 120,
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      colors.bg.withValues(alpha: 0.9),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 10,
                child: Text(
                  ru
                      ? 'Неделя Макара · 27 июля — 2 августа'
                      : 'Makar\'s week · Jul 27 — Aug 2',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        border: i == 0
                            ? null
                            : Border(
                                left: BorderSide(
                                  color: colors.border.withValues(alpha: 0.5),
                                ),
                              ),
                      ),
                      child: Column(
                        children: [
                          Text(
                            dayNames[i],
                            style: TextStyle(fontSize: 11, color: colors.dim),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            width: 26,
                            height: 26,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == 0
                                  ? colors.indigo
                                  : Colors.transparent,
                            ),
                            child: Text(
                              '${dates[i]}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: i == 0
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                                color: i == 0 ? colors.onAccent : colors.text,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          ...?events[i],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// store_calendar: the recurring Mon/Thu/Sat events with alarms in the
/// calendar week view.
Future<void> _calendarShot(
  WidgetTester tester,
  _Device device,
  Locale locale,
) async {
  final env = MemoryExecutionEnv();
  await _pumpStore(
    tester,
    _calendarHost(env, locale.languageCode),
    device: device,
    locale: locale,
    screen: 'store_calendar',
  );
  // The header photo decodes on the real event loop.
  await _settleRealAsync(tester, rounds: 12);
  await tester.pump();
  await _expectStore(tester, device, locale, 'store_calendar');
}

// --- Frame 3: store_apps — sessions and the apps gallery --------------------

/// store_apps: the docked sidebar (model card, story sessions, persisted
/// session, demo apps) on wide layouts; the opened drawer on the phone.
Future<void> _appsShot(
  WidgetTester tester,
  _Device device,
  Locale locale,
) async {
  _mockBundledAppAssets();
  final env = MemoryExecutionEnv();
  await _seedSessionNames(env, locale.languageCode);
  final service = _fakeService(env);
  service.messages
    ..add(
      FahChatMessage(
        role: 'user',
        content: locale.languageCode == 'ru'
            ? 'когда у Макара логопед на этой неделе?'
            : "when is Makar's speech therapy this week?",
      ),
    )
    ..add(
      FahChatMessage(
        role: 'assistant',
        content: locale.languageCode == 'ru'
            ? 'Каждый понедельник и четверг в 18:10 — напоминание придёт '
                  'за 30 минут. В эту неделю: 27 и 30 июля.'
            : 'Every Monday and Thursday at 18:10 — the alarm fires 30 '
                  'minutes before. This week: Jul 27 and Jul 30.',
      ),
    );
  final manager = await _storyManager(env, service);

  await _pumpStore(
    tester,
    ChatScreen(manager: manager),
    device: device,
    locale: locale,
    screen: 'store_apps',
  );
  if (device.name == 'ios') {
    // Narrow layout: the sidebar is a lazy drawer — let the screen settle,
    // open it (via the Scaffold, not a hit-tested tap), then wait for its
    // demo apps to seed.
    await tester.pumpAndSettle();
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();
  }
  await _settleSidebarApps(tester);
  await _expectStore(tester, device, locale, 'store_apps');
}

// --- Frame 4: store_inapp — Fa inside the map app ---------------------------

/// The square marketing promo (App Review / social artwork): the same
/// story sidebar+gallery composition as store_apps at 1024×1024.
Future<void> _promoShot(WidgetTester tester, Locale locale) async {
  const device = (name: 'promo', physical: Size(1024, 1024), dpr: 1.0);
  _mockBundledAppAssets();
  final env = MemoryExecutionEnv();
  await _seedSessionNames(env, locale.languageCode);
  final service = _fakeService(env);
  service.messages
    ..add(
      FahChatMessage(
        role: 'user',
        content: locale.languageCode == 'ru'
            ? 'когда у Макара логопед на этой неделе?'
            : "when is Makar's speech therapy this week?",
      ),
    )
    ..add(
      FahChatMessage(
        role: 'assistant',
        content: locale.languageCode == 'ru'
            ? 'Каждый понедельник и четверг в 18:10 — напоминание придёт '
                  'за 30 минут. В эту неделю: 27 и 30 июля.'
            : 'Every Monday and Thursday at 18:10 — the alarm fires 30 '
                  'minutes before. This week: Jul 27 and Jul 30.',
      ),
    );
  final manager = await _storyManager(env, service);

  await _pumpStore(
    tester,
    ChatScreen(manager: manager),
    device: device,
    locale: locale,
    screen: 'store_apps',
  );
  await _settleSidebarApps(tester);
  await _expectStore(tester, device, locale, 'store_promo');
}

// --- Frame 5: store_providers — the provider story ---------------------------

/// The bundled Map demo's inline SVG icon (from
/// `assets/apps/map/manifest.json`).
const _mapSvgIcon =
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'>"
    "<path d='M12 2 C7.6 2 4 5.6 4 10 C4 15.4 12 22 12 22 C12 22 20 15.4 "
    "20 10 C20 5.6 16.4 2 12 2 Z' fill='#ef4444'/>"
    "<circle cx='12' cy='10' r='3' fill='#fecaca'/></svg>";

/// Offline tile provider: every tile is the same in-memory PNG, so the map
/// renders a full grid without network access (same fixture as the apps
/// golden tests).
final class _StoreTileProvider extends TileProvider {
  _StoreTileProvider(this.bytes);

  final Uint8List bytes;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(bytes);
}

Marker _pin(LatLng point, String label, Color color) {
  return Marker(
    point: point,
    width: 110,
    height: 58,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.location_on, color: color, size: 28),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: const TextStyle(fontSize: 10, color: Colors.white),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

/// The map canvas: Grodno center (like the bundled Map demo) with the two
/// story pins — the pool and the speech therapist. The pins sit north of
/// center on purpose: the expanded Fa chat sheet covers the bottom ~76% of
/// the view, so the visible map strip is the top edge.
Widget _mapCanvas(String lang) {
  final ru = lang == 'ru';
  return FlutterMap(
    options: MapOptions(
      initialCenter: const LatLng(53.6790, 23.8255),
      initialZoom: 14,
    ),
    children: [
      TileLayer(
        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        userAgentPackageName: 'dev.fa1.app',
        tileProvider: _StoreTileProvider(_mapTileBytes),
      ),
      MarkerLayer(
        markers: [
          _pin(
            const LatLng(53.6890, 23.8231),
            ru ? 'Бассейн' : 'Pool',
            FahPalette.indigo,
          ),
          _pin(
            const LatLng(53.6918, 23.8290),
            ru ? 'Логопед' : 'Speech therapy',
            FahPalette.teal,
          ),
        ],
      ),
    ],
  );
}

/// A JsAppView-like scaffold for the map app with the expanded in-place Fa
/// chat overlay pulled up over the canvas (the map stays visible above the
/// sheet). The service is idle, so the footer work bar stays hidden and the
/// frame is static.
Widget _mapOverlayHost(
  MemoryExecutionEnv env,
  AgentService service,
  String lang,
) {
  final mapApp = JsAppInfo.fromManifest(
    const {'id': 'map', 'name': 'Map', 'icon': _mapSvgIcon},
    bundled: false,
    fallbackId: 'map',
  );
  return Scaffold(
    appBar: AppBar(
      title: Row(
        children: [
          AppIcon(app: mapApp, env: env, size: 24),
          const SizedBox(width: 8),
          const Flexible(child: Text('Map', overflow: TextOverflow.ellipsis)),
        ],
      ),
      actions: [
        IconButton(icon: const Icon(Icons.shield_outlined), onPressed: () {}),
        IconButton(icon: const Icon(Icons.refresh), onPressed: () {}),
      ],
    ),
    body: LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Positioned.fill(child: _mapCanvas(lang)),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              top: constraints.maxHeight * 0.24,
              child: FaChatOverlay(
                service: service,
                onSend: (text) async {},
                onCollapse: () {},
                onOpenFullChat: () {},
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// store_inapp: the follow-up edit ("move swimming to 11:30") done from the
/// expanded Fa chat overlay without leaving the map app.
Future<void> _inappShot(
  WidgetTester tester,
  _Device device,
  Locale locale,
) async {
  final env = MemoryExecutionEnv();
  final service = _fakeService(env);
  final ru = locale.languageCode == 'ru';
  service.messages.addAll([
    FahChatMessage(
      role: 'user',
      content: ru
          ? 'Перенеси субботнее плавание на 11:30'
          : 'Move Saturday swimming to 11:30',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'calendar_update',
      content:
          'Event "Swimming" updated: Saturday 11:30–12:15, alarm 1 hour '
          'before (calendar "Family").',
    ),
    FahChatMessage(
      role: 'assistant',
      content: ru
          ? 'Готово — плавание теперь в субботу в 11:30. Метка бассейна на '
                'карте уже на месте.'
          : 'Done — swimming is now Saturday 11:30. The pool pin on the map '
                'is already in place.',
    ),
  ]);

  await tester.runAsync(() async {
    // The map's tile loading and decoding all live on the real event loop
    // (pumping the widget in the fake zone leaves the canvas blank), so the
    // whole pump + wait sequence happens inside runAsync — the same dance
    // as the apps map goldens.
    await _pumpStore(
      tester,
      _mapOverlayHost(env, service, locale.languageCode),
      device: device,
      locale: locale,
      screen: 'store_inapp',
    );
    // The marker labels prove the MarkerLayer built.
    final poolLabel = ru ? 'Бассейн' : 'Pool';
    for (var i = 0; i < 20 && find.text(poolLabel).evaluate().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    expect(find.text(poolLabel), findsWidgets);
    // Wait until the offline tiles actually decoded and painted.
    var painted = false;
    for (var i = 0; i < 50 && !painted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      painted = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((r) => r.image != null);
    }
    expect(painted, isTrue, reason: 'map tiles never decoded');
    await tester.pump(const Duration(milliseconds: 300));
  });
  await tester.pump();
  await _expectStore(tester, device, locale, 'store_inapp');
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
    Future<Uint8List> read(String path) => File(path).readAsBytes();
    _birthdayCardBytes = await read(
      'test/golden/assets/store/birthday_card.png',
    );
    _clubPhotoBytes = await read('test/golden/assets/store/club_photo.jpg');
    _weekHeaderBytes = await read('test/golden/assets/store/week_header.jpg');
    _mapTileBytes = await read('test/golden/assets/map_tile.png');
  });

  group('App Store screenshots — the "Makar\'s week" story', () {
    testWidgets('store_chat — the ask: plan, recurring events, card, voice', (
      tester,
    ) async {
      for (final device in _devices) {
        for (final locale in _locales) {
          await _chatShot(tester, device, locale);
        }
      }
    });

    testWidgets('store_calendar — recurring events and alarms in the week', (
      tester,
    ) async {
      for (final device in _devices) {
        for (final locale in _locales) {
          await _calendarShot(tester, device, locale);
        }
      }
    });

    testWidgets('store_apps — story sessions next to the apps gallery', (
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

    testWidgets('store_inapp — Fa chat overlay over the map app', (
      tester,
    ) async {
      for (final device in _devices) {
        for (final locale in _locales) {
          await _inappShot(tester, device, locale);
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
