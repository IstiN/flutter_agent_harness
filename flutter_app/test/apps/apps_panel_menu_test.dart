// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Widget tests for the AppsPanel long-press context menu (issue #701 CRAP
// descent #12): `_showAppMenu` — Open / Publish… / Remove-widget items per
// bundled flag, the remove confirmation dialog (cancel + confirm), the
// removal-failure snackbar, and menu dismissal. Harness mirrors
// test/golden/apps_panel_golden_test.dart (memory env + fake service).

import 'dart:convert' show jsonDecode, utf8;
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/apps_panel.dart';
import 'package:fa/ui/widgets/widget_publish_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

const _customManifest = '''
{
  "id": "alpha",
  "name": "Alpha Widget",
  "description": "A custom widget",
  "icon": "🅰️"
}
''';

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

Future<MemoryExecutionEnv> _seededEnv() async {
  final env = MemoryExecutionEnv();
  await env.writeFile('apps/alpha/manifest.json', _customManifest);
  await env.writeFile(
    'apps/alpha/widget.js',
    '(function(){ jsr.render({type:"text",data:"hi"}); })();',
  );
  return env;
}

Future<String> _noAssets(String path) async =>
    throw StateError('no bundled assets in this test: $path');

/// A store whose removals always fail, for the snackbar branch — the real
/// [AppsStore.removeWidget] cannot fail with `force: true`.
class _FailingRemoveStore extends AppsStore {
  _FailingRemoveStore(super.env, {required super.readAsset});

  @override
  Future<bool> removeWidget(String appId, {bool force = false}) async => false;
}

/// Serves a hand-built app list, so the `bundled: true` menu shape (the
/// manifest loader always reports `bundled: false` for env apps) can be
/// asserted in isolation.
class _ScriptedListStore extends AppsStore {
  _ScriptedListStore(super.env, {required super.readAsset, required this.apps});

  final List<JsAppInfo> apps;

  @override
  Future<List<JsAppInfo>> listApps() async => apps;
}

