// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Golden (screenshot) tests for the JS apps platform widgets:
/// app_icon.dart, apps_grid.dart, fa_work_bar.dart and js_app_view.dart.
///
/// Everything runs on MemoryExecutionEnv with fixed manifests — no network,
/// no real file system writes, no real JS engine. The grid seeds the ten
/// bundled demo manifests (read from assets/apps/ on disk) plus twelve
/// custom "agent-built" apps. The JsAppView coverage uses the deterministic
/// start-error chrome (missing widget.js) instead of booting the
/// JavaScriptCore backend; FaWorkBar states render over a hand-built
/// calculator canvas. FaWorkBar owns an infinitely repeating orbit
/// animation, so its states are pumped frame-by-frame (never pumpAndSettle).
///
/// Note: the golden font sandbox (Inter + JetBrainsMono only) has no emoji
/// font — emoji manifest icons render as NO GLYPH boxes. Bundled manifests
/// with emoji icons get an inline-SVG stand-in here; crypto's '₿' glyph and
/// calculator's icon.svg render for real.
library;

import 'dart:convert';
import 'dart:io';

import 'package:fa/services/agent_service.dart';
import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/apps_grid.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/fa_work_bar.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

// --- Inline SVG icons (single-quoted XML so they embed in JSON manifests) --

const _weatherIcon =
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'>"
    "<circle cx='9' cy='9' r='4' fill='#fbbf24'/>"
    "<ellipse cx='14' cy='16' rx='7' ry='4.5' fill='#e5e7eb'/></svg>";

const _stocksIcon =
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'>"
    "<polyline points='3,17 8,11 12,14 21,5' fill='none' stroke='#34d399' "
    "stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'/>"
    "<polyline points='15,5 21,5 21,11' fill='none' stroke='#34d399' "
    "stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'/></svg>";

const _animationIcon =
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'>"
    "<rect x='2' y='4' width='20' height='16' rx='4' fill='#a78bfa'/>"
    "<polygon points='10,9 16,12 10,15' fill='#0b0f17'/></svg>";

const _sparkleIcon =
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'>"
    "<path d='M12 2 L14 10 L22 12 L14 14 L12 22 L10 14 L2 12 L10 10 Z' "
    "fill='#2dd4bf'/></svg>";

const _circleIcon =
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'>"
    "<circle cx='12' cy='12' r='10' fill='#4F8CFF'/></svg>";

const _alertIcon =
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'>"
    "<rect x='1' y='1' width='22' height='22' rx='6' fill='#f43f5e'/>"
    "<rect x='10.8' y='6' width='2.4' height='8' rx='1.2' fill='#f8fafc'/>"
    "<circle cx='12' cy='17.5' r='1.6' fill='#f8fafc'/></svg>";

/// The bundled demo manifests declare emoji icons, which the golden font
/// sandbox cannot render — substitute an equivalent inline SVG (calculator's
/// icon.svg file and crypto's '₿' glyph are kept verbatim).
const _bundledIconOverrides = <String, String>{
  'weather': _weatherIcon,
  'stocks': _stocksIcon,
  'animation-showcase': _animationIcon,
  'yolo-hello': _sparkleIcon,
};

/// A simple rounded-square icon with a white glyph shape.
String _badgeIcon(String bg, String shape) =>
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'>"
    "<rect x='1' y='1' width='22' height='22' rx='6' fill='$bg'/>"
    '$shape</svg>';

const _fg = '#f8fafc';

