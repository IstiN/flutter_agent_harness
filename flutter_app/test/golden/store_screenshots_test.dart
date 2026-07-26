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
import 'package:fa/apps/fa_work_bar.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/screens/providers_section.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// The hung-streaming service from the apps golden tests: the provider
/// stream stays open until aborted, so `isStreaming` stays true and the
/// FaWorkBar keeps its streaming chrome.
AgentService _hungService() {
  fn(Model model, dynamic context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final partial = AssistantMessage(
      content: const [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime(2026, 1, 1),
    );
    stream.push(StartEvent(partial: partial));
    cancelToken?.onCancel.then((_) {
      stream.push(ErrorEvent(reason: StopReason.aborted, error: partial));
      stream.end();
    });
    return stream; // stays open until aborted
  }

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
      streamFunction: fn,
      toolRegistry: ToolRegistry(const []),
    ),
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
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

/// A 64×64 teal→indigo gradient swatch PNG (618 bytes), generated once
/// offline and embedded so the generated-image shot never touches network
/// or assets (same swatch as chat_golden_test.dart).
final Uint8List _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAACMUlEQVR42u3a2TaV'
  'cRzGcbfQWg67ipAhpUmIFCqpZJ7bUZLpJkpzUQgJIZmnsAfbtodsmaU0kCShC/A/'
  '6+j5HXXwPmu9az0X8P2cPx57PPdSz0MH6ID/CNjnGvFyGtW8HUYfh8nHbtpvN/uO'
  'm31tFj+bxX9sVC3Aaj2gNmoNtIwdVDPbDpltQaZxtcNG+5ERNcfRYccxtSHn8SFn'
  '8DtX8KDrxOD7kAG1idD+ibB+d1if+2SvO7x3MrxnMqLnw6lutanIrqnTndNqZzqm'
  'ozpmotpnottnY97OxrTNnW2bO/dmXu1860Js6wIEUNTHtogA7ddfaF6EAIr6OAFA'
  'UR/3+iMGMNRfFAAU9ZealiCAol4EMNRfbvwEART18Q0YQFEf3/BZAmi//sorDKCo'
  'TxAAFPUJ9csYwFCfKAAo6pNefoEAivqkOgHAUJ9c9xUCKOpTajGAoj6l9psE0H59'
  'ag0GUNSn1XyHAIr6tBcSgKA+vRoDKOozqlcggKI+o0oAMNRnVq1CAEV9ViUGUNRn'
  'Vf7AAIb67OcYQFGf82wNAijqZQBB/dUKDKCoN1T8hACKekO5AGCov1a+DgEU9blP'
  'MYCiPvfJLwxgqM8TABT11x9vQABFvQwgqL/x6DcEUNTnCwCK+vyHIkD79TcfbEIA'
  'RX2BAKCoL7j/BwMY6m8JAIr6wntbEEBRLwIY6ovubkMARX1xGQZQ1BeX7UgA7deX'
  '3MEAivpSAUBRX3r7r/7c1QE64N92ATXq/Gi3ONqSAAAAAElFTkSuQmCC',
);

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

// --- Screen builders --------------------------------------------------------

