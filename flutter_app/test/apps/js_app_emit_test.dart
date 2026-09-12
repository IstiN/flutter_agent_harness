// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import '../native_test_guard.dart';

/// Skip value stamped on this file's engine-dependent tests: every one
/// boots a real JS engine (issue #184). Resolved once per isolate.
final _engineSkip = quickJsBridgeAvailable ? false : kQuickJsBridgeUnavailable;

/// Host-side tests for the `jsr.fa.emit` bridge (dynamic messages): the
/// engine forwards one named event + JSON payload to the injected
/// [JsAppEngine.onEmit] sink and resolves `{emitted: true}`; without a sink
/// it resolves `{emitted: false}` and never throws into the bridge.
///
/// Same harness as js_app_engine_test.dart: everything runs inside
/// `tester.runAsync` with small real delays — the JS→Dart bridge messages
/// are processed on the real event loop, and the fake-time `pump()` would
/// both starve them and trip the pending-timer invariant.
void main() {
  group('JS engine (native quickjs/JavaScriptCore bridge)', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    const settle = Duration(milliseconds: 300);

    JsAppInfo app() => JsAppInfo.fromManifest(
      const {'id': 'demo', 'name': 'Demo'},
      bundled: false,
      fallbackId: 'demo',
    );

    /// Waits until the app exported state (the bridge calls cross real
    /// platform channels, so a single fixed settle can race under load).
    Future<void> waitForState(JsAppEngine engine) async {
      for (var i = 0; i < 40 && engine.exportedState == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }

    testWidgets('emit forwards the event and payload to the host sink', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile('apps/demo/widget.js', '''
  (function() {
    jsr.onEvent(function(actionId, payload) {
      if (actionId === 'tap') {
        jsr.fa.emit('toggled', {item: 1}).then(function(result) {
          jsr.exportState({result: result});
        }, function(error) {
          jsr.exportState({result: {__rejected: '' + error}});
        });
      }
    });
    jsr.render({type: 'text', data: 'x'});
  })();
  ''');
        final events = <({String event, Map<String, Object?> payload})>[];
        final engine = JsAppEngine(
          app: app(),
          env: env,
          permissions: const AppPermissions(),
          onEmit: (event, payload) =>
              events.add((event: event, payload: payload)),
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          await engine.callEvent('tap');
          await waitForState(engine);

          expect(events, hasLength(1));
          expect(events.single.event, 'toggled');
          expect(events.single.payload, {'item': 1});
          expect(engine.exportedState?['result'], {'emitted': true});
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('emit without a host sink resolves {emitted: false}', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile('apps/demo/widget.js', '''
  (function() {
    jsr.onEvent(function(actionId, payload) {});
    jsr.fa.emit('booted', {n: 1}).then(function(result) {
      jsr.exportState({result: result});
    }, function(error) {
      jsr.exportState({result: {__rejected: '' + error}});
    });
    jsr.render({type: 'text', data: 'x'});
  })();
  ''');
        final engine = JsAppEngine(
          app: app(),
          env: env,
          permissions: const AppPermissions(),
        );
        try {
          await engine.start();
          await waitForState(engine);

          expect(engine.exportedState?['result'], {'emitted': false});
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('a non-map payload coerces to an empty map', (tester) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile('apps/demo/widget.js', '''
  (function() {
    jsr.onEvent(function(actionId, payload) {});
    jsr.fa.emit('pinged', 'just-text').then(function(result) {
      jsr.exportState({result: result});
    }, function(error) {
      jsr.exportState({result: {__rejected: '' + error}});
    });
    jsr.render({type: 'text', data: 'x'});
  })();
  ''');
        final events = <({String event, Map<String, Object?> payload})>[];
        final engine = JsAppEngine(
          app: app(),
          env: env,
          permissions: const AppPermissions(),
          onEmit: (event, payload) =>
              events.add((event: event, payload: payload)),
        );
        try {
          await engine.start();
          await waitForState(engine);

          expect(events, hasLength(1));
          expect(events.single.event, 'pinged');
          expect(events.single.payload, isEmpty);
          expect(engine.exportedState?['result'], {'emitted': true});
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('an empty event name answers with an actionable error', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile('apps/demo/widget.js', '''
  (function() {
    jsr.onEvent(function(actionId, payload) {});
    jsr.fa.emit('', {}).then(function(result) {
      jsr.exportState({result: result});
    }, function(error) {
      jsr.exportState({result: {__rejected: '' + error}});
    });
    jsr.render({type: 'text', data: 'x'});
  })();
  ''');
        var sinkCalls = 0;
        final engine = JsAppEngine(
          app: app(),
          env: env,
          permissions: const AppPermissions(),
          onEmit: (event, payload) => sinkCalls++,
        );
        try {
          await engine.start();
          await waitForState(engine);

          // The host resolves {__error: ...} and the runtime bootstrap turns
          // that envelope into a promise rejection (see
          // js_widget_bootstrap.dart) — the widget sees the guidance, the
          // host sink never sees the nameless event.
          expect(sinkCalls, 0);
          expect(
            engine.exportedState?['result']?['__rejected'],
            contains('emit requires an event name'),
          );
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('a throwing host sink does not reject the bridge promise', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile('apps/demo/widget.js', '''
  (function() {
    jsr.onEvent(function(actionId, payload) {});
    jsr.fa.emit('boom', {}).then(function(result) {
      jsr.exportState({result: result});
    }, function(error) {
      jsr.exportState({result: {__rejected: '' + error}});
    });
    jsr.render({type: 'text', data: 'x'});
  })();
  ''');
        final engine = JsAppEngine(
          app: app(),
          env: env,
          permissions: const AppPermissions(),
          onEmit: (event, payload) => throw StateError('sink exploded'),
        );
        try {
          await engine.start();
          await waitForState(engine);

          // The sink failure is contained host-side (AppLog); the widget still
          // learns the emit was accepted.
          expect(engine.exportedState?['result'], {'emitted': true});
        } finally {
          await engine.dispose();
        }
      });
    });
  }, skip: _engineSkip);
}