/// Custom "agent-built" apps filling the grid next to the bundled demos.
Map<String, List<String>> get _customApps => {
  // id → [name, description, icon]
  'notes': [
    'Notes',
    'Quick markdown notes',
    _badgeIcon(
      '#6366f1',
      "<rect x='7' y='7' width='10' height='2' rx='1' fill='$_fg'/>"
          "<rect x='7' y='11' width='10' height='2' rx='1' fill='$_fg'/>"
          "<rect x='7' y='15' width='6' height='2' rx='1' fill='$_fg'/>",
    ),
  ],
  'pomodoro': [
    'Pomodoro',
    'Focus timer with breaks',
    _badgeIcon(
      '#f43f5e',
      "<circle cx='12' cy='13' r='6' fill='none' stroke='$_fg' "
          "stroke-width='2'/><rect x='10' y='4' width='4' height='2' rx='1' "
          "fill='$_fg'/><path d='M12 13 L12 9.5' stroke='$_fg' "
          "stroke-width='2' stroke-linecap='round'/>",
    ),
  ],
  'unit-converter': [
    'Unit Converter',
    'Length, mass, temperature',
    _badgeIcon(
      '#0ea5e9',
      "<path d='M7 8 L16 8 M13.5 5.5 L16 8 L13.5 10.5' stroke='$_fg' "
          "stroke-width='2' fill='none' stroke-linecap='round' "
          "stroke-linejoin='round'/><path d='M17 16 L8 16 M10.5 13.5 L8 16 "
          "L10.5 18.5' stroke='$_fg' stroke-width='2' fill='none' "
          "stroke-linecap='round' stroke-linejoin='round'/>",
    ),
  ],
  'habit-tracker': [
    'Habit Tracker',
    'Daily streaks and reminders',
    _badgeIcon(
      '#22c55e',
      "<path d='M7 12.5 L10.5 16 L17 8.5' stroke='$_fg' stroke-width='2.5' "
          "fill='none' stroke-linecap='round' stroke-linejoin='round'/>",
    ),
  ],
  'dice-roller': [
    'Dice Roller',
    'd4 to d20, advantage rolls',
    _badgeIcon(
      '#8b5cf6',
      "<circle cx='8.5' cy='8.5' r='1.8' fill='$_fg'/>"
          "<circle cx='15.5' cy='8.5' r='1.8' fill='$_fg'/>"
          "<circle cx='8.5' cy='15.5' r='1.8' fill='$_fg'/>"
          "<circle cx='15.5' cy='15.5' r='1.8' fill='$_fg'/>",
    ),
  ],
  'markdown-pad': [
    'Markdown Pad',
    'Live preview editor',
    _badgeIcon(
      '#64748b',
      "<rect x='6' y='7' width='3' height='10' rx='1' fill='$_fg'/>"
          "<rect x='11' y='7' width='3' height='10' rx='1' fill='$_fg'/>"
          "<rect x='16' y='7' width='3' height='6' rx='1' fill='$_fg'/>",
    ),
  ],
  'color-palette': [
    'Color Palette',
    'Extract and save palettes',
    _badgeIcon(
      '#ec4899',
      "<circle cx='9' cy='9' r='3' fill='$_fg'/>"
          "<circle cx='15' cy='9' r='3' fill='#fbbf24'/>"
          "<circle cx='12' cy='15' r='3' fill='#2dd4bf'/>",
    ),
  ],
  'qr-generator': [
    'QR Generator',
    'Links and Wi-Fi codes',
    _badgeIcon(
      '#14b8a6',
      "<rect x='6' y='6' width='5' height='5' fill='$_fg'/>"
          "<rect x='13' y='6' width='5' height='5' fill='$_fg'/>"
          "<rect x='6' y='13' width='5' height='5' fill='$_fg'/>"
          "<rect x='14' y='14' width='4' height='4' fill='$_fg'/>",
    ),
  ],
  'stopwatch': [
    'Stopwatch',
    'Laps and splits',
    _badgeIcon(
      '#f59e0b',
      "<circle cx='12' cy='13' r='6.5' fill='none' stroke='$_fg' "
          "stroke-width='2'/><path d='M12 13 L15 10.5' stroke='$_fg' "
          "stroke-width='2' stroke-linecap='round'/>"
          "<rect x='10' y='4' width='4' height='2' rx='1' fill='$_fg'/>",
    ),
  ],
  'tip-calculator': [
    'Tip Calculator',
    'Split the bill fairly',
    _badgeIcon(
      '#f97316',
      "<circle cx='9' cy='9' r='2' fill='none' stroke='$_fg' "
          "stroke-width='1.8'/><circle cx='15' cy='15' r='2' fill='none' "
          "stroke='$_fg' stroke-width='1.8'/><path d='M16.5 7.5 L7.5 16.5' "
          "stroke='$_fg' stroke-width='2' stroke-linecap='round'/>",
    ),
  ],
  'flashcards': [
    'Flashcards',
    'Spaced repetition decks',
    _badgeIcon(
      '#06b6d4',
      "<rect x='8' y='5' width='10' height='12' rx='2' fill='#94a3b8'/>"
          "<rect x='5' y='8' width='10' height='12' rx='2' fill='$_fg'/>",
    ),
  ],
  'sound-board': [
    'Sound Board',
    'Custom sound pads',
    _badgeIcon(
      '#84cc16',
      "<rect x='6' y='10' width='2.5' height='4' rx='1' fill='$_fg'/>"
          "<rect x='10.75' y='6' width='2.5' height='12' rx='1' fill='$_fg'/>"
          "<rect x='15.5' y='9' width='2.5' height='6' rx='1' fill='$_fg'/>",
    ),
  ],
};

Future<void> _writeApp(
  MemoryExecutionEnv env,
  String id,
  Map<String, Object?> manifest,
) async {
  await env.writeFile('apps/$id/manifest.json', jsonEncode(manifest));
  await env.writeFile(
    'apps/$id/widget.js',
    '(function(){ jsr.render({type:"text",data:"hi"}); })();',
  );
}

