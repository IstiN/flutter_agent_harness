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
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppsStore', () {
    test(
      'a demo id without assets does not kill the rest — it is flagged',
      () async {
        final env = MemoryExecutionEnv();
        Future<String> assets(String path) async {
          if (path.contains('ghost')) {
            throw StateError('Unable to load asset: "$path"');
          }
          return path.endsWith('manifest.json')
              ? _manifest
              : '(function(){ jsr.render({type:"text",data:"hi"}); })();';
        }

        final store = AppsStore(env, readAsset: assets);

        // 'ghost' has no bundled assets (the TestFlight 1.0.0 regression):
        // seeding must still complete and 'demo' must land.
        await store.seedBundledApps(['ghost', 'demo']);

        final apps = await store.listApps();
        expect(apps.map((a) => a.id), contains('demo'));
        expect(store.failedSeeds.value, contains('ghost'));
        expect(store.failedSeeds.value, isNot(contains('demo')));

        // A later successful seed clears the flag.
        final healed = AppsStore(env, readAsset: _fakeAssets);
        await healed.seedBundledApps(['ghost']);
        expect(healed.failedSeeds.value, isNot(contains('ghost')));
      },
    );

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

      // Seeding refreshes demos ONLY where nothing was customized: a
      // locally edited file (hash differs from the last-seeded one) is
      // user-owned now and is left alone.
      await env.writeFile(
        'apps/demo/manifest.json',
        _manifest.replaceAll('Demo App', 'Edited App'),
      );
      await store.seedBundledApps(['demo']);
      apps = await store.listApps();
      expect(apps.single.name, 'Edited App');

      // …while an untouched sibling file still refreshes when the BUNDLE
      // changes (the manifest stays user-owned and preserved).
      final storeV2 = AppsStore(
        env,
        readAsset: (path) async =>
            path.endsWith('widget.js') ? '// v2' : _fakeAssets(path),
      );
      await storeV2.seedBundledApps(['demo']);
      expect(
        (await env.readTextFile('apps/demo/widget.js')).valueOrNull,
        '// v2',
      );
      apps = await store.listApps();
      expect(apps.single.name, 'Edited App');
    });

    test(
      'a legacy (pre-hash) customized file is conservatively preserved',
      () async {
        final env = MemoryExecutionEnv();
        // A demo app folder exists from before hash tracking, with a local
        // edit — no recorded hash to prove ownership either way.
        await env.writeFile(
          'apps/demo/manifest.json',
          _manifest.replaceAll('Demo App', 'Legacy Edit'),
        );
        final store = AppsStore(env, readAsset: _fakeAssets);
        await store.seedBundledApps(['demo']);
        expect(
          (await env.readTextFile('apps/demo/manifest.json')).valueOrNull,
          contains('Legacy Edit'),
        );
      },
    );

    test('resetDemoApp force-restores a customized demo', () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(
        env,
        readAsset: _fakeAssets,
        seedDemoIds: const ['demo'],
      );
      await store.seedBundledApps(['demo']);
      await env.writeFile(
        'apps/demo/manifest.json',
        _manifest.replaceAll('Demo App', 'Edited App'),
      );
      expect(await store.resetDemoApp('demo'), isTrue);
      expect(
        (await env.readTextFile('apps/demo/manifest.json')).valueOrNull,
        contains('Demo App'),
      );
      // And after the reset, refreshes flow again (hash re-recorded).
      expect(await store.resetDemoApp('nope'), isFalse);
    });

    test(
      'a broken on-disk manifest is re-seeded despite ownership (dead tile)',
      () async {
        final env = MemoryExecutionEnv();
        final store = AppsStore(env, readAsset: _fakeAssets);
        await store.seedBundledApps(['demo']);

        // An agent half-writes the manifest (unparseable JSON). Ownership
        // must not protect a broken skeleton — otherwise listApps skips the
        // folder forever and the launcher tile turns into a dead
        // placeholder (fitness-trainer on TestFlight).
        await env.writeFile('apps/demo/manifest.json', '{"id": "demo", ');
        await store.seedBundledApps(['demo']);

        expect(
          (await env.readTextFile('apps/demo/manifest.json')).valueOrNull,
          contains('Demo App'),
        );
        final apps = await store.listApps();
        expect(apps.map((a) => a.id), contains('demo'));
      },
    );

    test('a VALID user-owned manifest is still preserved', () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env, readAsset: _fakeAssets);
      await store.seedBundledApps(['demo']);

      // Well-formed but customized: ownership applies (JSON parses).
      await env.writeFile(
        'apps/demo/manifest.json',
        _manifest.replaceAll('Demo App', 'Agent Edit'),
      );
      await store.seedBundledApps(['demo']);
      expect(
        (await env.readTextFile('apps/demo/manifest.json')).valueOrNull,
        contains('Agent Edit'),
      );
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

    test('filters apps by the injected host platform', () async {
      final env = MemoryExecutionEnv();
      const iosManifest = '''
{
  "id": "demo",
  "name": "Demo App",
  "platforms": ["ios"]
}
''';
      final store = AppsStore(
        env,
        platform: 'macos',
        readAsset: (path) async =>
            path.endsWith('manifest.json') ? iosManifest : '// widget',
      );
      await store.seedBundledApps(['demo']);

      expect(await store.listApps(), isEmpty);
    });
  });

  group('JsAppInfo', () {
    test('missing platforms enables every host', () {
      final app = JsAppInfo.fromManifest(
        const {'id': 'demo'},
        bundled: false,
        fallbackId: 'demo',
      );

      expect(app.platforms, isNull);
      expect(app.supportsPlatform('macos'), isTrue);
      expect(app.supportsPlatform('android'), isTrue);
    });

    test('platform allowlist is normalized and enforced', () {
      final app = JsAppInfo.fromManifest(
        const {
          'id': 'demo',
          'platforms': [' iOS ', 'MACOS'],
        },
        bundled: false,
        fallbackId: 'demo',
      );

      expect(app.platforms, {'ios', 'macos'});
      expect(app.supportsPlatform('macos'), isTrue);
      expect(app.supportsPlatform('linux'), isFalse);
    });

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
      expect(tile.widthCells, JsTileWidgetInfo.defaultWidthCells);
      expect(tile.heightCells, JsTileWidgetInfo.defaultHeightCells);
      expect(tile.size, '2x2');
      expect(tile.refreshSeconds, isNull);
      expect(app.tileWidgetPath, 'apps/demo/widget_tile.js');

      final full = JsAppInfo.fromManifest(
        const {
          'id': 'demo',
          'widget': {'entry': 'tile.js', 'size': '4x2', 'refreshSeconds': 900},
        },
        bundled: false,
        fallbackId: 'demo',
      );
      expect(full.tileWidget!.entry, 'tile.js');
      expect(full.tileWidget!.widthCells, 4);
      expect(full.tileWidget!.heightCells, 2);
      expect(full.tileWidget!.size, '4x2');
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

      expect(tile('2x2').size, '2x2'); // small
      expect(tile('4x2').size, '4x2'); // medium
      expect(tile('4x4').size, '4x4'); // large
      // W clamps to 2..4, H to 1..4.
      expect(tile('1x1').size, '2x1');
      expect(tile('5x2').size, '4x2');
      expect(tile('2x9').size, '2x4');
      expect(tile('9x9').size, '4x4');
      expect(tile('0x0').size, '2x1');
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
      expect(tile.size, '2x2');
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

    test('rejects an app disabled on the current host', () async {
      final engine = JsAppEngine(
        app: JsAppInfo.fromManifest(
          const {
            'id': 'demo',
            'platforms': ['not-a-flutter-platform'],
          },
          bundled: false,
          fallbackId: 'demo',
        ),
        env: MemoryExecutionEnv(),
        permissions: const AppPermissions(),
      );

      await expectLater(engine.start(), throwsA(isA<StateError>()));
    });
  });

  group('filterPlatformInstructions', () {
    test('filters blocks and tagged lines and expands the host', () {
      const source = '''
Host: {{FA_PLATFORM}}
<!-- fa-platforms: ios,macos -->
Apple bridge
<!-- /fa-platforms -->
<!-- fa-platforms: ios -->
iOS only
<!-- /fa-platforms -->
Always
macOS row <!-- fa-platforms: macos -->
iOS row <!-- fa-platforms: ios -->
''';

      final result = filterPlatformInstructions(source, platform: 'macos');

      expect(result, contains('Host: macos'));
      expect(result, contains('Apple bridge'));
      expect(result, contains('Always'));
      expect(result, contains('macOS row'));
      expect(result, isNot(contains('fa-platforms')));
      expect(result, isNot(contains('iOS only')));
      expect(result, isNot(contains('iOS row')));
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