/// The hero chat conversation: a user question, a collapsed thinking block,
/// tool calls, and a Markdown answer with an inline generated image. The
/// conversation itself is localized too — store visitors read it.
List<FahChatMessage> _heroConversation(String lang) {
  final ru = lang == 'ru';
  return [
    FahChatMessage(
      role: 'user',
      content: ru
          ? 'сгенерируй новый градиент для шапки лендинга и вставь его на страницу'
          : 'generate a fresh gradient for the landing hero and drop it into '
                'the page',
    ),
    FahChatMessage(
      role: 'thinking',
      content: [
        ru
            ? 'Посмотрю, как устроена шапка лендинга.'
            : 'Let me look at how the landing hero is built.',
        ru
            ? 'Фирменные цвета — teal→indigo…'
            : 'The brand colors are teal→indigo…',
        ru
            ? '…соберу мягкий диагональный перелив.'
            : '…so a soft diagonal sweep fits best.',
        ru
            ? 'Сначала прочитаю разметку страницы:'
            : 'Reading the page markup first:',
        '  - site/index.html: <header class="hero">',
        '  - assets live under generated/',
        ru
            ? 'Сгенерирую изображение и обновлю CSS,'
            : 'I will generate the artwork, update the CSS,',
        ru
            ? 'затем проверю, что ссылка на файл верна.'
            : 'then verify the file reference resolves.',
        ru
            ? 'Ничего больше шапку не использует —'
            : 'Nothing else touches the hero —',
        ru
            ? 'изменение локально, риск минимален.'
            : 'the change is local, risk is minimal.',
        ru
            ? 'План: read → generate_image → правка CSS.'
            : 'Plan: read → generate_image → patch CSS.',
      ].join('\n'),
    ),
    FahChatMessage(
      role: 'system',
      content: '[read] {"path": "site/index.html"}',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'read',
      content:
          '41  <header class="hero">\n'
          '42    <h1>Fa — your personal AI agent</h1>\n'
          '43    <div class="hero-art"></div>\n'
          '44  </header>',
    ),
    FahChatMessage(
      role: 'tool',
      toolName: 'generate_image',
      content:
          'Generated image saved to generated/hero-gradient.png '
          '(618 bytes, 1024x1024). Reference it as '
          '![image](generated/hero-gradient.png) to display it inline in '
          'the chat.',
    ),
    FahChatMessage(
      role: 'assistant',
      content: ru
          ? 'Готово — вот новая шапка:\n\n'
                '![градиент для шапки](generated/hero-gradient.png)\n\n'
                'Вставил её в `site/index.html`: блок `.hero-art` теперь '
                'использует перелив teal-to-indigo.'
          : 'Done — here is the new hero artwork:\n\n'
                '![hero gradient](generated/hero-gradient.png)\n\n'
                'Dropped it into `site/index.html`: the `.hero-art` block '
                'now uses the teal-to-indigo sweep.',
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
  final env = MemoryExecutionEnv();
  await env.writeBinaryFile('generated/hero-gradient.png', _tinyPngBytes);
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  await repo.create(
    JsonlSessionCreateOptions(
      id: 'c0ffee01-landing-refresh',
      cwd: 'site',
      metadata: const {'agent': 'fa', 'model': 'old-model'},
    ),
  );
  final service = _fakeService(env);
  service.messages.addAll(_heroConversation(locale.languageCode));
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('7b21e04d-notes-app', _fakeService(env))
    ..addSession('f3a9c1d4-hero-artwork', service);

  await _pumpStore(
    tester,
    ChatScreen(manager: manager),
    device: device,
    locale: locale,
    screen: 'store_chat',
  );
  // The env image read + codec resolve on the real event loop; the sidebar
  // seeds its demo apps there too. Alternate real delays with pumps.
  await tester.runAsync(() async {
    for (var i = 0; i < 24; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
  });
  // Flush fake-time debounces (the message sync) with bounded pumps —
  // pumpAndSettle is not safe here (intermittent settle timeouts).
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  // The markdown image inside the assistant bubble starts loading only
  // after the bubble's first frame — give the real event loop more time.
  await tester.runAsync(() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
  });
  // Pin the chat to the tail: image loads grew the content after the last
  // follow-scroll, so jump deterministically. Jump every Scrollable — the
  // sidebar's short lists are unaffected, the chat list lands at its tail.
  for (final element in find.byType(Scrollable).evaluate()) {
    final state = (element as StatefulElement).state as ScrollableState;
    state.position.jumpTo(state.position.maxScrollExtent);
  }
  await tester.pump();
  // The sidebar (and its demo apps) only exists on wide layouts; on the
  // phone it is a lazy drawer that stays closed for the chat shot.
  if (device.name != 'ios') await _settleSidebarApps(tester);
  await _expectStore(tester, device, locale, 'store_chat');
}

/// store_sidebar: the docked sidebar (model card, sessions, persisted
/// session, apps) on wide layouts; the opened drawer on the phone.
Future<void> _sidebarShot(
  WidgetTester tester,
  _Device device,
  Locale locale,
) async {
  _mockBundledAppAssets();
  final env = MemoryExecutionEnv();
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  await repo.create(
    JsonlSessionCreateOptions(
      id: 'c0ffee01-restored-chat',
      cwd: 'openai-completions',
      metadata: const {'agent': 'fa', 'model': 'old-model'},
    ),
  );
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
  manager.addSession('aaa00001-first-chat', _fakeService(env));
  manager.addSession('bbb00002-second-chat', _fakeService(env));
  manager.active!.service.messages
    ..add(FahChatMessage(role: 'user', content: 'what is in README.md?'))
    ..add(
      FahChatMessage(
        role: 'assistant',
        content:
            'The README describes the **Flutter Agent Harness**:\n'
            '- a pure Dart agent core\n'
            '- a Flutter chat example app',
      ),
    );

  await _pumpStore(
    tester,
    ChatScreen(manager: manager),
    device: device,
    locale: locale,
    screen: 'store_sidebar',
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
  await _expectStore(tester, device, locale, 'store_sidebar');
}

// --- JS app shot (calculator canvas + streaming FaWorkBar) ------------------

const _calcSvgIcon =
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'>"
    "<rect x='1' y='1' width='22' height='22' rx='6' fill='#818CF8'/>"
    "<rect x='6' y='5' width='12' height='4' rx='1' fill='#06121A'/>"
    "<circle cx='8' cy='13' r='1.4' fill='#06121A'/>"
    "<circle cx='12' cy='13' r='1.4' fill='#06121A'/>"
    "<circle cx='16' cy='13' r='1.4' fill='#06121A'/>"
    "<circle cx='8' cy='17' r='1.4' fill='#06121A'/>"
    "<circle cx='12' cy='17' r='1.4' fill='#06121A'/>"
    "<circle cx='16' cy='17' r='1.4' fill='#06121A'/></svg>";

/// A hand-built stand-in for a running JS app render tree (the apps golden
/// tests' calculator pad) so the FaWorkBar shot shows the bar over a
/// realistic app canvas instead of booting the JS engine.
Widget _calculatorCanvas() {
  const colors = FahColors.dark;
  const rows = [
    ['C', '±', '%', '÷'],
    ['7', '8', '9', '×'],
    ['4', '5', '6', '−'],
    ['1', '2', '3', '+'],
    ['0', '.', '( )', '='],
  ];
  const operators = {'÷', '×', '−', '+'};
  return ColoredBox(
    color: colors.bg,
    child: Center(
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: colors.panel,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: colors.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: colors.panelAlt,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '128 × 27 + 36',
                    style: colors.mono(color: colors.dim, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '3,492',
                    style: colors.mono(
                      fontSize: 40,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    for (final key in row)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          child: _calcKey(
                            key,
                            colors,
                            isOperator: operators.contains(key),
                            isEquals: key == '=',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

Widget _calcKey(
  String label,
  FahColors colors, {
  bool isOperator = false,
  bool isEquals = false,
}) {
  return Container(
    height: 56,
    decoration: BoxDecoration(
      color: isEquals
          ? colors.indigo
          : isOperator
          ? colors.userBubble
          : colors.panelAlt,
      borderRadius: BorderRadius.circular(12),
      border: isEquals ? null : Border.all(color: colors.border),
    ),
    child: Center(
      child: Text(
        label,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: isEquals
              ? colors.onAccent
              : isOperator
              ? colors.indigo
              : colors.text,
        ),
      ),
    ),
  );
}

/// A JsAppView-like scaffold: app bar with the app icon + name, the mock app
/// canvas, and the FaWorkBar docked at the bottom.
Widget _workBarHost(AgentService service, MemoryExecutionEnv env) {
  final calcApp = JsAppInfo.fromManifest(
    const {'id': 'calculator', 'name': 'Calculator', 'icon': 'icon.svg'},
    bundled: false,
    fallbackId: 'calculator',
  );
  return Scaffold(
    appBar: AppBar(
      title: Row(
        children: [
          AppIcon(app: calcApp, env: env, size: 24),
          const SizedBox(width: 8),
          const Flexible(
            child: Text('Calculator', overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      actions: [
        IconButton(icon: const Icon(Icons.shield_outlined), onPressed: () {}),
        IconButton(icon: const Icon(Icons.refresh), onPressed: () {}),
      ],
    ),
    body: Stack(
      children: [
        Positioned.fill(child: _calculatorCanvas()),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: FaWorkBar(
            service: service,
            onSend: (text) async {},
            onExpand: () {},
          ),
        ),
      ],
    ),
  );
}

/// store_js_app: a JS mini-app canvas with the Fa work bar mid-run. The
/// orbit animation repeats forever, so this shot uses a fixed pump sequence
/// (never pumpAndSettle) — same as the apps golden tests.
Future<void> _jsAppShot(
  WidgetTester tester,
  _Device device,
  Locale locale,
) async {
  final env = MemoryExecutionEnv();
  await env.writeFile('apps/calculator/icon.svg', _calcSvgIcon);
  final service = _hungService();
  addTearDown(service.dispose);

  await _pumpStore(
    tester,
    _workBarHost(service, env),
    device: device,
    locale: locale,
    screen: 'store_js_app',
  );
  await tester.runAsync(() async {
    await service.sendText(
      locale.languageCode == 'ru'
          ? 'сделай калькулятор'
          : 'build me a calculator',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await tester.pump();
  expect(service.isStreaming, isTrue);
  await tester.enterText(
    find.byType(TextField),
    locale.languageCode == 'ru' ? 'сделай её фиолетовой' : 'make it purple',
  );
  await tester.pump();
  await _expectStore(tester, device, locale, 'store_js_app');
}

// --- Settings shots ---------------------------------------------------------

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

/// store_media: the media models section (one slot overridden) plus the
/// keys section — values are never shown, only their sources.
Future<void> _mediaShot(
  WidgetTester tester,
  _Device device,
  Locale locale,
) async {
  final mediaStore = MediaModelsStore.inMemory();
  await mediaStore.setOverride(
    MediaSlot.imageGeneration,
    const MediaSlotOverride(
      providerKind: 'openai-completions',
      baseUrl: 'https://openrouter.ai/api/v1',
      modelId: 'gpt-image-1',
    ),
  );
  final registry = ProviderRegistry.inMemory();
  final provider = await registry.add(
    name: 'Acme',
    baseUrl: 'https://acme.example/v1',
    modelId: 'acme-1',
  );
  registry.rememberKey(provider.id, 'acme-secret');
  final keysStore = SessionKeysStore.inMemory({
    'OPENROUTER_API_KEY': 'sk-or-saved',
  });
  await _pumpStore(
    tester,
    Builder(
      builder: (context) => _settingsFrame(
        context,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            MediaModelsSection(store: mediaStore),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            KeysSection(store: keysStore, registry: registry),
          ],
        ),
      ),
    ),
    device: device,
    locale: locale,
    screen: 'store_media',
  );
  await tester.pumpAndSettle();
  await _expectStore(tester, device, locale, 'store_media');
}

void main() {
  setUpAll(ensureGoldenFonts);

  group('App Store screenshots', () {
    testWidgets('store_chat — hero conversation with inline generated image', (
      tester,
    ) async {
      for (final device in _devices) {
        for (final locale in _locales) {
          await _chatShot(tester, device, locale);
        }
      }
    });

    testWidgets('store_sidebar — apps and sessions sidebar', (tester) async {
      for (final device in _devices) {
        for (final locale in _locales) {
          await _sidebarShot(tester, device, locale);
        }
      }
    });

    testWidgets('store_js_app — mini-app canvas with the Fa work bar', (
      tester,
    ) async {
      for (final device in _devices) {
        for (final locale in _locales) {
          await _jsAppShot(tester, device, locale);
        }
      }
    });

    testWidgets('store_providers — providers-first settings', (tester) async {
      for (final device in _devices) {
        for (final locale in _locales) {
          await _providersShot(tester, device, locale);
        }
      }
    });

    testWidgets('store_media — media models and keys sections', (tester) async {
      for (final device in _devices) {
        for (final locale in _locales) {
          await _mediaShot(tester, device, locale);
        }
      }
    });
  });
}
