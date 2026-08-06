// LOCAL DEVICE-PATH REPRO for "fitness-trainer does not open" (build 81):
// the REAL platform sandbox env on the macOS host (same JavascriptCore
// engine as iOS), seedBundledApps into it, then the full JsAppView route
// exactly as pushJsApp builds it — intervals ticking on the real event
// loop. No LLM key needed.
//
// Run with: flutter test integration_test/fitness_trainer_probe_test.dart -d macos

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/sandbox/env_factory.dart';

import 'e2e_support/e2e_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fitness-trainer seeds into the real sandbox and opens', (
    tester,
  ) async {
    final env = await createPlatformEnv();
    final store = AppsStore(env);

    await tester.runAsync(() => store.seedBundledApps());
    expect(
      store.failedSeeds.value,
      isEmpty,
      reason: 'seed failures: ${store.failedSeeds.value}',
    );

    final app = await expectApp(store, 'fitness-trainer');

    await tester.pumpWidget(
      MaterialApp(
        home: JsAppView(
          app: app,
          env: env,
          permissionsStore: AppPermissionsStore(env, const {}),
        ),
      ),
    );
    // Real time, so the widget's setInterval loops tick and re-render.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(find.text("Today's workout"), findsOneWidget);
    expect(find.text('Goblet Squat'), findsWidgets);

    await unmountAll(tester);
  });
}
