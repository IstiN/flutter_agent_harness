// Dev probe (not for CI): does the fitness-trainer countdown tick?
import 'dart:convert';
import 'dart:io';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('countdown ticks in real time', (tester) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        'apps/fitness-trainer/widget.js',
        await File('assets/apps/fitness-trainer/widget.js').readAsString(),
      );
      final engine = JsAppEngine(
        app: JsAppInfo.fromManifest(
          const {'id': 'fitness-trainer', 'name': 'Fitness Trainer'},
          bundled: true,
          fallbackId: 'fitness-trainer',
        ),
        env: env,
        permissions: const AppPermissions(),
      );
      try {
        await engine.start();
        await Future<void>.delayed(const Duration(seconds: 1));
        await engine.callEvent('start');
        await Future<void>.delayed(const Duration(seconds: 3));
        final tree = jsonEncode(engine.tree.value);
        // After ~3s the 40s countdown must read 0:37/0:38, not 0:40.
        // ignore: avoid_print
        print(
          'COUNTDOWN TREE CHECK: ${RegExp(r'0:\d\d').allMatches(tree).map((m) => m.group(0)).toSet()}',
        );
        expect(tree.contains('0:40'), isFalse, reason: 'countdown frozen');
      } finally {
        await engine.dispose();
      }
    });
  });
}
