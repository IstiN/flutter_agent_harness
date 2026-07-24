// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Golden (screenshot) tests for the JS apps platform widgets:
/// app_icon.dart, apps_grid.dart, fa_work_bar.dart and js_app_view.dart.
///
/// Everything runs on MemoryExecutionEnv with fixed manifests — no network,
/// no real file system, no real JS engine. The JsAppView coverage uses the
/// deterministic start-error chrome (missing widget.js) instead of booting
/// the JavaScriptCore backend. FaWorkBar owns an infinitely repeating pulse
/// animation, so its states are pumped frame-by-frame (never pumpAndSettle).
library;

import 'package:fa/agent_service.dart';
import 'package:fa/app_theme.dart';
import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/apps_grid.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/fa_work_bar.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

const _demoManifest = '''
{
  "id": "demo",
  "name": "Demo App",
  "description": "A demo app",
  "icon": "🧪"
}
''';

// Single-quoted XML attributes so the icon can sit inside a JSON manifest.
const _svgIcon =
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'>"
    "<circle cx='12' cy='12' r='10' fill='#4F8CFF'/></svg>";

const _svgManifest =
    '''
{
  "id": "svg-app",
  "name": "SVG App",
  "description": "Inline SVG icon",
  "icon": "$_svgIcon"
}
''';

const _plainManifest = '''
{
  "id": "plain",
  "name": "Plain App",
  "description": "No icon declared"
}
''';

Future<MemoryExecutionEnv> _seededEnv() async {
  final env = MemoryExecutionEnv();
  for (final (id, manifest) in [
    ('demo', _demoManifest),
    ('svg-app', _svgManifest),
    ('plain', _plainManifest),
  ]) {
    await env.writeFile('apps/$id/manifest.json', manifest);
    await env.writeFile(
      'apps/$id/widget.js',
      '(function(){ jsr.render({type:"text",data:"hi"}); })();',
    );
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

/// pumpGolden without the pumpAndSettle: FaWorkBar's pulse animation repeats
/// forever, so settling would time out. A fixed pump sequence keeps the
/// animation phase identical between snapshot generation and comparison.
Future<void> _pumpFrames(
  WidgetTester tester,
  Widget child, {
  Size size = goldenSizeTall,
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

Widget _workBarHost(AgentService service) {
  return Scaffold(
    body: Column(
      children: [
        const Expanded(child: Center(child: Text('JS app body'))),
        FaWorkBar(service: service, onSend: (text) async {}),
      ],
    ),
  );
}

void main() {
  testWidgets('apps grid with seeded demo apps', (tester) async {
    final env = await _seededEnv();
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
      size: goldenSizeWide,
      wrap: (child) => child,
    );
    await expectGolden(tester, 'apps_grid');
  });

  testWidgets('app icon variants', (tester) async {
    final env = MemoryExecutionEnv();
    await pumpGolden(
      tester,
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Emoji text icon (the common case).
          AppIcon(
            app: _app(const {'id': 'demo', 'name': 'Demo', 'icon': '🧪'}),
            env: env,
            size: 48,
          ),
          const SizedBox(width: 24),
          // No icon in the manifest → the 📦 fallback glyph.
          AppIcon(
            app: _app(const {'id': 'plain', 'name': 'Plain'}),
            env: env,
            size: 48,
          ),
          const SizedBox(width: 24),
          // Inline SVG markup icon.
          AppIcon(
            app: _app(const {'id': 'svg', 'name': 'SVG', 'icon': _svgIcon}),
            env: env,
            size: 48,
          ),
        ],
      ),
    );
    await expectGolden(tester, 'apps_icon_variants');
  });

  testWidgets('work bar hidden while idle', (tester) async {
    final service = _hungService();
    addTearDown(service.dispose);
    await _pumpFrames(tester, _workBarHost(service));
    expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
    await expectGolden(tester, 'apps_work_bar_idle');
  });

  testWidgets('work bar streaming with follow-up input', (tester) async {
    final service = _hungService();
    addTearDown(service.dispose);
    await _pumpFrames(tester, _workBarHost(service));
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
    final app = _app(const {'id': 'demo', 'name': 'Demo', 'icon': '🧪'});
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
    await env.writeFile('apps/broken/manifest.json', _demoManifest);
    final permissions = await AppPermissionsStore.load(env);
    await pumpGolden(
      tester,
      JsAppView(
        app: _app(const {
          'id': 'broken',
          'name': 'Broken App',
          'icon': '🧪',
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
