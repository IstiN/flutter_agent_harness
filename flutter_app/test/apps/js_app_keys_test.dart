// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Host-side tests for the `jsr.fa.keys.*` bridge: list/get read the
/// injected host-secrets source, request rides the injected prompt
/// callback — no real Keychain or UI involved.
///
/// Every test runs inside `tester.runAsync`: the JS engine's native work
/// and the JS→Dart bridge messages are processed on the real event loop
/// (same pattern as `js_app_engine_test.dart`). Each scenario boots its
/// own engine with a SINGLE top-level bridge call — chaining a second
/// bridge call from inside a `.then` resolution crashes the native JS
/// context in tests.
void main() {
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

  /// Boots an engine running [js] (which must call `jsr.exportState`),
  /// waits for the exported state, and returns it after disposing.
  Future<Map<String, dynamic>?> runApp(
    MemoryExecutionEnv env,
    String js, {
    AppPermissions permissions = const AppPermissions(keys: true),
    FaHostKeysSource? keysSource,
    RequestSecretCallback? keyRequestHandler,
  }) async {
    await env.writeFile('apps/demo/widget.js', js);
    final engine = JsAppEngine(
      app: app(),
      env: env,
      permissions: permissions,
      keysSource: keysSource,
      keyRequestHandler: keyRequestHandler,
    );
    try {
      await engine.start();
      await waitForState(engine);
      await Future<void>.delayed(settle);
      return engine.exportedState;
    } finally {
      await engine.dispose();
    }
  }

  Map<String, String> fakeKeys() => {
    'OPENAI_API_KEY': 'sk-test-openai',
    'WEATHER_API_KEY': 'weather-123',
  };

  /// Wraps one bridge call expression, exporting the resolution or the
  /// rejection as `{__error: ...}`.
  String callJs(String call) =>
      '''
(function() {
  $call.then(function(result) {
    jsr.exportState({result: result});
  }, function(error) {
    jsr.exportState({result: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''';

  testWidgets('fa.keys.list returns sorted names only, never values', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final state = await runApp(
        MemoryExecutionEnv(),
        callJs('jsr.fa.keys.list()'),
        keysSource: fakeKeys,
      );
      expect(state, {
        'result': {
          'keys': ['OPENAI_API_KEY', 'WEATHER_API_KEY'],
        },
      });
      // Values must not cross the list call.
      expect(jsonEncode(state), isNot(contains('sk-test')));
      expect(jsonEncode(state), isNot(contains('weather-123')));
    });
  });

  testWidgets('fa.keys.get resolves the value of one exact name', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final state = await runApp(
        MemoryExecutionEnv(),
        callJs("jsr.fa.keys.get('WEATHER_API_KEY')"),
        keysSource: fakeKeys,
      );
      expect(state, {
        'result': {'name': 'WEATHER_API_KEY', 'value': 'weather-123'},
      });
    });
  });

  testWidgets('fa.keys.get of an unknown name answers with an actionable '
      'error', (tester) async {
    await tester.runAsync(() async {
      final state = await runApp(
        MemoryExecutionEnv(),
        callJs("jsr.fa.keys.get('NOPE')"),
        keysSource: fakeKeys,
      );
      final result = jsonEncode(state?['result']);
      expect(result, contains('__error'));
      expect(result, contains('unknown host key'));
    });
  });

  testWidgets('fa.keys.request resolves a grant with name and value', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final requests = <({String name, String reason})>[];
      final state = await runApp(
        MemoryExecutionEnv(),
        callJs("jsr.fa.keys.request('WEATHER_API_KEY', 'for the weather API')"),
        keysSource: fakeKeys,
        keyRequestHandler: (name, reason) async {
          requests.add((name: name, reason: reason));
          return RequestSecretResult(name: name, value: 'granted-value');
        },
      );
      expect(state, {
        'result': {'name': 'WEATHER_API_KEY', 'value': 'granted-value'},
      });
      expect(requests.single.name, 'WEATHER_API_KEY');
      expect(requests.single.reason, 'for the weather API');
    });
  });

  testWidgets('fa.keys.request rejects when the user declines', (tester) async {
    await tester.runAsync(() async {
      final state = await runApp(
        MemoryExecutionEnv(),
        callJs("jsr.fa.keys.request('WEATHER_API_KEY', 'for the weather API')"),
        keysSource: fakeKeys,
        keyRequestHandler: (name, reason) async => null,
      );
      expect(jsonEncode(state?['result']), contains('declined'));
    });
  });

  testWidgets('fa.keys.* are gated by the keys permission', (tester) async {
    await tester.runAsync(() async {
      var promptCalls = 0;
      for (final call in [
        'jsr.fa.keys.list()',
        "jsr.fa.keys.get('OPENAI_API_KEY')",
        "jsr.fa.keys.request('OPENAI_API_KEY', 'why')",
      ]) {
        final state = await runApp(
          MemoryExecutionEnv(),
          callJs(call),
          permissions: const AppPermissions(),
          keysSource: fakeKeys,
          keyRequestHandler: (name, reason) async {
            promptCalls++;
            return RequestSecretResult(name: name, value: 'v');
          },
        );
        expect(
          jsonEncode(state?['result']),
          contains('keys permission'),
          reason: '$call must be permission-gated',
        );
      }
      expect(promptCalls, 0);
    });
  });

  testWidgets('granted fa.keys without a session backend answers with '
      'actionable errors', (tester) async {
    await tester.runAsync(() async {
      final listState = await runApp(
        MemoryExecutionEnv(),
        callJs('jsr.fa.keys.list()'),
      );
      expect(
        jsonEncode(listState?['result']),
        contains('not available in this session'),
      );
      final requestState = await runApp(
        MemoryExecutionEnv(),
        callJs("jsr.fa.keys.request('SOME_KEY', 'why')"),
      );
      expect(
        jsonEncode(requestState?['result']),
        contains('cannot prompt for secrets'),
      );
    });
  });
}
