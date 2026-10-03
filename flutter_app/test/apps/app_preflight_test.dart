// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1164 Part C: the `open_app` pre-flight gate —
///
/// - gate selection (AC10): a standing test file + a toolchain runner →
///   `flutter-test`; otherwise the headless smoke render;
/// - the "no fake success" contract (AC7): a gate failure rejects the
///   tool call with the gate name and the error excerpt;
/// - the smoke probe itself boots a real JS engine on a scratch copy of
///   the app folder and never writes back.
library;

import 'package:fa/apps/app_preflight.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/open_app_tool.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import '../native_test_guard.dart';

/// Skip value stamped on the engine-dependent group (issue #184).
final _engineSkip = quickJsBridgeAvailable ? false : kQuickJsBridgeUnavailable;

/// Real-time budget for the smoke probe inside `tester.runAsync` (the
/// engine needs the real event loop; 3s covers boot + render).
const Duration _shortBudget = Duration(seconds: 3);

JsAppInfo _app(String id) => JsAppInfo.fromManifest(
  {'id': id, 'name': id},
  bundled: false,
  fallbackId: id,
);

void main() {
  group('gate selection (runAppPreflight)', () {
    test('the standing acceptance test path is test/apps/<id>_test.dart', () {
      expect(appTestPath('weather'), 'test/apps/weather_test.dart');
    });

    test(
      'a standing test file + runner selects the flutter-test gate',
      () async {
        final env = MemoryExecutionEnv();
        await env.writeFile('apps/demo/widget.js', 'x');
        await env.writeFile('test/apps/demo_test.dart', 'void main() {}');
        final gates = <String>[];
        final outcome = await runAppPreflight(
          env,
          _app('demo'),
          testRunner: (env, testPath) {
            gates.add('flutter-test:$testPath');
            return Future.value(const AppPreflightOk(gate: 'flutter-test'));
          },
          smokeRender: (env, app, {required budget}) {
            gates.add('smoke-render');
            return Future.value(const AppPreflightOk(gate: 'smoke-render'));
          },
        );
        expect(gates, ['flutter-test:test/apps/demo_test.dart']);
        expect(outcome.gate, 'flutter-test');
      },
    );

    test(
      'no test file → the smoke gate runs even with a runner wired',
      () async {
        final env = MemoryExecutionEnv();
        final outcome = await runAppPreflight(
          env,
          _app('demo'),
          testRunner: (env, testPath) =>
              Future.value(const AppPreflightOk(gate: 'flutter-test')),
          smokeRender: (env, app, {required budget}) =>
              Future.value(const AppPreflightOk(gate: 'smoke-render')),
        );
        expect(outcome.gate, 'smoke-render');
      },
    );

    test('a red standing test fails with the test failure excerpt', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('test/apps/demo_test.dart', 'some: failure');
      final outcome = await runAppPreflight(
        env,
        _app('demo'),
        testRunner: (env, testPath) => Future.value(
          const AppPreflightFailure(
            gate: 'flutter-test',
            excerpt: 'Expected: 200\n  Actual: 500',
          ),
        ),
      );
      expect(outcome, isA<AppPreflightFailure>());
      expect((outcome as AppPreflightFailure).excerpt, contains('Actual: 500'));
    });
  });

  group('defaultAppPreflight', () {
    test('omits the gate on hosts that cannot boot the JS engine', () {
      expect(
        defaultAppPreflight(
          MemoryExecutionEnv(),
          jsEngineBootableOverride: false,
        ),
        isNull,
      );
    });

    test('wires the gate when the engine is bootable', () {
      final preflight = defaultAppPreflight(
        MemoryExecutionEnv(),
        jsEngineBootableOverride: true,
      );
      expect(preflight, isNotNull);
    });

    test('the real host probe never throws and agrees with itself', () {
      late final AppPreflight? wired;
      expect(
        () => wired = defaultAppPreflight(MemoryExecutionEnv()),
        returnsNormally,
      );
      if (jsEngineBootable) {
        expect(wired, isNotNull);
      } else {
        expect(wired, isNull);
      }
    });
  });

  group('preflightExcerptForTool', () {
    test('names the gate and carries the excerpt', () {
      final text = preflightExcerptForTool(
        const AppPreflightFailure(gate: 'smoke-render', excerpt: 'boom'),
      );
      expect(text, contains('smoke-render'));
      expect(text, contains('boom'));
    });

    test('oversized excerpts cap with an explicit truncation marker', () {
      final text = preflightExcerptForTool(
        AppPreflightFailure(
          gate: 'flutter-test',
          excerpt: 'x' * (AppPreflightFailure.maxExcerptChars + 500),
        ),
      );
      expect(text, contains('truncated from'));
      expect(text.length, lessThan(AppPreflightFailure.maxExcerptChars + 100));
    });
  });

  group('openAppTool pre-flight gate', () {
    test(
      'a gate failure rejects the call with the gate name + excerpt',
      () async {
        final env = MemoryExecutionEnv();
        await env.writeFile('apps/demo/manifest.json', '{"id":"demo"}');
        final launched = <String>[];
        final tool = openAppTool(
          env,
          launcher: (app) => launched.add(app.id),
          preflight: (app) async => const AppPreflightFailure(
            gate: 'smoke-render',
            excerpt: 'ReferenceError: foo is not defined',
          ),
        );

        await expectLater(
          tool.execute({'id': 'demo'}, null, null),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('smoke-render'),
                contains('ReferenceError: foo is not defined'),
              ),
            ),
          ),
        );
        expect(launched, isEmpty, reason: 'a failing gate never opens the app');
      },
    );

    test('a passing gate opens the app and reports success', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/manifest.json', '{"id":"demo"}');
      final launched = <String>[];
      final tool = openAppTool(
        env,
        launcher: (app) => launched.add(app.id),
        preflight: (app) async => const AppPreflightOk(gate: 'flutter-test'),
      );

      final result = await tool.execute({'id': 'demo'}, null, null);
      expect(launched, ['demo']);
      expect(
        result.content.whereType<TextContent>().map((b) => b.text).join(),
        "Opened app 'demo'",
      );
    });

    test('a broken manifest is rejected before the gate runs', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/broken/manifest.json', '{not json');
      var gateRan = false;
      final tool = openAppTool(
        env,
        launcher: (_) {},
        preflight: (app) async {
          gateRan = true;
          return const AppPreflightOk(gate: 'smoke-render');
        },
      );

      await expectLater(
        tool.execute({'id': 'broken'}, null, null),
        throwsA(isA<StateError>()),
      );
      expect(gateRan, isFalse);
    });

    test('no gate wired → unchanged back-compat behavior', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/manifest.json', '{"id":"demo"}');
      final launched = <String>[];
      final tool = openAppTool(env, launcher: (app) => launched.add(app.id));

      await tool.execute({'id': 'demo'}, null, null);
      expect(launched, ['demo']);
    });
  });

  group('smokeRenderApp (real JS engine)', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    testWidgets('a healthy app passes the smoke gate', (tester) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile(
          'apps/healthy/widget.js',
          '(function(){ jsr.render({type:"text",data:"hi"}); })();',
        );
        final outcome = await smokeRenderApp(
          env,
          _app('healthy'),
          budget: _shortBudget,
        );
        expect(outcome.gate, 'smoke-render');
        expect(outcome, isA<AppPreflightOk>());
      });
    });

    testWidgets('a load-time throw fails with the error message', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile(
          'apps/broken/widget.js',
          '(function(){ jsr.onEvent(function(){}); '
              'throw new Error("boom at load"); })();',
        );
        final outcome = await smokeRenderApp(
          env,
          _app('broken'),
          budget: _shortBudget,
        );
        expect(outcome, isA<AppPreflightFailure>());
        expect(
          (outcome as AppPreflightFailure).excerpt,
          contains('boom at load'),
        );
      });
    });

    testWidgets('a jsr.showError call fails with the shown message', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile(
          'apps/errored/widget.js',
          '(function(){ jsr.showError("cannot divide by zero"); })();',
        );
        final outcome = await smokeRenderApp(
          env,
          _app('errored'),
          budget: _shortBudget,
        );
        expect(outcome, isA<AppPreflightFailure>());
        expect(
          (outcome as AppPreflightFailure).excerpt,
          contains('cannot divide by zero'),
        );
      });
    });

    testWidgets(
      'a syntax error (no render at all) fails with the no-render excerpt',
      (tester) async {
        await tester.runAsync(() async {
          final env = MemoryExecutionEnv();
          await env.writeFile(
            'apps/unparseable/widget.js',
            '(function(){ jsr.render({type::: oops });',
          );
          final outcome = await smokeRenderApp(
            env,
            _app('unparseable'),
            budget: _shortBudget,
          );
          expect(outcome, isA<AppPreflightFailure>());
          expect(
            (outcome as AppPreflightFailure).excerpt,
            contains('no render'),
          );
        });
      },
    );

    testWidgets('the probe never writes back to the source env', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile(
          'apps/healthy/widget.js',
          '(function(){ jsr.render({type:"text",data:"hi"}); })();',
        );
        await smokeRenderApp(env, _app('healthy'), budget: _shortBudget);
        final listing = await env.listDir('apps/healthy');
        expect(listing.valueOrNull!.map((e) => e.name).toSet(), {
          'widget.js',
        }, reason: 'the probe ran on a scratch copy of the app folder');
      });
    });
  }, skip: _engineSkip);
}
