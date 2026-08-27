import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/catalog_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List widgetZip(String id) {
  final archive = Archive();
  final data = {
    '$id/manifest.json': utf8.encode('{"id":"$id","name":"$id"}'),
    '$id/widget.js': utf8.encode('(function(){$id();})();'),
    '$id/icon.svg': utf8.encode('<svg>$id</svg>'),
  };
  for (final name in data.keys.toList()..sort()) {
    final bytes = data[name]!;
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Future<Map<String, Map<String, String>>> readMeta(ExecutionEnv env) async {
  final text = (await env.readTextFile(
    AppsStore.installedMetaFile,
  )).valueOrNull;
  if (text == null) return {};
  final decoded = jsonDecode(text);
  return {
    for (final entry in (decoded as Map).entries)
      entry.key as String: {
        for (final field in (entry.value as Map).entries)
          field.key as String: field.value.toString(),
      },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppsStore.installWidget', () {
    test('writes archive files under apps/<id>/ and records origin', () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env, readAsset: (_) async => '');
      await store.installWidget(
        id: 'focus-timer',
        version: '1.0.0',
        files: {
          'manifest.json': utf8.encode('{"id":"focus-timer"}'),
          'widget.js': utf8.encode('alert(1)'),
        },
      );
      expect(
        (await env.readTextFile('apps/focus-timer/widget.js')).valueOrNull,
        'alert(1)',
      );
      final meta = await readMeta(env);
      expect(meta['focus-timer']?['origin'], 'catalog');
      expect(meta['focus-timer']?['version'], '1.0.0');
    });

    test('a re-install of user-modified files skips only those', () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env, readAsset: (_) async => '');
      final v1 = utf8.encode('v1');
      await store.installWidget(
        id: 'demo',
        version: '1.0.0',
        files: {'widget.js': v1},
      );

      // The agent/user rewrites widget.js outside our hashes.
      await env.writeFile('apps/demo/widget.js', 'hacked');

      await store.installWidget(
        id: 'demo',
        version: '1.1.0',
        files: {'widget.js': utf8.encode('v2')},
      );

      expect(
        (await env.readTextFile('apps/demo/widget.js')).valueOrNull,
        'hacked',
        reason: 'user-owned code never clobbered by an update',
      );
      final meta = await readMeta(env);
      expect(meta['demo']?['version'], '1.1.0');
    });

    test('storage.json survives installs and force=false default', () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env, readAsset: (_) async => '');
      await env.writeFile('apps/demo/storage.json', '{"score":42}');
      await store.installWidget(
        id: 'demo',
        version: '1.0.0',
        files: {
          'widget.js': utf8.encode('x'),
          'storage.json': utf8.encode('{}'),
        },
      );
      expect(
        (await env.readTextFile('apps/demo/storage.json')).valueOrNull,
        '{"score":42}',
        reason: 'user data is not catalog content',
      );
    });
  });

  group('AppsStore.removeWidget', () {
    test('removes app code, keeps storage.json, updates meta', () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env, readAsset: (_) async => '');
      await store.installWidget(
        id: 'demo',
        version: '1.0.0',
        files: {'widget.js': utf8.encode('x')},
      );
      await env.writeFile('apps/demo/storage.json', '{}');

      final removed = await store.removeWidget('demo');

      expect(removed, isTrue);
      expect((await env.exists('apps/demo/widget.js')).valueOrNull, isFalse);
      expect(
        (await env.exists('apps/demo/storage.json')).valueOrNull,
        isTrue,
        reason: 'user data is kept on removal',
      );
      expect((await readMeta(env)).containsKey('demo'), isFalse);
      expect(await store.removeWidget('nope'), isFalse);
    });
  });

  group('availableUpdates', () {
    test('bumps detected semver-wise; downgrades ignored', () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env, readAsset: (_) async => '');
      await store.installWidget(
        id: 'alpha',
        version: '1.2.0',
        files: {
          'manifest.json': utf8.encode('{"id":"alpha"}'),
          'widget.js': utf8.encode('a'),
        },
      );

      final updates = await store.availableUpdates([
        _entry('alpha', '1.3.0'), // bump → candidate
        _entry('beta', '5.0.0'), // not installed → no dir, skip
      ]);

      expect(updates.map((u) => u.entry.id), ['alpha']);
      expect(updates.single.installedVersion, '1.2.0');
      expect(await store.availableUpdates([_entry('alpha', '1.1.9')]), isEmpty);
      expect(await store.availableUpdates([_entry('gone', '2.0.0')]), isEmpty);
    });
  });

  group('semverNewer', () {
    test('numeric part-wise comparison', () {
      expect(semverNewer('1.10.0', '1.9.9'), isTrue);
      expect(semverNewer('1.0.0', '1.0.0'), isFalse);
      expect(semverNewer('0.4.79', '0.4.80'), isFalse);
      expect(semverNewer('', '1.0.0'), isTrue, reason: 'absent = upgrade');
    });
  });
}

CatalogEntry _entry(String id, String version) => CatalogEntry(
  id: id,
  name: id,
  version: version,
  description: '',
  author: '',
  tags: const [],
  minRuntime: '0.4.79',
  iconFile: null,
  network: false,
  allowedCommands: const [],
  zipFile: '$id-$version.zip',
  zipSha256: '',
  zipSizeBytes: 0,
);
