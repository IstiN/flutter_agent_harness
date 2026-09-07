import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_catalog.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_manifest.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// Builds a zip from `{name: bytes}` (names preserved verbatim, hostile ones
/// included — the client under test must reject them).
Uint8List zipOf(Map<String, List<int>> files) {
  final archive = Archive();
  final names = files.keys.toList()..sort();
  for (final name in names) {
    final data = files[name]!;
    archive.addFile(ArchiveFile(name, data.length, data));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Fake release server: `catalog.json` plus flat zip assets.
http.Client fakeReleaseServer({
  Map<String, dynamic>? catalog,
  Map<String, List<int>>? assets,
  int catalogStatus = 200,
}) {
  return MockClient((request) async {
    final name = request.url.pathSegments.last;
    if (name == 'catalog.json') {
      if (catalogStatus != 200) return http.Response('boom', catalogStatus);
      return http.Response.bytes(_bytes(jsonEncode(catalog)), 200);
    }
    final asset = assets?[name];
    if (asset != null) return http.Response.bytes(asset, 200);
    return http.Response('not found', 404);
  });
}

Map<String, dynamic> entryJson(
  String id, {
  String? kind,
  String version = '1.0.0',
  String? zipFile,
  String sha = '',
  List<String>? platforms,
}) => {
  'id': id,
  'version': version,
  'zipFile': zipFile ?? '$id-$version.zip',
  'zipSha256': sha,
  'kind': ?kind,
  'platforms': ?platforms,
};

/// Builds `<id>/manifest.json`+`<id>/main.js` plus [extra] entries, and the
/// catalog entry SEALED to those exact zip bytes.
(ExtCatalogEntry, Uint8List) sealedEntry(
  String id, {
  Map<String, List<int>> extra = const {},
}) {
  final zip = zipOf({
    '$id/manifest.json': _bytes('{"name":"$id"}'),
    '$id/main.js': _bytes('export default 1;'),
    ...extra,
  });
  return (
    ExtCatalogEntry(
      id: id,
      version: '1.0.0',
      kind: ExtKind.widget,
      zipFile: '$id-1.0.0.zip',
      zipSha256: sha256.convert(zip).toString(),
      raw: const {},
    ),
    zip,
  );
}

void main() {
  group('parseExtCatalog', () {
    test(
      'v1 back-compat: no schemaVersion, widgets key, absent kind => widget',
      () {
        final catalog = parseExtCatalog({
          'widgets': [entryJson('a')],
        });
        expect(catalog.schemaVersion, 1);
        expect(catalog.entries, hasLength(1));
        expect(catalog.entries.single.id, 'a');
        expect(catalog.entries.single.kind, ExtKind.widget);
      },
    );

    test('v2: schemaVersion honored and extensions key parsed', () {
      final catalog = parseExtCatalog({
        'schemaVersion': 2,
        'extensions': [entryJson('b', kind: 'cli-extension')],
      });
      expect(catalog.schemaVersion, 2);
      expect(catalog.entries.single.kind, ExtKind.cliExtension);
    });

    test('widgets and extensions keys are UNIONED', () {
      final catalog = parseExtCatalog({
        'schemaVersion': 2,
        'widgets': [entryJson('a')],
        'extensions': [entryJson('b', kind: 'hybrid')],
      });
      expect(catalog.entries.map((e) => e.id), ['a', 'b']);
    });

    test('unknown kind skipped, missing id/version/zipFile skipped', () {
      final noVersion = entryJson('noversion')..remove('version');
      final catalog = parseExtCatalog({
        'widgets': [
          entryJson('good'),
          entryJson('weird', kind: 'sliders'),
          {'version': '1.0.0', 'zipFile': 'x.zip'}, // no id
          noVersion, // no version
          entryJson('nozip', zipFile: ''), // empty zipFile
          {'id': 7, 'version': '1', 'zipFile': 'x.zip'}, // non-string id
          'not-a-map',
        ],
      });
      expect(catalog.entries.map((e) => e.id), ['good']);
    });

    test('platform names parsed case-insensitively, unknown dropped', () {
      final catalog = parseExtCatalog({
        'extensions': [
          entryJson('a', platforms: ['CLI', 'Web', 'klingon']),
        ],
      });
      expect(catalog.entries.single.platforms, {
        ExtPlatformTag.cli,
        ExtPlatformTag.web,
      });
    });

    test('entries sorted by id regardless of file order', () {
      final catalog = parseExtCatalog({
        'widgets': [entryJson('zeta'), entryJson('alpha')],
      });
      expect(catalog.entries.map((e) => e.id), ['alpha', 'zeta']);
    });
  });

  group('fetchExtCatalog', () {
    test('fetches, parses, and writes a TTL cache through env', () async {
      final env = MemoryExecutionEnv();
      const cachePath = '/cache/catalog.json';
      final catalog = {
        'widgets': [entryJson('a')],
      };

      final cat = await fetchExtCatalog(
        kExtCatalogBaseUrl,
        fakeReleaseServer(catalog: catalog),
        cachePath: cachePath,
        env: env,
      );

      expect(cat.entries.single.id, 'a');
      final cached =
          jsonDecode((await env.readTextFile(cachePath)).getOrThrow())
              as Map<String, dynamic>;
      expect(cached['fetchedAt'], isNotNull);
      expect((cached['catalog'] as Map)['widgets'], isNotNull);
    });

    test('fresh cache is served without hitting the network', () async {
      final env = MemoryExecutionEnv();
      const cachePath = '/cache/catalog.json';
      await fetchExtCatalog(
        kExtCatalogBaseUrl,
        fakeReleaseServer(
          catalog: {
            'widgets': [entryJson('a')],
          },
        ),
        cachePath: cachePath,
        env: env,
      );

      var hits = 0;
      final deadClient = MockClient((request) async {
        hits++;
        throw StateError('network should not be touched');
      });

      final cat = await fetchExtCatalog(
        kExtCatalogBaseUrl,
        deadClient,
        cachePath: cachePath,
        env: env,
      );
      expect(hits, 0);
      expect(cat.entries.single.id, 'a');
    });

    test('force bypasses the freshness check', () async {
      final env = MemoryExecutionEnv();
      const cachePath = '/cache/catalog.json';
      await fetchExtCatalog(
        kExtCatalogBaseUrl,
        fakeReleaseServer(
          catalog: {
            'widgets': [entryJson('a')],
          },
        ),
        cachePath: cachePath,
        env: env,
      );

      var hits = 0;
      final counting = MockClient((request) async {
        hits++;
        return http.Response.bytes(
          _bytes(
            jsonEncode({
              'widgets': [entryJson('a')],
            }),
          ),
          200,
        );
      });
      await fetchExtCatalog(
        kExtCatalogBaseUrl,
        counting,
        force: true,
        cachePath: cachePath,
        env: env,
      );
      expect(hits, 1);
    });

    test('expired cache + server failure => stale-on-error', () async {
      final env = MemoryExecutionEnv();
      const cachePath = '/cache/catalog.json';
      await fetchExtCatalog(
        kExtCatalogBaseUrl,
        fakeReleaseServer(
          catalog: {
            'widgets': [entryJson('a')],
          },
        ),
        cachePath: cachePath,
        env: env,
      );
      final cached =
          jsonDecode((await env.readTextFile(cachePath)).getOrThrow())
              as Map<String, dynamic>;
      cached['fetchedAt'] = DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 7))
          .toIso8601String();
      await env.writeFile(cachePath, jsonEncode(cached));

      final cat = await fetchExtCatalog(
        kExtCatalogBaseUrl,
        fakeReleaseServer(catalogStatus: 500),
        cachePath: cachePath,
        env: env,
      );
      expect(cat.entries.single.id, 'a');
    });

    test('server failure without cache throws', () async {
      await expectLater(
        fetchExtCatalog(
          kExtCatalogBaseUrl,
          fakeReleaseServer(catalogStatus: 500),
        ),
        throwsA(isA<ExtCatalogException>()),
      );
    });

    test('invalid catalog json throws ExtCatalogException', () async {
      final client = MockClient(
        (request) async => http.Response.bytes(_bytes('[1,2]'), 200),
      );
      await expectLater(
        fetchExtCatalog(kExtCatalogBaseUrl, client),
        throwsA(isA<ExtCatalogException>()),
      );
    });

    test('happy path: sha verified, root stripped, binary skipped', () async {
      const id = 'crap-guard';
      final (entry, zip) = sealedEntry(
        id,
        extra: {
          '$id/icon.svg': _bytes('<svg/>'), // text — kept
          '$id/icon.bin': Uint8List.fromList([
            0,
            1,
            2,
            255,
          ]), // binary — skipped
        },
      );
      final client = fakeReleaseServer(assets: {'$id-1.0.0.zip': zip});
      final files = await downloadExtZip(
        baseUrl: kExtCatalogBaseUrl,
        entry: entry,
        client: client,
      );
      expect(files.keys, containsAll(['manifest.json', 'main.js', 'icon.svg']));
      expect(files.containsKey('icon.bin'), isFalse);
      expect(files['main.js'], 'export default 1;');
    });

    test('empty declared sha skips verification', () async {
      const id = 'g';
      final client = fakeReleaseServer(
        assets: {
          '$id-1.0.0.zip': zipOf({
            '$id/manifest.json': _bytes('{"name":"$id"}'),
            '$id/main.js': _bytes(''),
          }),
        },
      );
      final files = await downloadExtZip(
        baseUrl: kExtCatalogBaseUrl,
        entry: ExtCatalogEntry(
          id: id,
          version: '1.0.0',
          kind: ExtKind.widget,
          zipFile: '$id-1.0.0.zip',
          zipSha256: '',
          raw: const {},
        ),
        client: client,
      );
      expect(files.keys, containsAll(['manifest.json', 'main.js']));
    });

    test('tampered zip rejected with nothing written', () async {
      const id = 'g';
      final client = fakeReleaseServer(
        assets: {
          '$id-1.0.0.zip': zipOf({
            '$id/manifest.json': _bytes('{"name":"$id"}'),
            '$id/main.js': _bytes('export default 1;'),
          }),
        },
      );
      await expectLater(
        downloadExtZip(
          baseUrl: kExtCatalogBaseUrl,
          entry: ExtCatalogEntry(
            id: id,
            version: '1.0.0',
            kind: ExtKind.widget,
            zipFile: '$id-1.0.0.zip',
            zipSha256: '00' * 32,
            raw: const {},
          ),
          client: client,
        ),
        throwsA(
          isA<ExtCatalogException>().having(
            (e) => e.message,
            'message',
            contains('sha256 mismatch'),
          ),
        ),
      );
    });

    test('asset name with a slash rejected up front', () async {
      final client = fakeReleaseServer();
      await expectLater(
        downloadExtZip(
          baseUrl: kExtCatalogBaseUrl,
          entry: ExtCatalogEntry(
            id: 'g',
            version: '1.0.0',
            kind: ExtKind.widget,
            zipFile: 'sub/dir.zip',
            zipSha256: '',
            raw: const {},
          ),
          client: client,
        ),
        throwsA(
          isA<ExtCatalogException>().having(
            (e) => e.message,
            'message',
            contains('bad asset name'),
          ),
        ),
      );
    });

    test('HTTP failure surfaces as ExtCatalogException', () async {
      await expectLater(
        downloadExtZip(
          baseUrl: kExtCatalogBaseUrl,
          entry: sealedEntry('missing').$1,
          client: fakeReleaseServer(),
        ),
        throwsA(isA<ExtCatalogException>()),
      );
    });
  });

  group('extractExtensionZip hostile-zip rules', () {
    test('entry outside the required root rejected', () {
      final zip = zipOf({
        'g/manifest.json': _bytes('{"name":"g"}'),
        'g/main.js': _bytes(''),
        'loose.txt': _bytes('escape'),
      });
      expect(
        () => extractExtensionZip(zip, requiredRoot: 'g/', label: 'g'),
        throwsA(
          isA<ExtCatalogException>().having(
            (e) => e.message,
            'message',
            contains('outside the g/ root'),
          ),
        ),
      );
    });

    test('zip-slip via .. segment rejected', () {
      final zip = zipOf({
        'g/manifest.json': _bytes('{"name":"g"}'),
        'g/../evil.js': _bytes(''),
      });
      expect(
        () => extractExtensionZip(zip, requiredRoot: 'g/', label: 'g'),
        throwsA(
          isA<ExtCatalogException>().having(
            (e) => e.message,
            'message',
            contains('unsafe zip entry'),
          ),
        ),
      );
    });

    test('backslash traversal is normalized to .. and rejected', () {
      // ZipDecoder normalizes `\\` to `/`, so `g\\..\\evil.js` arrives as
      // `g/../evil.js` and must be caught by the `..` rule; a surviving
      // literal backslash would be caught by the explicit check.
      final zip = zipOf({
        'g/manifest.json': _bytes('{"name":"g"}'),
        'g\\..\\evil.js': _bytes(''),
      });
      expect(
        () => extractExtensionZip(zip, requiredRoot: 'g/', label: 'g'),
        throwsA(
          isA<ExtCatalogException>().having(
            (e) => e.message,
            'message',
            contains('unsafe zip entry'),
          ),
        ),
      );
    });

    test('absolute entry rejected', () {
      final zip = zipOf({
        'g/manifest.json': _bytes('{"name":"g"}'),
        '/abs.js': _bytes(''),
      });
      expect(
        () => extractExtensionZip(zip, requiredRoot: 'g/', label: 'g'),
        throwsA(
          isA<ExtCatalogException>().having(
            (e) => e.message,
            'message',
            contains('unsafe zip entry'),
          ),
        ),
      );
    });

    test('archive without main.js rejected', () {
      final zip = zipOf({'g/manifest.json': _bytes('{"name":"g"}')});
      expect(
        () => extractExtensionZip(zip, requiredRoot: 'g/', label: 'g'),
        throwsA(
          isA<ExtCatalogException>().having(
            (e) => e.message,
            'message',
            contains('misses manifest.json/main.js'),
          ),
        ),
      );
    });

    test('discovered root: single manifest dir is stripped', () {
      final zip = zipOf({
        'repo-main/manifest.json': _bytes('{"name":"g"}'),
        'repo-main/main.js': _bytes('ok'),
        'repo-main/lib/util.js': _bytes('u'),
      });
      final files = extractExtensionZip(zip, label: 'g');
      expect(
        files.keys,
        containsAll(['manifest.json', 'main.js', 'lib/util.js']),
      );
    });

    test('ambiguous manifests rejected when root is discovered', () {
      final zip = zipOf({
        'a/manifest.json': _bytes('{}'),
        'b/manifest.json': _bytes('{}'),
        'a/main.js': _bytes(''),
      });
      expect(
        () => extractExtensionZip(zip, label: 'g'),
        throwsA(
          isA<ExtCatalogException>().having(
            (e) => e.message,
            'message',
            contains('exactly one manifest.json'),
          ),
        ),
      );
    });
  });
}
