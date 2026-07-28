// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
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

      // Demo files are refreshed when the bundled content changed —
      // identical files stay untouched, local edits are replaced by the
      // updated bundled version (demos are samples, not user data).
      await env.writeFile(
        'apps/demo/manifest.json',
        _manifest.replaceAll('Demo App', 'Edited App'),
      );
      await store.seedBundledApps(['demo']);
      apps = await store.listApps();
      expect(apps.single.name, 'Demo App');
    });

    test('seeds the svg icon file when the manifest references one', () async {
      final env = MemoryExecutionEnv();
      Future<String> assets(String path) async {
        if (path.endsWith('icon.svg')) return '<svg/>';
        return _fakeAssets(path);
      }

      const manifestWithSvg = '''
{
  "id": "demo",
  "name": "Demo App",
  "description": "A demo",
  "icon": "icon.svg"
}
''';
      final store = AppsStore(
        env,
        readAsset: (path) async =>
            path.endsWith('manifest.json') ? manifestWithSvg : assets(path),
      );
      await store.seedBundledApps(['demo']);
      final svg = await env.readTextFile('apps/demo/icon.svg');
      expect(svg.valueOrNull, '<svg/>');
    });

    test(
      'seeds the tile entry file when the manifest declares a widget',
      () async {
        const manifestWithWidget = '''
{
  "id": "demo",
  "name": "Demo App",
  "description": "A demo",
  "icon": "🧪",
  "widget": { "entry": "widget_tile.js", "size": "1x1", "refreshSeconds": 900 }
}
''';
        final env = MemoryExecutionEnv();
        final store = AppsStore(
          env,
          readAsset: (path) async {
            if (path.endsWith('manifest.json')) return manifestWithWidget;
            if (path.endsWith('widget_tile.js')) return '(function(){})();';
            return _fakeAssets(path);
          },
        );
        await store.seedBundledApps(['demo']);
        final tile = await env.readTextFile('apps/demo/widget_tile.js');
        expect(tile.valueOrNull, '(function(){})();');

        // The tile declaration lands on the discovered app info.
        final app = (await store.listApps()).single;
        expect(app.tileWidget, isNotNull);
        expect(app.tileWidget!.entry, 'widget_tile.js');
        expect(app.tileWidget!.refreshSeconds, 900);
      },
    );

    test('a missing tile entry asset is skipped, not fatal', () async {
      const manifestWithWidget = '''
{
  "id": "demo",
  "name": "Demo App",
  "description": "A demo",
  "icon": "🧪",
  "widget": { "entry": "widget_tile.js" }
}
''';
      final env = MemoryExecutionEnv();
      final store = AppsStore(
        env,
        readAsset: (path) async {
          if (path.endsWith('manifest.json')) return manifestWithWidget;
          if (path.endsWith('widget_tile.js')) {
            throw StateError('asset not found');
          }
          return _fakeAssets(path);
        },
      );
      await store.seedBundledApps(['demo']);
      final apps = await store.listApps();
      expect(apps, hasLength(1));
      final tile = await env.readTextFile('apps/demo/widget_tile.js');
      expect(tile.valueOrNull, isNull);
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

  group('JsAppInfo', () {
    test('chrome flag parses with the header fallback', () {
      final full = JsAppInfo.fromManifest(
        const {'id': 'map', 'chrome': 'full'},
        bundled: false,
        fallbackId: 'map',
      );
      expect(full.chrome, JsAppInfo.chromeFull);
      expect(full.isFullChrome, isTrue);

      // Missing flag → default header chrome.
      final missing = JsAppInfo.fromManifest(
        const {'id': 'demo'},
        bundled: false,
        fallbackId: 'demo',
      );
      expect(missing.chrome, JsAppInfo.chromeHeader);
      expect(missing.isFullChrome, isFalse);

      // Unknown values fall back to the header chrome.
      final unknown = JsAppInfo.fromManifest(
        const {'id': 'demo', 'chrome': 'sidebar'},
        bundled: false,
        fallbackId: 'demo',
      );
      expect(unknown.chrome, JsAppInfo.chromeHeader);
    });

    test('no widget section → no tile widget', () {
      final app = JsAppInfo.fromManifest(
        const {'id': 'demo'},
        bundled: false,
        fallbackId: 'demo',
      );
      expect(app.tileWidget, isNull);
    });

    test('widget section parses with defaults', () {
      final app = JsAppInfo.fromManifest(
        const {'id': 'demo', 'widget': <String, Object?>{}},
        bundled: false,
        fallbackId: 'demo',
      );
      final tile = app.tileWidget!;
      expect(tile.entry, JsTileWidgetInfo.defaultEntry);
      expect(tile.widthCells, 1);
      expect(tile.heightCells, 1);
      expect(tile.size, '1x1');
      expect(tile.refreshSeconds, isNull);
      expect(app.tileWidgetPath, 'apps/demo/widget_tile.js');

      final full = JsAppInfo.fromManifest(
        const {
          'id': 'demo',
          'widget': {'entry': 'tile.js', 'size': '2x2', 'refreshSeconds': 900},
        },
        bundled: false,
        fallbackId: 'demo',
      );
      expect(full.tileWidget!.entry, 'tile.js');
      expect(full.tileWidget!.widthCells, 2);
      expect(full.tileWidget!.heightCells, 2);
      expect(full.tileWidget!.size, '2x2');
      expect(full.tileWidget!.refreshSeconds, 900);
      expect(full.tileWidgetPath, 'apps/demo/tile.js');
    });

    test('widget size clamps to the supported cell range', () {
      JsTileWidgetInfo tile(String size) => JsAppInfo.fromManifest(
        {
          'id': 'demo',
          'widget': {'size': size},
        },
        bundled: false,
        fallbackId: 'demo',
      ).tileWidget!;

      expect(tile('1x1').size, '1x1');
      expect(tile('2x1').size, '2x1');
      expect(tile('3x1').size, '3x1');
      expect(tile('3x2').size, '3x2');
      // W clamps to 3, H to 2.
      expect(tile('4x1').size, '3x1');
      expect(tile('1x5').size, '1x2');
      expect(tile('9x9').size, '3x2');
      expect(tile('0x0').size, '1x1');
    });

    test('weird widget values fall back to the defaults', () {
      final app = JsAppInfo.fromManifest(
        const {
          'id': 'demo',
          'widget': {'entry': '', 'size': 'big', 'refreshSeconds': 'later'},
        },
        bundled: false,
        fallbackId: 'demo',
      );
      final tile = app.tileWidget!;
      expect(tile.entry, JsTileWidgetInfo.defaultEntry);
      expect(tile.size, '1x1');
      expect(tile.refreshSeconds, isNull);

      // A non-map widget section is ignored entirely.
      final notAMap = JsAppInfo.fromManifest(
        const {'id': 'demo', 'widget': true},
        bundled: false,
        fallbackId: 'demo',
      );
      expect(notAMap.tileWidget, isNull);
    });
  });

  group('JsAppEngine entryFile', () {
    test('defaults to widget.js', () {
      final engine = JsAppEngine(
        app: JsAppInfo.fromManifest(
          const {'id': 'demo'},
          bundled: false,
          fallbackId: 'demo',
        ),
        env: MemoryExecutionEnv(),
        permissions: const AppPermissions(),
      );
      expect(engine.entryFile, JsAppEngine.defaultEntryFile);
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
