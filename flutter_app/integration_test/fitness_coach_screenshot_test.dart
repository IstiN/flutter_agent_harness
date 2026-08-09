// Screenshot verification for the Fitness Trainer 3D coach: boots the app
// through the real JsAppView on the macOS host (Impeller + Flutter GPU —
// the same flame_3d path as iOS), then captures the screen while the
// workout runs. Run with:
//   flutter test integration_test/fitness_coach_screenshot_test.dart -d macos
// PNGs land in build/fitness_coach/.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/sandbox/env_factory.dart';

import 'e2e_support/e2e_harness.dart';

final _boundaryKey = GlobalKey();

/// Rasterizes the whole app window through a RepaintBoundary — window-
/// manager independent (OS-level grabs kept landing on the wrong Space
/// and came back as wallpaper).
Future<void> _shot(String name) async {
  final dir = Directory('build/fitness_coach')..createSync(recursive: true);
  final boundary =
      _boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1.0);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fitness-trainer 3D coach renders and animates', (tester) async {
    await tester.runAsync(() async {
      final env = await createPlatformEnv();
      final store = AppsStore(env);
      await store.seedBundledApps();
      // The REAL sandbox may hold an older/agent-owned copy of the app
      // (ownership-aware seeding preserves it) — force the reference
      // version so the probe tests what ships, not what lingers.
      await store.resetDemoApp('fitness-trainer');
      final app = await expectApp(store, 'fitness-trainer');
      final permissions = await AppPermissionsStore.load(env);

      await tester.pumpWidget(
        RepaintBoundary(
          key: _boundaryKey,
          child: MaterialApp(
            home: JsAppView(app: app, env: env, permissionsStore: permissions),
          ),
        ),
      );
      // Let the GLB parse + first skeletal frames render (real time).
      await Future<void>.delayed(const Duration(seconds: 5));
      await tester.pump();
      await _shot('01_home_idle');

      expect(find.text('START WORKOUT'), findsOneWidget);
      await tester.tap(find.text('START WORKOUT'));
      await Future<void>.delayed(const Duration(seconds: 2));
      await _shot('02_jumping_jacks_a');
      await Future<void>.delayed(const Duration(seconds: 2));
      await _shot('03_jumping_jacks_b');

      // The countdown ticked and the exercise screen is up.
      expect(find.text('JUMPING JACKS'), findsOneWidget);

      // Skip into the rest step (Idle clip).
      await tester.tap(find.text('SKIP'));
      await Future<void>.delayed(const Duration(seconds: 2));
      await _shot('04_rest_idle');
      expect(find.text('REST'), findsOneWidget);

      // Orbit: drag the 3D view sideways, the camera must swing around
      // the coach (the pose silhouette changes visibly). dragFrom lands
      // inside the scene box regardless of detector ordering.
      final sceneCenter = tester.getCenter(find.text('REST'));
      await tester.dragFrom(
        sceneCenter.translate(0, -140),
        const Offset(-160, 0),
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      await _shot('05_orbit_left');
    });
    await unmountAll(tester);
  });
}
