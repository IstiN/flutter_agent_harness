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

/// End-to-end render check: boots the REAL calculator demo app
/// (assets/apps/calculator/widget.js) through the real JavaScriptCore
/// backend and renders the resulting UI tree into actual Flutter widgets
/// with the same JsonWidgetRenderer the JsAppView uses.
///
/// The engine is booted inside `tester.runAsync` (the JS backend needs the
/// real event loop); the renderer itself is synchronous.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('calculator demo app renders real widgets', (tester) async {
    final env = MemoryExecutionEnv();
    late final JsAppEngine engine;
    Map<String, dynamic>? tree;
    await tester.runAsync(() async {
      // Real async IO only progresses inside runAsync under flutter_test.
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
      // Give the bridge a moment to deliver the first render.
      for (var i = 0; i < 20 && engine.tree.value == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      tree = engine.tree.value;
    });
    addTearDown(() async {
      await tester.runAsync(engine.dispose);
    });

    expect(tree, isNotNull);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              final renderer = JsonWidgetRenderer(
                theme: JsonWidgetTheme.fromAccent(
                  Theme.of(context).colorScheme.primary,
                ),
                onEvent: (_, __) {},
              );
              return renderer.build(tree!, context);
            },
          ),
        ),
      ),
    );

    // The calculator keypad from widget.js: digits and the equals key.
    expect(find.text('7'), findsOneWidget);
    expect(find.text('='), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
  });
}