/// Seeds the ten bundled demo apps (manifests read from assets/apps/ on
/// disk) plus the custom apps into an in-memory env.
Future<MemoryExecutionEnv> _seededEnv() async {
  final env = MemoryExecutionEnv();
  for (final id in AppsStore.demoAppIds) {
    final raw = await File('assets/apps/$id/manifest.json').readAsString();
    final manifest = (jsonDecode(raw) as Map).cast<String, Object?>();
    final override = _bundledIconOverrides[id];
    if (override != null) manifest['icon'] = override;
    await _writeApp(env, id, manifest);
  }
  await env.writeFile(
    'apps/calculator/icon.svg',
    await File('assets/apps/calculator/icon.svg').readAsString(),
  );
  for (final entry in _customApps.entries) {
    await _writeApp(env, entry.key, {
      'id': entry.key,
      'name': entry.value[0],
      'description': entry.value[1],
      'icon': entry.value[2],
    });
  }
  return env;
}

JsAppInfo _app(Map<String, Object?> manifest, {String fallbackId = 'demo'}) {
  return JsAppInfo.fromManifest(
    manifest,
    bundled: false,
    fallbackId: fallbackId,
  );
}

/// The hung-streaming service from test/apps/fa_work_bar_test.dart: the
/// provider stream stays open until aborted, so `isStreaming` stays true.
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

/// pumpGolden without the pumpAndSettle: FaWorkBar's orbit animation repeats
/// forever while the service streams, so settling would time out. A fixed
/// pump sequence keeps the animation phase identical between snapshot
/// generation and comparison.
Future<void> _pumpFrames(
  WidgetTester tester,
  Widget child, {
  Size size = goldenSizeDesktop,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildFahTheme(),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
  await tester.pump();
}

/// A hand-built stand-in for a running JS app render tree: a calculator pad,
/// so the FaWorkBar shots show the bar over a realistic app canvas instead
/// of an empty scaffold.
Widget _calculatorCanvas() {
  const rows = [
    ['C', '±', '%', '÷'],
    ['7', '8', '9', '×'],
    ['4', '5', '6', '−'],
    ['1', '2', '3', '+'],
    ['0', '.', '( )', '='],
  ];
  const operators = {'÷', '×', '−', '+'};
  return ColoredBox(
    color: FahPalette.bg,
    child: Center(
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: FahPalette.panel,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: FahPalette.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: FahPalette.panelAlt,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '128 × 27 + 36',
                    style: FahPalette.mono(color: FahPalette.dim, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '3,492',
                    style: FahPalette.mono(
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
  String label, {
  bool isOperator = false,
  bool isEquals = false,
}) {
  return Container(
    height: 56,
    decoration: BoxDecoration(
      color: isEquals
          ? FahPalette.indigo
          : isOperator
          ? FahPalette.userBubble
          : FahPalette.panelAlt,
      borderRadius: BorderRadius.circular(12),
      border: isEquals ? null : Border.all(color: FahPalette.border),
    ),
    child: Center(
      child: Text(
        label,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: isEquals
              ? FahPalette.onAccent
              : isOperator
              ? FahPalette.indigo
              : FahPalette.text,
        ),
      ),
    ),
  );
}

/// A JsAppView-like scaffold: app bar with the app icon + name + the
/// permissions/reload actions, the mock app canvas, and the FaWorkBar
/// docked at the bottom (hidden unless the service streams).
Widget _workBarHost(AgentService service, MemoryExecutionEnv env) {
  final calcApp = _app(const {
    'id': 'calculator',
    'name': 'Calculator',
    'icon': 'icon.svg',
  }, fallbackId: 'calculator');
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

Widget _iconTile(String label, Widget icon) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          color: FahPalette.panelAlt,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: FahPalette.border),
        ),
        child: Center(child: icon),
      ),
      const SizedBox(height: 10),
      Text(label, style: const TextStyle(color: FahPalette.dim, fontSize: 13)),
    ],
  );
}

