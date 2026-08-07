// The device path end to end: seedBundledApps with the REAL rootBundle
// (what ships in the app — rootBundle in flutter_test resolves assets
// through pubspec exactly like the device bundle), then boot every demo
// app from the seeded env files, the way JsAppView does. bundled_demos_test
// copies only widget.js by hand, so it cannot catch seeding/asset/manifest
// regressions (fitness-trainer "does not open" on device, build 81).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryExecutionEnv env;
  late AppsStore store;

  setUp(() {
    env = MemoryExecutionEnv();
    // Default readAsset = rootBundle.loadString — the real bundle.
    store = AppsStore(env);
  });

  test('all demo ids seed from the real bundle without failures', () async {
    await store.seedBundledApps();
    expect(
      store.failedSeeds.value,
      isEmpty,
      reason: 'seed failures: ${store.failedSeeds.value}',
    );
    for (final id in AppsStore.demoAppIds) {
      for (final file in const ['manifest.json', 'widget.js']) {
        final result = await env.readTextFile('apps/$id/$file');
        expect(
          result.isOk,
          isTrue,
          reason: 'apps/$id/$file missing after seeding',
        );
      }
    }
  });

  for (final id in const ['fitness-trainer', 'english-teacher']) {
    testWidgets('$id boots from the seeded env files', (tester) async {
      await tester.runAsync(() async {
        await store.seedBundledApps();
        expect(store.failedSeeds.value, isEmpty);
        final manifestResult = await env.readTextFile('apps/$id/manifest.json');
        final manifest =
            jsonDecode(manifestResult.valueOrNull!) as Map<String, Object?>;
        final engine = JsAppEngine(
          app: JsAppInfo.fromManifest(manifest, bundled: true, fallbackId: id),
          env: env,
          permissions: const AppPermissions(),
        );
        try {
          await engine.start();
          await Future<void>.delayed(const Duration(seconds: 3));
          expect(
            engine.tree.value,
            isNotNull,
            reason: 'engine logs: ${engine.peekLogs()}',
          );
        } finally {
          await engine.dispose();
        }
      });
    });
  }
}
