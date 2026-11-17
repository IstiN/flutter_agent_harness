// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';
import 'package:js_widget_runtime/src/runtime/js_widget_engine_flutter_js.dart';

import '../native_test_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('flutter_js fallback renders with the upgraded runtime', (
    tester,
  ) async {
    await tester.runAsync(() async {
      Map<String, dynamic>? tree;
      final engine = JsWidgetEngine(
        config: JsRuntimeConfig(
          widgetId: 'flutter-js-smoke',
          onRender: (value) => tree = value,
          onSetTitle: (_) {},
          onStorageUpdate: (_) {},
          backendFactory: (config) =>
              FlutterJsWidgetEngineBackend(config: config),
        ),
      );
      try {
        await engine.init();
        await engine.run('''
          jsr.render({type: 'text', data: 'flutter_js works'});
          jsr.exportState({ready: true});
        ''');
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(tree?['type'], 'text');
        expect(tree?['data'], 'flutter_js works');
        expect(engine.exportedState?['ready'], isTrue);
      } finally {
        await engine.dispose();
      }
    });
  }, skip: !quickJsBridgeAvailable);
}
