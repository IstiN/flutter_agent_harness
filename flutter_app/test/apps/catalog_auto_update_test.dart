// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/catalog_auto_update.dart';
import 'package:fa/apps/catalog_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Uint8List _zipOf(String id, String version, Map<String, String> files) {
  final archive = Archive();
  final data = {
    '$id/manifest.json': utf8.encode(
      jsonEncode({'id': id, 'name': id, 'version': version}),
    ),
    for (final file in files.entries)
      '$id/${file.key}': utf8.encode(file.value),
  };
  for (final name in data.keys.toList()..sort()) {
    final bytes = data[name]!;
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Serves a catalog with one widget at [version] plus its zip; counts zip
/// downloads in [zipHits] when given.
http.Client _serverFor(
  String id,
  String version,
  Map<String, String> files, {
  List<String>? zipHits,
}) {
  return MockClient((req) async {
    final name = req.url.pathSegments.last;
    if (name == 'catalog.json') {
      return http.Response(
        jsonEncode({
          'widgets': [
            {
              'id': id,
              'name': id,
              'version': version,
              'description': 'test widget',
              'tags': ['demo'],
              'permissions': {'network': false, 'allowedCommands': []},
              'minRuntime': '0.4.0',
              'zip': {'file': '$id-$version.zip'},
            },
          ],
        }),
        200,
      );
    }
    if (name == '$id-$version.zip') {
      zipHits?.add(name);
      return http.Response.bytes(_zipOf(id, version, files), 200);
    }
    return http.Response('nf', 404);
  });
}

CatalogService _catalog(MemoryExecutionEnv env, http.Client client) =>
    CatalogService(
      env,
      httpClient: client,
      baseUrl: Uri.parse('https://example.com'),
    );

void main() {
  group('autoUpdateCleanWidgets', () {
    test('updates a clean installed widget, keeping user data', () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env);
      await store.installWidget(
        id: 'pomodoro',
        version: '1.0.0',
        files: {
          'manifest.json': utf8.encode(
            jsonEncode({'id': 'pomodoro', 'version': '1.0.0'}),
          ),
          'widget.js': utf8.encode('// old'),
        },
      );
      await env.writeFile('apps/pomodoro/storage.json', '{"cycles":3}');

      final updated = await autoUpdateCleanWidgets(
        store: store,
        catalog: _catalog(
          env,
          _serverFor('pomodoro', '1.0.1', {'widget.js': '// new'}),
        ),
      );

      expect(updated, ['pomodoro']);
      final source = await env.readTextFile('apps/pomodoro/widget.js');
      expect(source.valueOrNull, '// new');
      // User data survives updates.
      final storage = await env.readTextFile('apps/pomodoro/storage.json');
      expect(storage.valueOrNull, '{"cycles":3}');
      expect(await store.installedCatalogVersions(), {'pomodoro': '1.0.1'});
    });

    test('skips a widget whose files the user modified', () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env);
      await store.installWidget(
        id: 'pomodoro',
        version: '1.0.0',
        files: {
          'manifest.json': utf8.encode(
            jsonEncode({'id': 'pomodoro', 'version': '1.0.0'}),
          ),
          'widget.js': utf8.encode('// old'),
        },
      );
      // The user (or the agent) owns widget.js now.
      await env.writeFile('apps/pomodoro/widget.js', '// mine');

      final zipHits = <String>[];
      final updated = await autoUpdateCleanWidgets(
        store: store,
        catalog: _catalog(
          env,
          _serverFor('pomodoro', '1.0.1', {
            'widget.js': '// new',
          }, zipHits: zipHits),
        ),
      );

      expect(updated, isEmpty);
      expect(zipHits, isEmpty, reason: 'never downloads a skipped widget');
      final source = await env.readTextFile('apps/pomodoro/widget.js');
      expect(source.valueOrNull, '// mine');
      expect(await store.installedCatalogVersions(), {'pomodoro': '1.0.0'});
    });

    test('leaves a current widget untouched (no download)', () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env);
      await store.installWidget(
        id: 'pomodoro',
        version: '1.0.1',
        files: {
          'manifest.json': utf8.encode(
            jsonEncode({'id': 'pomodoro', 'version': '1.0.1'}),
          ),
          'widget.js': utf8.encode('// new'),
        },
      );

      final zipHits = <String>[];
      final updated = await autoUpdateCleanWidgets(
        store: store,
        catalog: _catalog(
          env,
          _serverFor('pomodoro', '1.0.1', {
            'widget.js': '// new',
          }, zipHits: zipHits),
        ),
      );

      expect(updated, isEmpty);
      expect(zipHits, isEmpty);
    });

    test(
      'heals a broken install (empty dir, untracked) from the catalog',
      () async {
        final env = MemoryExecutionEnv();
        final store = AppsStore(env);
        // The residue of a failed install: the dir exists but is empty and
        // .installed.json knows nothing — the board renders a dead tile.
        await env.createDir('apps/pomodoro');

        final updated = await autoUpdateCleanWidgets(
          store: store,
          catalog: _catalog(
            env,
            _serverFor('pomodoro', '1.0.1', {'widget.js': '// healed'}),
          ),
        );

        expect(updated, ['pomodoro']);
        final source = await env.readTextFile('apps/pomodoro/widget.js');
        expect(source.valueOrNull, '// healed');
        expect(await store.installedCatalogVersions(), {'pomodoro': '1.0.1'});
      },
    );

    test('never resurrects a removed widget (storage.json leftover)', () async {
      final env = MemoryExecutionEnv();
      final store = AppsStore(env);
      // Remove keeps the user's storage.json — that dir must NOT be
      // mistaken for a broken install and reinstalled.
      await env.writeFile('apps/pomodoro/storage.json', '{"cycles":3}');

      final zipHits = <String>[];
      final updated = await autoUpdateCleanWidgets(
        store: store,
        catalog: _catalog(
          env,
          _serverFor('pomodoro', '1.0.1', {
            'widget.js': '// healed',
          }, zipHits: zipHits),
        ),
      );

      expect(updated, isEmpty);
      expect(zipHits, isEmpty);
      expect(await store.installedCatalogVersions(), isEmpty);
      final files = await env.listDir('apps/pomodoro');
      expect(files.valueOrNull?.length, 1, reason: 'storage.json only');
    });
  });
}
