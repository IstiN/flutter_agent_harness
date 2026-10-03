// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1164 Part B (engine side): the JS runtime's crash surfaces are
/// captured and forwarded to the error sink —
///
/// - load-time throws (the runtime reports them through `jsr.showError`);
/// - per-frame/per-tick callback throws (swallowed by the bridge, so an
///   animation erroring every frame previously died silently);
/// - host-side render exceptions (`reportHostError`);
/// - the source revision the error fired against (the dedup boundary).
///
/// Delivery dedup (AC4) is the channel gate's job — see
/// `js_app_error_channel_test.dart`; the session re-entry (AC5) — see
/// `agent_service_js_app_error_delivery_test.dart`.
library;

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import '../native_test_guard.dart';

/// Skip value stamped on every engine-dependent test (issue #184).
final _engineSkip = quickJsBridgeAvailable ? false : kQuickJsBridgeUnavailable;

JsAppEngine _engine(
  ExecutionEnv env, {
  required String id,
  void Function(JsAppErrorEvent event)? errorSink,
}) {
  return JsAppEngine(
    app: JsAppInfo.fromManifest(
      {'id': id, 'name': id},
      bundled: false,
      fallbackId: id,
    ),
    env: env,
    permissions: const AppPermissions(),
    errorSink: errorSink,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(
    'engine error capture (gh-1164)',
    () {
      testWidgets('a load-time throw is captured with the app id and revision',
          (tester) async {
        final env = MemoryExecutionEnv();
        await env.writeFile(
          'apps/broken/widget.js',
          '(function(){ jsr.onEvent(function(){}); '
          'throw new Error("boom at load"); })();',
        );
        final events = <JsAppErrorEvent>[];
        final engine = _engine(env, id: 'broken', errorSink: events.add);
        try {
          await tester.runAsync(() async {
            await engine.start();
            await Future<void>.delayed(const Duration(milliseconds: 300));
          });
          expect(events, hasLength(1));
          expect(events.single.kind, 'showError');
          expect(events.single.message, contains('boom at load'));
          expect(engine.sourceRevision, isNotEmpty);
        } finally {
          await tester.runAsync(engine.dispose);
        }
      });

      testWidgets(
          '100 identical per-tick errors are captured raw (the gate '
          'collapses them to ONE report)', (tester) async {
        final env = MemoryExecutionEnv();
        await env.writeFile(
          'apps/spinner/widget.js',
          '(function(){'
          'jsr.onEvent(function(){});'
          'var n = 0;'
          'var t = setInterval(function(){'
          '  n++;'
          '  if (n > 100) { clearInterval(t); return; }'
          '  throw new Error("tick boom");'
          '}, 1);'
          '})();',
        );
        final events = <JsAppErrorEvent>[];
        final engine = _engine(env, id: 'spinner', errorSink: events.add);
        try {
          await tester.runAsync(() async {
            await engine.start();
            // 100 ticks at 1ms plus engine boot — real-time budget.
            await Future<void>.delayed(const Duration(milliseconds: 900));
          });
          expect(events, hasLength(100), reason: 'the engine forwards raw '
              'events; the session gate does the collapsing');
          for (final event in events) {
            expect(event.kind, 'callback');
            expect(event.message, 'tick boom');
          }
        } finally {
          await tester.runAsync(engine.dispose);
        }
      });

      testWidgets('a host render exception reports through reportHostError',
          (tester) async {
        final env = MemoryExecutionEnv();
        await env.writeFile(
          'apps/ok/widget.js',
          '(function(){ jsr.onEvent(function(){}); '
          'jsr.render({type:"text",data:"hi"}); })();',
        );
        final events = <JsAppErrorEvent>[];
        final engine = _engine(env, id: 'ok', errorSink: events.add);
        try {
          await tester.runAsync(() async {
            await engine.start();
            await Future<void>.delayed(const Duration(milliseconds: 300));
          });
          engine.reportHostError('host render failed', stack: 'at build');
          expect(events, hasLength(1));
          expect(events.single.kind, 'render');
          expect(events.single.message, 'host render failed');
          expect(events.single.stack, 'at build');
        } finally {
          await tester.runAsync(engine.dispose);
        }
      });

      testWidgets(
          'a source edit changes the revision the next run reports against',
          (tester) async {
        final env = MemoryExecutionEnv();
        await env.writeFile(
          'apps/edited/widget.js',
          '(function(){ jsr.onEvent(function(){}); '
          'throw new Error("still broken"); })();',
        );
        final engine = _engine(env, id: 'edited');
        try {
          var first = '';
          await tester.runAsync(() async {
            await engine.start();
            await Future<void>.delayed(const Duration(milliseconds: 200));
            first = engine.sourceRevision;
          });
          await tester.runAsync(engine.dispose);

          // The agent's edit — same error, different source.
          await env.writeFile(
            'apps/edited/widget.js',
            '(function(){ jsr.onEvent(function(){}); '
            'throw new Error("still broken"); })(); // v2',
          );
          final engine2 = _engine(env, id: 'edited');
          try {
            await tester.runAsync(() async {
              await engine2.start();
              await Future<void>.delayed(const Duration(milliseconds: 200));
              expect(engine2.sourceRevision, isNot(first));
            });
          } finally {
            await tester.runAsync(engine2.dispose);
          }
        } finally {
          // `engine` was disposed inside the runAsync block above when the
          // test reached it; a start failure still owns a half-started
          // native engine — dispose is idempotent-safe here.
          await tester.runAsync(engine.dispose).catchError((_) {});
        }
      });
    },
    skip: _engineSkip,
  );
}
