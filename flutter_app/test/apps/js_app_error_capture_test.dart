// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1164 Part B (AC3/AC4): the engine captures JS load/runtime errors and
/// forwards them to the [JsAppEngine.errorSink] — the owner (app-wide
/// channel or the pre-flight probe) applies the gate + delivery. Real JS
/// engine required (issue #184 guard).
library;

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import '../native_test_guard.dart';

final _engineSkip = quickJsBridgeAvailable ? false : kQuickJsBridgeUnavailable;

JsAppInfo _app() => JsAppInfo.fromManifest(
  const {'id': 'demo', 'name': 'Demo'},
  bundled: false,
  fallbackId: 'demo',
);

void main() {
  testWidgets(
    'a load-time throw is captured through jsr.showError',
    skip: _engineSkip,
    (tester) async {
      final captured = <JsAppErrorEvent>[];
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile(
          'apps/demo/widget.js',
          'throw new Error("load blew up");',
        );
        final engine = JsAppEngine(
          app: _app(),
          env: env,
          permissions: const AppPermissions(),
          errorSink: captured.add,
        );
        try {
          await engine.start();
          // The runtime surfaces load throws through jsr.showError — give
          // the bridge a moment to deliver the log line.
          for (var i = 0; i < 40 && captured.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
        } on Object {
          // The start throw itself is expected — capture rides the log tap.
        }
        await engine.dispose();
      });
      expect(captured, isNotEmpty, reason: 'the load error must be captured');
      expect(
        captured.first.message,
        contains('load blew up'),
        reason: 'captured: ${captured.first.message}',
      );
    },
  );

  testWidgets(
    'per-frame callback errors are captured with the callback kind',
    skip: _engineSkip,
    (tester) async {
      final captured = <JsAppErrorEvent>[];
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile(
          'apps/demo/widget.js',
          '''
(function() {
  jsr.render({type: 'text', data: 'hi'});
  var n = 0;
  setInterval(function() {
    n++;
    throw new Error('frame error ' + n);
  }, 30);
})();
''',
        );
        final engine = JsAppEngine(
          app: _app(),
          env: env,
          permissions: const AppPermissions(),
          errorSink: captured.add,
        );
        await engine.start();
        for (var i = 0; i < 40 && captured.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        await engine.dispose();
      });
      expect(captured, isNotEmpty, reason: 'frame errors must be captured');
      expect(
        captured.first.kind,
        JsAppErrorKind.callback,
        reason: 'captured kinds: ${captured.map((e) => e.kind.name)}',
      );
    },
  );

  testWidgets(
    'sourceRevision re-arms when the app source changes (AC4)',
    skip: _engineSkip,
    (tester) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile(
          'apps/demo/widget.js',
          '(function(){jsr.render({type:"text",data:"v1"});})();',
        );
        final engine = JsAppEngine(
          app: _app(),
          env: env,
          permissions: const AppPermissions(),
        );
        await engine.start();
        final first = engine.sourceRevision;
        expect(first, isNotEmpty);
        await engine.dispose();

        await env.writeFile(
          'apps/demo/widget.js',
          '(function(){jsr.render({type:"text",data:"v2"});})();',
        );
        final second = JsAppEngine(
          app: _app(),
          env: env,
          permissions: const AppPermissions(),
        );
        await second.start();
        expect(second.sourceRevision, isNot(first));
        await second.dispose();
      });
    },
  );
}
