// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

const _manifest = '''
{
  "id": "demo",
  "name": "Demo App",
  "description": "A demo",
  "icon": "🧪",
  "network": true,
  "llm": true,
  "allowedCommands": ["echo"]
}
''';

Future<String> _fakeAssets(String path) async {
  if (path.endsWith('manifest.json')) return _manifest;
  return '(function(){ jsr.render({type:"text",data:"hi"}); })();';
}

void main() {
  group('AppsStore', () {
    test('seeds bundled apps once and lists them', () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env, readAsset: _fakeAssets);

      await store.seedBundledApps(['demo']);
      var apps = await store.listApps();
      expect(apps, hasLength(1));
      expect(apps.single.id, 'demo');
      expect(apps.single.name, 'Demo App');
      expect(apps.single.icon, '🧪');
      expect(apps.single.declaredPermissions.network, isTrue);
      expect(apps.single.declaredPermissions.llm, isTrue);
      expect(apps.single.declaredPermissions.allowedCommands, contains('echo'));

      // Seeding again must not overwrite local modifications.
      await env.writeFile(
        'apps/demo/manifest.json',
        _manifest.replaceAll('Demo App', 'Edited App'),
      );
      await store.seedBundledApps(['demo']);
      apps = await store.listApps();
      expect(apps.single.name, 'Edited App');
    });

    test('skips malformed app folders', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/broken/manifest.json', '{not json');
      final apps = await AppsStore(env, readAsset: _fakeAssets).listApps();
      expect(apps, isEmpty);
    });

    test('readWidgetSource returns the JS source', () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env, readAsset: _fakeAssets);
      await store.seedBundledApps(['demo']);
      final source = await store.readWidgetSource(
        (await store.listApps()).single,
      );
      expect(source, contains('jsr.render'));
    });
  });

  group('AppPermissionsStore', () {
    test('declared permissions apply without overrides', () async {
      final env = MemoryExecutionEnv();
      final store = await AppPermissionsStore.load(env);
      final app = JsAppInfo.fromManifest(
        const {'id': 'demo', 'name': 'Demo', 'network': true},
        bundled: false,
        fallbackId: 'demo',
      );
      final effective = store.forApp(app);
      expect(effective.network, isTrue);
      expect(effective.llm, isFalse);
      expect(effective.homekit, isFalse);
    });

    test('overrides persist across reloads', () async {
      final env = MemoryExecutionEnv();
      final app = JsAppInfo.fromManifest(
        const {'id': 'demo', 'name': 'Demo'},
        bundled: false,
        fallbackId: 'demo',
      );

      final store = await AppPermissionsStore.load(env);
      await store.setOverride(
        'demo',
        const AppPermissions(network: true, contacts: true),
      );

      final reloaded = await AppPermissionsStore.load(env);
      final effective = reloaded.forApp(app);
      expect(effective.network, isTrue);
      expect(effective.contacts, isTrue);
      expect(effective.llm, isFalse);
    });

    test('clearOverride falls back to the manifest', () async {
      final env = MemoryExecutionEnv();
      final app = JsAppInfo.fromManifest(
        const {'id': 'demo', 'name': 'Demo', 'llm': true},
        bundled: false,
        fallbackId: 'demo',
      );
      final store = await AppPermissionsStore.load(env);
      await store.setOverride('demo', const AppPermissions());
      expect(store.forApp(app).llm, isFalse);
      await store.clearOverride('demo');
      expect(store.forApp(app).llm, isTrue);
    });
  });
}
