// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Smoke test for the real JS backend (flutter_js / JavaScriptCore on the
/// macOS test host): boots the engine, expects a render tree, and checks the
/// fa-bridge permission gates.
///
/// Everything runs inside `tester.runAsync` with small real delays: the
/// JS→Dart bridge messages are processed on the real event loop, and the
/// fake-time `pump()` would both starve them and trip the pending-timer
/// invariant.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const settle = Duration(milliseconds: 300);

  const widgetJs = '''
(function() {
  jsr.onEvent(function(actionId, payload) {
    if (actionId === 'tap') {
      jsr.render({type: 'text', data: 'tapped'});
      jsr.exportState({tapped: true});
    }
  });
  jsr.render({type: 'text', data: 'hello'});
  jsr.exportState({ready: true});
})();
''';

  JsAppInfo app() => JsAppInfo.fromManifest(
    const {'id': 'demo', 'name': 'Demo'},
    bundled: false,
    fallbackId: 'demo',
  );

  testWidgets('engine renders the initial tree and exports state', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', widgetJs);
      final engine = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
      );
      try {
        await engine.start();
        await Future<void>.delayed(settle);

        expect(engine.tree.value, isNotNull);
        expect(jsonEncode(engine.tree.value), contains('hello'));
        expect(engine.exportedState, isNotNull);
        expect(engine.exportedState!['ready'], isTrue);

        await engine.callEvent('tap');
        await Future<void>.delayed(settle);
        expect(jsonEncode(engine.tree.value), contains('tapped'));
        expect(engine.exportedState!['tapped'], isTrue);
      } finally {
        await engine.dispose();
      }
    });
  });

  testWidgets('fa.llm is gated by the llm permission', (tester) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.llm('ping').then(function(result) {
    jsr.exportState({result: result});
  }, function(error) {
    jsr.exportState({result: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      Future<Object?> fakeLlm(String prompt) async => 'pong:$prompt';

      // Without the permission the bridge answers with a permission error.
      final denied = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
        llmHandler: fakeLlm,
      );
      try {
        await denied.start();
        await Future<void>.delayed(settle);
        expect(
          jsonEncode(denied.exportedState?['result']),
          contains('__error'),
        );
        expect(
          jsonEncode(denied.exportedState?['result']),
          contains('llm permission'),
        );
      } finally {
        await denied.dispose();
      }

      // With it, the handler runs.
      final granted = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(llm: true),
        llmHandler: fakeLlm,
      );
      try {
        await granted.start();
        await Future<void>.delayed(settle);
        expect(granted.exportedState?['result'], 'pong:ping');
      } finally {
        await granted.dispose();
      }
    });
  });
}
