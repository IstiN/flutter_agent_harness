// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Integration tests for the unpacked-widget loader (gh-1616 IT-*): pick
// (a files map, as the folder picker hands over) → validate → store into
// the env's `apps/<id>/` → boot → restart. Everything runs over a web-
// shaped `MemoryExecutionEnv` — the same shape the extension's OPFS-backed
// env replays after a restart.

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/apps/unpacked_loader.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Uint8List> folder({
  String id = 'fa-agents',
  String name = 'FA Agents',
  Map<String, Object?> extra = const {},
  String root = '',
}) {
  final manifest = jsonEncode({
    'id': id,
    'name': name,
    'version': '0.3.0',
    ...extra,
  });
  return {
    if (root.isNotEmpty) '$root/manifest.json': utf8.encode(manifest),
    if (root.isNotEmpty) '$root/widget.js': utf8.encode('jsr.render(null);'),
    if (root.isEmpty) 'manifest.json': utf8.encode(manifest),
    if (root.isEmpty) 'widget.js': utf8.encode('jsr.render(null);'),
  };
}

Map<String, Map<String, String>> castMeta(Object? decoded) => {
  for (final entry in (decoded! as Map).entries)
    entry.key as String: {
      for (final field in (entry.value as Map).entries)
        field.key as String: field.value.toString(),
    },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(
    'UnpackedWidgetLoader — load → store (I1: catalog-identical shape)',
    () {
      test(
        'install writes apps/<id>/ and records the unpacked origin',
        () async {
          final env = MemoryExecutionEnv();
          final loader = UnpackedWidgetLoader(env: env);
          final inspection = await loader.inspect(folder());
          expect(inspection.isValid, isTrue, reason: '${inspection.errors}');
          expect(inspection.id, 'fa-agents');
          expect(inspection.name, 'FA Agents');
          expect(inspection.version, '0.3.0');

          await loader.install(inspection);

          expect(
            (await env.readTextFile(
              'apps/fa-agents/manifest.json',
            )).valueOrNull,
            isNotNull,
          );
          expect(
            (await env.readTextFile('apps/fa-agents/widget.js')).valueOrNull,
            'jsr.render(null);',
          );
          final meta = castMeta(
            jsonDecode(
              (await env.readTextFile(
                AppsStore.installedMetaFile,
              )).getOrThrow(),
            ),
          );
          expect(meta['fa-agents']?['origin'], 'unpacked');
          expect(meta['fa-agents']?['version'], '0.3.0');
          expect(meta['fa-agents']?['installedAt'], isNotNull);
        },
      );

      test(
        'a whitespace-padded manifest id installs under the trimmed id',
        () async {
          // The id rule runs against `id.trim()` (and WidgetManifest
          // itself trims), so the folder the widget lands in and the
          // `.installed.json` key must carry the trimmed, rule-enforced
          // form — never a padded `apps/ fa-agents /` (gh-1616 review).
          final env = MemoryExecutionEnv();
          final loader = UnpackedWidgetLoader(env: env);
          final inspection = await loader.inspect(folder(id: ' fa-agents '));
          expect(inspection.isValid, isTrue, reason: '${inspection.errors}');
          expect(inspection.id, 'fa-agents');

          await loader.install(inspection);

          final listed = [
            for (final e
                in (await env.listDir('apps')).valueOrNull ??
                    const <FileInfo>[])
              e.name,
          ];
          expect(listed, containsAll(['.installed.json', 'fa-agents']));
          expect(
            listed,
            everyElement(isNot(contains(' '))),
            reason: 'no space-padded sibling folder may be created',
          );
          expect(
            (await env.readTextFile(
              'apps/fa-agents/manifest.json',
            )).valueOrNull,
            isNotNull,
          );
          final meta = castMeta(
            jsonDecode(
              (await env.readTextFile(
                AppsStore.installedMetaFile,
              )).getOrThrow(),
            ),
          );
          expect(meta.keys, contains('fa-agents'));
          expect(meta.keys, isNot(contains(' fa-agents ')));
        },
      );

      test('multi-file folders land nested under apps/<id>/', () async {
        final env = MemoryExecutionEnv();
        final loader = UnpackedWidgetLoader(env: env);
        final files = {
          'my-app/manifest.json': utf8.encode(
            jsonEncode({'id': 'my-app', 'name': 'My App'}),
          ),
          'my-app/widget.js': utf8.encode("import './lib/game.js';"),
          'my-app/lib/game.js': utf8.encode('export const start = () => {};;'),
        };
        final multi = await loader.inspect(files);
        expect(multi.isValid, isTrue, reason: '${multi.errors}');
        await loader.install(multi);
        expect(
          (await env.readTextFile('apps/my-app/lib/game.js')).valueOrNull,
          'export const start = () => {};;',
        );
      });

      test(
        'reinstall keeps storage.json (user data is never clobbered)',
        () async {
          final env = MemoryExecutionEnv();
          final loader = UnpackedWidgetLoader(env: env);
          final inspection = await loader.inspect(folder());
          await loader.install(inspection);
          await env.writeFile('apps/fa-agents/storage.json', '{"kept":true}');

          final v2 = await loader.inspect(folder(name: 'FA Agents v2'));
          await loader.install(v2);

          expect(
            (await env.readTextFile('apps/fa-agents/storage.json')).valueOrNull,
            '{"kept":true}',
          );
          expect(
            (await env.readTextFile(
              'apps/fa-agents/manifest.json',
            )).valueOrNull,
            contains('FA Agents v2'),
          );
        },
      );
    },
  );

  group('UnpackedWidgetLoader — boot + restart (AC1, AC3)', () {
    test(
      'a freshly installed unpacked widget boots through jsr.render',
      () async {
        final env = MemoryExecutionEnv();
        final loader = UnpackedWidgetLoader(env: env);
        await loader.install(await loader.inspect(folder()));

        final store = AppsStore(env, readAsset: (_) async => '');
        final apps = await store.listApps();
        expect(apps.map((a) => a.id), contains('fa-agents'));
        final app = apps.singleWhere((a) => a.id == 'fa-agents');

        // The same boot path a catalog widget takes (I1 — zero special
        // cases): assemble the entry JS the engine will run.
        final js = await JsAppEngine.assembleEntryJsForTest(
          env: env,
          dir: app.dir,
          entryFile: JsAppEngine.defaultEntryFile,
        );
        expect(js, contains('jsr.render'));
      },
    );

    test(
      'restart (re-opened env + store) rediscovers the widget and boots',
      () async {
        final env = MemoryExecutionEnv();
        final loader = UnpackedWidgetLoader(env: env);
        await loader.install(await loader.inspect(folder()));

        // "Restart": fresh store objects over the same persisted env — the
        // extension's OPFS snapshot replays into exactly this shape.
        final store = AppsStore(env, readAsset: (_) async => '');
        final apps = await store.listApps();
        final app = apps.singleWhere((a) => a.id == 'fa-agents');
        expect(app.installSource, 'unpacked');

        final js = await JsAppEngine.assembleEntryJsForTest(
          env: env,
          dir: app.dir,
          entryFile: JsAppEngine.defaultEntryFile,
        );
        expect(js, isNotEmpty);
      },
    );

    test(
      'manifest refreshSeconds survives the store into the tile model',
      () async {
        final env = MemoryExecutionEnv();
        final loader = UnpackedWidgetLoader(env: env);
        await loader.install(
          await loader.inspect({
            'manifest.json': utf8.encode(
              jsonEncode({
                'id': 'fa-agents',
                'name': 'FA Agents',
                'widget': {'entry': 'widget_tile.js', 'refreshSeconds': 15},
              }),
            ),
            'widget.js': utf8.encode('jsr.render(null);'),
            'widget_tile.js': utf8.encode('tile.refresh();'),
          }),
        );

        final store = AppsStore(env, readAsset: (_) async => '');
        final app = (await store.listApps()).singleWhere(
          (a) => a.id == 'fa-agents',
        );
        // The tile host drives the AC1 update-on-schedule from this value.
        expect(app.tileWidget?.refreshSeconds, 15);
      },
    );
  });

  group('UnpackedWidgetLoader — provenance + coexistence (I3, AC4, E3)', () {
    test(
      'catalog and unpacked apps coexist, each with its own source',
      () async {
        final env = MemoryExecutionEnv();
        final store = AppsStore(env, readAsset: (_) async => '');
        await store.installWidget(
          id: 'from-catalog',
          version: '1.0.0',
          files: {
            'manifest.json': utf8.encode(
              jsonEncode({'id': 'from-catalog', 'name': 'Cat'}),
            ),
            'widget.js': utf8.encode('a'),
          },
        );
        final loader = UnpackedWidgetLoader(env: env, appsStore: store);
        await loader.install(
          await loader.inspect(folder(id: 'from-folder', name: 'Unp')),
        );

        final apps = await store.listApps();
        final sources = {for (final app in apps) app.id: app.installSource};
        expect(sources['from-catalog'], 'catalog');
        expect(sources['from-folder'], 'unpacked');
        expect(await store.isCatalogInstalled('from-catalog'), isTrue);
        // An unpacked widget is NOT a catalog install: the publish gate and
        // the catalog auto-update treat it as user-owned local code.
        expect(await store.isCatalogInstalled('from-folder'), isFalse);
      },
    );

    test('replacing a catalog install flips the origin to unpacked', () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env, readAsset: (_) async => '');
      await store.installWidget(
        id: 'fa-agents',
        version: '2.0.0',
        files: {
          'manifest.json': utf8.encode(
            jsonEncode({'id': 'fa-agents', 'name': 'Cat'}),
          ),
          'widget.js': utf8.encode('catalog'),
        },
      );
      final loader = UnpackedWidgetLoader(env: env, appsStore: store);
      await loader.install(await loader.inspect(folder()));

      expect(
        (await env.readTextFile('apps/fa-agents/widget.js')).valueOrNull,
        'jsr.render(null);',
      );
      final meta = castMeta(
        jsonDecode(
          (await env.readTextFile(AppsStore.installedMetaFile)).getOrThrow(),
        ),
      );
      expect(meta['fa-agents']?['origin'], 'unpacked');
      expect(await store.isCatalogInstalled('fa-agents'), isFalse);
      final app = (await store.listApps()).singleWhere(
        (a) => a.id == 'fa-agents',
      );
      expect(app.installSource, 'unpacked');
    });
  });

  group('UnpackedWidgetLoader — invalid payloads never write (AC2, E1)', () {
    test(
      'an invalid payload surfaces named issues and installs nothing',
      () async {
        final env = MemoryExecutionEnv();
        final loader = UnpackedWidgetLoader(env: env);
        final inspection = await loader.inspect({
          'manifest.json': utf8.encode(jsonEncode({'id': 'BAD ID'})),
          'widget.js': utf8.encode('x'),
        });
        expect(inspection.isValid, isFalse);
        expect(inspection.errors.map((e) => e.code), contains('id_invalid'));

        // Nothing was written: no app folder, no meta record.
        expect((await env.listDir('apps')).valueOrNull ?? [], isEmpty);
        expect(
          (await env.readTextFile(AppsStore.installedMetaFile)).valueOrNull,
          isNull,
        );
        expect(() => loader.install(inspection), throwsStateError);
      },
    );

    test(
      'E1: an empty pick (folder vanished before the read) is honest',
      () async {
        final env = MemoryExecutionEnv();
        final loader = UnpackedWidgetLoader(env: env);
        final inspection = await loader.inspect(const {});
        expect(inspection.isValid, isFalse);
        expect(
          inspection.errors.map((e) => e.code),
          contains('manifest_missing'),
        );
      },
    );

    test(
      'a folder whose manifest is not at the root names the looked paths',
      () async {
        final loader = UnpackedWidgetLoader(env: MemoryExecutionEnv());
        final inspection = await loader.inspect({
          'picked-widget/inner/manifest.json': utf8.encode(
            jsonEncode({'id': 'deep', 'name': 'X'}),
          ),
          'picked-widget/inner/widget.js': utf8.encode('x'),
        });
        expect(
          inspection.errors.map((e) => e.code),
          contains('manifest_missing'),
        );
        expect(
          inspection.errors.map((e) => e.message).join('\n'),
          contains('inner/manifest.json'),
          reason: 'the error names the path that was actually looked at',
        );
      },
    );
  });
}
