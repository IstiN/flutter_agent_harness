// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Smoke test for the bundled 3D game demo: boots `widget.js` in the real
/// engine (js3dHost wired by [JsAppEngine.start]) and lets the rAF game
/// loop run — proves the `jsr.scene3d.*` bridge commands flow into the
/// runtime's dispatcher host without crashing, blocks spawn, and the HUD
/// state exports.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('3d-game boots, runs the loop, spawns blocks', (tester) async {
    final env = MemoryExecutionEnv();
    await tester.runAsync(() async {
      await env.writeFile(
        'apps/3d-game/widget.js',
        await File('assets/apps/3d-game/widget.js').readAsString(),
      );
    });
    final engine = JsAppEngine(
      app: JsAppInfo.fromManifest(
        const {'id': '3d-game', 'name': '3D Game'},
        bundled: true,
        fallbackId: '3d-game',
      ),
      env: env,
      permissions: const AppPermissions(),
    );
    try {
      await tester.runAsync(() async {
        await engine.start();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      // The game loop rides a Flutter Ticker (rAF) — it only ticks when
      // the binding pumps frames, so drive ~1.5 s of game time in 100 ms
      // frames (the game clamps dt to 0.1 s per frame).
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final exported = engine.exportedState;
      expect(exported, isNotNull);
      expect(exported!['running'], isTrue);
      expect(exported['lives'], 3);
      expect(exported['score'], greaterThan(0));
      expect(exported['blockCount'], greaterThanOrEqualTo(1));

      // Steering clamps into the field instead of crashing; the render
      // tree carries the scene3d node and the HUD.
      await tester.runAsync(() async {
        await engine.callEvent('steer', {'dx': 5000.0, 'dy': 0.0});
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 100));
      expect(engine.exportedState!['running'], isTrue);
      expect(engine.tree.value, isNotNull);
    } finally {
      await tester.runAsync(engine.dispose);
    }
  });
}