void main() {
  setUpAll(ensureGoldenFonts);

  testWidgets('apps grid filled with demo apps', (tester) async {
    // Real file IO must run outside the FakeAsync test zone.
    final env = (await tester.runAsync(_seededEnv))!;
    final permissions = await AppPermissionsStore.load(env);
    await pumpGolden(
      tester,
      AppsGridView(
        env: env,
        permissionsStore: permissions,
        appsStore: AppsStore(
          env,
          readAsset: (path) async =>
              throw StateError('no bundled assets in this test'),
          seedDemoIds: const [],
        ),
      ),
      size: goldenSizeDesktop,
      wrap: (child) => child,
    );
    await expectGolden(tester, 'apps_grid');
  });

  testWidgets('app icon showcase', (tester) async {
    final env = MemoryExecutionEnv();
    // Real file IO must run outside the FakeAsync test zone.
    final calcSvg = (await tester.runAsync(
      () => File('assets/apps/calculator/icon.svg').readAsString(),
    ))!;
    await env.writeFile('apps/calculator/icon.svg', calcSvg);
    final calcApp = _app(const {
      'id': 'calculator',
      'name': 'Calculator',
      'icon': 'icon.svg',
    }, fallbackId: 'calculator');
    final svgApp = _app(const {
      'id': 'svg',
      'name': 'SVG',
      'icon': _circleIcon,
    });
    final glyphApp = _app(const {
      'id': 'crypto',
      'name': 'Crypto',
      'icon': '₿',
    });
    await pumpGolden(
      tester,
      Container(
        width: 1120,
        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 40),
        decoration: BoxDecoration(
          color: FahPalette.panel,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: FahPalette.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'App icons',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              'Every icon form a manifest can declare, at the sizes the '
              'grid and toolbars render them.',
              style: TextStyle(color: FahPalette.dim, fontSize: 14),
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _iconTile(
                  'Inline SVG',
                  AppIcon(app: svgApp, env: env, size: 48),
                ),
                _iconTile(
                  'SVG file',
                  AppIcon(app: calcApp, env: env, size: 48),
                ),
                _iconTile(
                  'Text glyph',
                  AppIcon(app: glyphApp, env: env, size: 48),
                ),
                _iconTile(
                  'Grid size',
                  AppIcon(app: svgApp, env: env, size: 32),
                ),
                _iconTile(
                  'Toolbar size',
                  AppIcon(app: calcApp, env: env, size: 22),
                ),
              ],
            ),
          ],
        ),
      ),
      size: goldenSizeDesktop,
    );
    await expectGolden(tester, 'apps_icon_variants');
  });

  testWidgets('work bar hidden while idle', (tester) async {
    // Real file IO must run outside the FakeAsync test zone.
    final env = (await tester.runAsync(_seededEnv))!;
    final service = _hungService();
    addTearDown(service.dispose);
    await _pumpFrames(tester, _workBarHost(service, env));
    expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
    await expectGolden(tester, 'apps_work_bar_idle');
  });

  testWidgets('work bar streaming with follow-up input', (tester) async {
    // Real file IO must run outside the FakeAsync test zone.
    final env = (await tester.runAsync(_seededEnv))!;
    final service = _hungService();
    addTearDown(service.dispose);
    await _pumpFrames(tester, _workBarHost(service, env));
    await tester.runAsync(() async {
      await service.sendText('work');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(service.isStreaming, isTrue);
    await tester.enterText(find.byType(TextField), 'make it purple');
    await tester.pump();
    await expectGolden(tester, 'apps_work_bar_streaming');
  });

  testWidgets('app permissions dialog with a persisted override', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final app = _app(const {
      'id': 'demo',
      'name': 'Demo',
      'icon': _sparkleIcon,
    });
    // A "previous run" enabled Network; the reloaded store exposes it.
    final store = await AppPermissionsStore.load(env);
    await store.setOverride('demo', const AppPermissions(network: true));
    final reloaded = await AppPermissionsStore.load(env);
    await pumpGolden(
      tester,
      AppPermissionsDialog(app: app, env: env, store: reloaded),
    );
    await expectGolden(tester, 'apps_permissions_dialog');
  });

  testWidgets('app view start-error chrome (no JS engine booted)', (
    tester,
  ) async {
    // manifest.json exists but widget.js is missing: JsAppEngine.start()
    // fails while reading the source, before ever touching the JS backend —
    // a deterministic error state covering the view chrome.
    final env = MemoryExecutionEnv();
    // Only the manifest — no widget.js.
    await env.writeFile(
      'apps/broken/manifest.json',
      jsonEncode(const {
        'id': 'broken',
        'name': 'Broken App',
        'icon': _alertIcon,
      }),
    );
    final permissions = await AppPermissionsStore.load(env);
    await pumpGolden(
      tester,
      JsAppView(
        app: _app(const {
          'id': 'broken',
          'name': 'Broken App',
          'icon': _alertIcon,
        }, fallbackId: 'broken'),
        env: env,
        permissionsStore: permissions,
        onSendToAgent: (message) async {},
      ),
      size: goldenSizeWide,
      wrap: (child) => child,
    );
    await expectGolden(tester, 'apps_view_error');
  });
}
