import 'dart:io';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pomodoro tile tree at tile size — find the overflow', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    late final JsAppEngine engine;
    Map<String, dynamic>? tree;
    await tester.runAsync(() async {
      final source = await File(
        '/Users/Uladzimir_Klyshevich/git/fa_widgets/vendor/'
        'js_widget_runtime/example/widgets/pomodoro/widget.js',
      ).readAsString();
      await env.writeFile('apps/pomodoro/widget.js', source);
      engine = JsAppEngine(
        app: JsAppInfo.fromManifest(
          const {
            'id': 'pomodoro',
            'name': 'Pomodoro',
            'widget': {
              'entry': 'widget.js',
              'size': '2x2',
              'refreshSeconds': 30,
              'interactive': true,
            },
          },
          bundled: false,
          fallbackId: 'pomodoro',
        ),
        env: env,
        permissions: const AppPermissions(),
      );
      await engine.start();
      for (var i = 0; i < 20 && engine.tree.value == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      tree = engine.tree.value;
    });
    addTearDown(() async {
      await tester.runAsync(engine.dispose);
    });
    expect(tree, isNotNull);

    // Tile-sized surface (large 4x4 tile on a ~770px-wide window).
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 690,
              height: 700,
              child: Builder(
                builder: (context) {
                  final renderer = JsonWidgetRenderer(
                    theme: JsonWidgetTheme.fromAccent(
                      Theme.of(context).colorScheme.primary,
                    ),
                    onEvent: (_, _) {},
                  );
                  return renderer.build(tree!, context);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final exception = tester.takeException();
    // ignore: avoid_print
    print('EXCEPTION: $exception');
  });
}
