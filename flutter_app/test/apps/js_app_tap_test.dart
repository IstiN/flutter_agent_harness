// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';

/// Tap-path check: taps on the rendered calculator must reach the JS engine
/// through JsonWidgetRenderer.onEvent and update the tree/state.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tapping a calculator key reaches the JS engine', (tester) async {
    final env = MemoryExecutionEnv();
    late final JsAppEngine engine;
    await tester.runAsync(() async {
      final source = await File(
        'assets/apps/calculator/widget.js',
      ).readAsString();
      await env.writeFile('apps/calculator/widget.js', source);
      engine = JsAppEngine(
        app: JsAppInfo.fromManifest(
          const {'id': 'calculator', 'name': 'Calculator', 'icon': '🧮'},
          bundled: false,
          fallbackId: 'calculator',
        ),
        env: env,
        permissions: const AppPermissions(),
      );
      await engine.start();
      for (var i = 0; i < 20 && engine.tree.value == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    addTearDown(() async {
      await tester.runAsync(engine.dispose);
    });
    expect(engine.tree.value, isNotNull);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<Map<String, dynamic>?>(
            valueListenable: engine.tree,
            builder: (context, tree, _) {
              if (tree == null) return const SizedBox.shrink();
              final renderer = JsonWidgetRenderer(
                theme: JsonWidgetTheme.fromAccent(
                  Theme.of(context).colorScheme.primary,
                ),
                onEvent: (actionId, payload) {
                  engine.callEvent(actionId, payload);
                },
              );
              return renderer.build(tree, context);
            },
          ),
        ),
      ),
    );

    expect(find.text('7'), findsOneWidget);
    await tester.tap(find.text('7'));

    // The tap fires through a microtask + async JS evaluation: let it land.
    var expression = '';
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      final state = engine.exportedState;
      if (state != null) {
        expression = '${state['expression']}';
        if (expression.isNotEmpty) break;
      }
      await tester.pump();
    }
    expect(expression, '7');
  });
}