Future<MemoryExecutionEnv> _pumpPanel(
  WidgetTester tester, {
  AppsStore? store,
}) async {
  final env = await _seededEnv();
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
  manager.addSession('test-session', _fakeService(env));
  final effective = store ?? AppsStore(env, readAsset: _noAssets);
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      home: Scaffold(
        body: ManagerScope(
          manager: manager,
          child: AppsPanel(manager: manager, appsStore: effective),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return env;
}

Future<void> _longPress(WidgetTester tester, String appName) async {
  await tester.longPress(find.text(appName).first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('long-press on a custom app offers open/publish/remove', (
    tester,
  ) async {
    await _pumpPanel(tester);
    await _longPress(tester, 'Alpha Widget');

    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Publish…'), findsOneWidget);
    expect(find.text('Remove widget'), findsOneWidget);
  });

  testWidgets('long-press on a bundled app offers open only', (tester) async {
    final env = await _seededEnv();
    await _pumpPanel(
      tester,
      store: _ScriptedListStore(
        env,
        readAsset: _noAssets,
        apps: [
          const JsAppInfo(
            id: 'beta',
            name: 'Beta Demo',
            description: 'A bundled demo',
            icon: '🅱️',
            declaredPermissions: AppPermissions(),
            bundled: true,
          ),
        ],
      ),
    );
    await _longPress(tester, 'Beta Demo');

    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Publish…'), findsNothing);
    expect(find.text('Remove widget'), findsNothing);
  });

  testWidgets('dismissing the menu changes nothing', (tester) async {
    await _pumpPanel(tester);
    await _longPress(tester, 'Alpha Widget');

    // Dismiss via the barrier (a tap far outside the menu).
    await tester.tapAt(const Offset(10, 850));
    await tester.pumpAndSettle();

    expect(find.text('Open'), findsNothing);
    expect(find.text('Remove Alpha Widget?'), findsNothing);
    expect(find.text('Alpha Widget'), findsOneWidget);
  });

  testWidgets('open pushes the JS app view', (tester) async {
    await _pumpPanel(tester);
    await _longPress(tester, 'Alpha Widget');

    // flutter_js's getJavascriptRuntime() evaluates its fetch polyfill from
    // a package asset the local test bundle does not carry (CI resolves it
    // through the git pin; worktrees override flutter_js as a path dep).
    // Serve that one key through the asset channel from the resolved
    // flutter_js package's own file — identical bytes in both worlds. The
    // package root comes from package_config.json (resolvePackageUri is
    // unsupported under the test harness's patched isolate).
    const fetchKey = 'packages/flutter_js/assets/js/fetch.js';
    final configUri = Uri.base.resolve('.dart_tool/package_config.json');
    final config =
        jsonDecode(io.File.fromUri(configUri).readAsStringSync())
            as Map<String, Object?>;
    final packages = config['packages']! as List<Object?>;
    final jsRoot =
        packages
                .map((p) => p! as Map<String, Object?>)
                .firstWhere((p) => p['name'] == 'flutter_js')['rootUri']!
            as String;
    final fetchJs = io.File.fromUri(
      configUri.resolve('$jsRoot/assets/js/fetch.js'),
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Future<ByteData?>? assetHandler(ByteData? message) async {
      final key = utf8.decode(message!.buffer.asUint8List());
      if (key != fetchKey) return null;
      final bytes = fetchJs.readAsBytesSync();
      return ByteData.view(bytes.buffer);
    }

    // The JS engine boots on the real event loop (the JavaScriptCore
    // backend needs it — same pattern as js_app_view_test.dart); a fake
    // zone settle would hang on its periodic timer.
    await tester.runAsync(() async {
      messenger.setMockMessageHandler('flutter/assets', assetHandler);
      await tester.tap(find.text('Open'));
      await tester.pump();
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
        if (find.byType(JsAppView).evaluate().isNotEmpty) break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
      messenger.setMockMessageHandler('flutter/assets', null);
    });
    expect(find.byType(JsAppView), findsOneWidget);

    // Unmount so the engine disposes before teardown.
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });

  testWidgets('canceling the remove dialog keeps the widget', (tester) async {
    final env = await _pumpPanel(tester);
    await _longPress(tester, 'Alpha Widget');

    await tester.tap(find.text('Remove widget'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Alpha Widget?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Remove Alpha Widget?'), findsNothing);
    expect(find.text('Alpha Widget'), findsOneWidget);
    expect((await env.listDir('apps/alpha')).valueOrNull, isNotEmpty);
  });

  testWidgets('confirming remove deletes the widget files but keeps data', (
    tester,
  ) async {
    final env = await _pumpPanel(tester);
    await env.writeFile('apps/alpha/storage.json', '{"kept":true}');
    await _longPress(tester, 'Alpha Widget');

    await tester.tap(find.text('Remove widget'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(find.text('Remove Alpha Widget?'), findsNothing);
    expect(find.text('Alpha Widget'), findsNothing);
    // storage.json survives a force removal by contract.
    final data = await env.readTextFile('apps/alpha/storage.json');
    expect(data.valueOrNull, '{"kept":true}');
  });

  testWidgets('a failed removal surfaces the snackbar', (tester) async {
    final env = await _seededEnv();
    final store = _FailingRemoveStore(env, readAsset: _noAssets);
    await _pumpPanel(tester, store: store);
    await _longPress(tester, 'Alpha Widget');

    await tester.tap(find.text('Remove widget'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(find.text('Could not remove Alpha Widget.'), findsOneWidget);
    expect(find.text('Alpha Widget'), findsOneWidget);
  });

  testWidgets('publish opens the publish sheet', (tester) async {
    await _pumpPanel(tester);
    await _longPress(tester, 'Alpha Widget');

    await tester.tap(find.text('Publish…'));
    await tester.pumpAndSettle();

    expect(find.byType(WidgetPublishSheet), findsOneWidget);
  });
}
