// Deterministic coverage provider for `lib/apps/catalog_service.dart`
// (gh-946 rework): the comprehensive behavior suite
// `catalog_service_test.dart` is runtime-skipped on Linux (hosted-runner
// flake, #936/#938 — root cause in #943), and the Linux shards are the
// ONLY coverage legs the app-crap-gate merges — there is no macOS
// coverage leg (fa#911 follow-up corrected: ci.yml uploads
// app-coverage-shard-* from ubuntu-24.04-arm only). With the whole file
// skipped, catalog_service.dart sat at 0% coverage and its complexity-16
// `downloadWidget` scored CRAP 16^2+16 = 272 > 30, red for every PR.
//
// This suite stays UNCONDITIONAL on every platform: same MockClient /
// MemoryExecutionEnv style as the skipped suite, no shared mutable
// fixture state, injected clocks where TTL boundaries are asserted —
// it keeps the CRAP ratchet honest until #943 unskips the big suite.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fa/apps/catalog_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A minimal well-formed widget entry json map.
Map<String, dynamic> entryJson({
  String id = 'calc',
  String version = '1.0.0',
  String? icon = 'icon.svg',
  Map<String, dynamic>? zip,
  Map<String, dynamic>? preview = const {
    'manifest': 'https://raw.test/m/manifest.json',
    'js': 'https://raw.test/w/widget.js',
  },
  List<Object?>? platforms,
  Object? permissions = const {'network': false, 'allowedCommands': ['ls']},
}) => {
  'id': id,
  'name': 'Calc',
  'version': version,
  'description': 'Calculator',
  'author': 'Fa',
  'tags': ['tools', 42, null, 'math'],
  'permissions': permissions,
  'minRuntime': '0.4.79',
  'icon': icon,
  'platforms': platforms,
  'zip': zip ?? {'file': '$id-1.0.0.zip', 'sha256': '', 'sizeBytes': 0},
  'preview': preview,
};

/// Builds the zip bytes a release asset would carry: one `<id>/` root
/// with manifest.json + widget.js (+ icon.svg when [icon] is set). Extra
/// [entries] land verbatim (hostile-path / directory-entry cases).
Uint8List widgetZip(
  String id, {
  bool icon = true,
  Map<String, List<int>> entries = const {},
  bool rootDirEntry = false,
}) {
  final archive = Archive();
  if (rootDirEntry) {
    archive.addFile(ArchiveFile('$id/', 0, <int>[]));
  }
  final files = <String, List<int>>{
    '$id/manifest.json': utf8.encode('{"id":"$id"}'),
    '$id/widget.js': utf8.encode('(function(){})();'),
    if (icon) '$id/icon.svg': utf8.encode('<svg/>'),
    ...entries,
  };
  final sorted = files.keys.toList()..sort();
  for (final name in sorted) {
    final data = files[name]!;
    archive.addFile(ArchiveFile(name, data.length, data));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// A catalog json whose `calc` entry's zip hash/size match [bytes].
Map<String, dynamic> sealedCatalogFor(
  Uint8List bytes, {
  String id = 'calc',
  String? icon = 'icon.svg',
}) {
  final catalog = {
    'widgets': [
      entryJson(
        id: id,
        icon: icon,
        zip: {
          'file': '$id-1.0.0.zip',
          'sha256': sha256.convert(bytes).toString(),
          'sizeBytes': bytes.length,
        },
      ),
    ],
  };
  return catalog;
}

/// Serves `catalog.json` from [catalog] and `<id>-<version>.zip` assets
/// from [zips] (id → bytes).
MockClient catalogServer(
  Map<String, dynamic> catalog,
  Map<String, Uint8List> zips,
) => MockClient((request) async {
  final name = request.url.pathSegments.last;
  if (name == 'catalog.json') {
    return http.Response.bytes(utf8.encode(jsonEncode(catalog)), 200);
  }
  for (final hit in zips.entries) {
    if (name == '${hit.key}-1.0.0.zip') {
      return http.Response.bytes(hit.value, 200);
    }
  }
  return http.Response('not found', 404);
});

/// A client that always fails at the transport level (offline / DNS).
MockClient deadClient() => MockClient(
  (request) => Future.error(http.ClientException('offline')),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('catalogAssetUri', () {
    test('collapses redundant slashes in every combination', () {
      expect(
        catalogAssetUri('https://x.test/a', 'b.json').toString(),
        'https://x.test/a/b.json',
      );
      expect(
        catalogAssetUri('https://x.test/a/', 'b.json').toString(),
        'https://x.test/a/b.json',
      );
      expect(
        catalogAssetUri('https://x.test/a', '/b.json').toString(),
        'https://x.test/a/b.json',
      );
      expect(
        catalogAssetUri('https://x.test/a//', '//b.json').toString(),
        'https://x.test/a/b.json',
      );
    });
  });

  group('CatalogEntry.fromJson defaults', () {
    test('absent optional blocks fall through to null-safe defaults', () {
      final entry = CatalogEntry.fromJson({
        'id': 'w',
        'name': 'W',
        'version': '1.0.0',
        'description': 'd',
      });
      expect(entry.iconFile, isNull);
      expect(entry.network, isFalse);
      expect(entry.allowedCommands, isEmpty);
      expect(entry.tags, isEmpty);
      expect(entry.platforms, isEmpty);
      expect(entry.zipFile, isEmpty);
      expect(entry.zipSha256, isEmpty);
      expect(entry.zipSizeBytes, 0);
      expect(entry.previewManifestUrl, isNull);
      expect(entry.previewJsUrl, isNull);
      expect(entry.displayName('en'), 'W');
      expect(entry.displayDescription('en'), 'd');
    });

    test('typed fields are filtered and platforms sanitize', () {
      final entry = CatalogEntry.fromJson(
        entryJson(platforms: ['ios', 7, null, 'macos']),
      );
      expect(entry.platforms, ['ios', 'macos']);
      expect(entry.tags, ['tools', 'math']);
      expect(entry.allowedCommands, ['ls']);
      expect(entry.network, isFalse);
      // downloadUrl joins the rolling-release base with the flat asset.
      expect(
        entry.downloadUrl.toString(),
        'https://github.com/IstiN/fa_widgets/releases/latest/download/'
        'calc-1.0.0.zip',
      );
    });
  });

  group('fetchCatalog', () {
    test('fresh fetch parses, sorts and persists the cache', () async {
      final env = MemoryExecutionEnv();
      final bytes = widgetZip('calc');
      final service = CatalogService(
        env,
        httpClient: catalogServer(sealedCatalogFor(bytes), {
          'calc': bytes,
        }),
        clock: () => DateTime.utc(2026, 9, 25, 12),
      );
      final result = await service.fetchCatalog();
      expect(result.stale, isFalse);
      expect(result.entries.single.id, 'calc');
      expect(
        (await env.exists(CatalogService.cacheFile)).valueOrNull,
        isTrue,
        reason: 'cache persisted into apps/',
      );
    });

    test('TTL-fresh cache answers without a network hit', () async {
      final env = MemoryExecutionEnv();
      var hits = 0;
      final bytes = widgetZip('calc');
      final service = CatalogService(
        env,
        httpClient: catalogServer(sealedCatalogFor(bytes), {
          'calc': bytes,
        }),
        clock: () => DateTime.utc(2026, 9, 25, 12),
      );
      await service.fetchCatalog();
      // Age the cached stamp by 1h — well inside the 6h TTL. A real clock
      // would need a sleep; the injected clock reads the persisted stamp.
      final cached = jsonDecode(
        (await env.readTextFile(CatalogService.cacheFile)).valueOrNull!,
      ) as Map<String, dynamic>;
      cached['fetchedAt'] = DateTime.utc(2026, 9, 25, 11).toIso8601String();
      await env.writeFile(CatalogService.cacheFile, jsonEncode(cached));
      hits = 0;
      final second = await CatalogService(
        env,
        httpClient: MockClient((request) async {
          hits++;
          return http.Response('nope', 500);
        }),
        clock: () => DateTime.utc(2026, 9, 25, 12),
      ).fetchCatalog();
      expect(hits, 0, reason: 'inside TTL the cache answers, no fetch');
      expect(second.stale, isFalse);
      expect(second.entries.single.id, 'calc');
    });

    test('force bypasses the TTL and refetches', () async {
      final env = MemoryExecutionEnv();
      var hits = 0;
      final bytes = widgetZip('calc');
      Map<String, dynamic> catalog() => sealedCatalogFor(bytes);
      final service = CatalogService(
        env,
        httpClient: MockClient((request) async {
          final name = request.url.pathSegments.last;
          if (name == 'catalog.json') {
            hits++;
            return http.Response.bytes(
              utf8.encode(jsonEncode(catalog())),
              200,
            );
          }
          return http.Response.bytes(bytes, 200);
        }),
      );
      await service.fetchCatalog();
      final again = await service.fetchCatalog(force: true);
      expect(again.entries.single.id, 'calc');
      expect(hits, 2, reason: 'force must hit the network past a fresh TTL');
    });

    test('network failure with a cache yields the stale snapshot', () async {
      final env = MemoryExecutionEnv();
      final bytes = widgetZip('calc');
      final seeding = catalogServer(sealedCatalogFor(bytes), {
        'calc': bytes,
      });
      final service = CatalogService(env, httpClient: seeding);
      await service.fetchCatalog();
      final offline = await CatalogService(
        env,
        httpClient: deadClient(),
      ).fetchCatalog(force: true);
      expect(offline.stale, isTrue);
      expect(offline.error, isNotNull);
      expect(offline.entries.single.id, 'calc');
    });

    test('HTTP error with a cache yields the stale snapshot', () async {
      final env = MemoryExecutionEnv();
      final bytes = widgetZip('calc');
      await CatalogService(
        env,
        httpClient: catalogServer(sealedCatalogFor(bytes), {
          'calc': bytes,
        }),
      ).fetchCatalog();
      final stale = await CatalogService(
        env,
        httpClient: MockClient((request) async => http.Response('boom', 503)),
      ).fetchCatalog(force: true);
      expect(stale.stale, isTrue);
      expect('$stale.error', contains('503'));
    });

    test('no cache and transport failure rethrows CatalogError', () async {
      final env = MemoryExecutionEnv();
      final service = CatalogService(env, httpClient: deadClient());
      await expectLater(service.fetchCatalog(), throwsA(isA<CatalogError>()));
    });

    test('no cache and HTTP failure rethrows CatalogError', () async {
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        httpClient: MockClient((request) async => http.Response('boom', 500)),
      );
      await expectLater(service.fetchCatalog(), throwsA(isA<CatalogError>()));
    });

    test('non-object catalog body is a CatalogError', () async {
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        httpClient: MockClient((request) async => http.Response.bytes(
          utf8.encode('[]'),
          200,
        )),
      );
      await expectLater(service.fetchCatalog(), throwsA(isA<CatalogError>()));
    });

    test('corrupt cache payload is ignored, never fatal', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(CatalogService.cacheFile, '{not json');
      final bytes = widgetZip('calc');
      final service = CatalogService(
        env,
        httpClient: catalogServer(sealedCatalogFor(bytes), {
          'calc': bytes,
        }),
      );
      final result = await service.fetchCatalog();
      expect(result.entries.single.id, 'calc');
    });

    test('catalog without widgets[] is a CatalogError', () async {
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        httpClient: MockClient(
          (request) async => http.Response('{"schemaVersion":1}', 200),
        ),
      );
      await expectLater(service.fetchCatalog(), throwsA(isA<CatalogError>()));
    });

    test('malformed entries are skipped, never fail the gallery', () async {
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        httpClient: MockClient((request) async {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'widgets': [
                'not-a-map',
                {'id': '', 'version': '1.0.0', 'zip': {'file': 'a.zip'}},
                {'id': 'b', 'version': '', 'zip': {'file': 'b.zip'}},
                {'id': 'c', 'version': '1.0.0'},
                entryJson(id: 'aa'),
              ],
            })),
            200,
          );
        }),
      );
      final result = await service.fetchCatalog();
      expect(result.entries.map((e) => e.id), ['aa']);
    });
  });

  group('downloadWidget (native zip path)', () {
    test('unpacks a sealed archive into relative paths', () async {
      final bytes = widgetZip('calc', rootDirEntry: true);
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        httpClient: catalogServer(sealedCatalogFor(bytes), {'calc': bytes}),
      );
      final files = await service.downloadWidget(
        CatalogEntry.fromJson(sealedCatalogFor(bytes)['widgets'].single),
      );
      expect(files.keys.toList()..sort(), [
        'icon.svg',
        'manifest.json',
        'widget.js',
      ]);
      expect(utf8.decode(files['manifest.json']!), contains('"calc"'));
    });

    test('empty zip sha skips verification', () async {
      final bytes = widgetZip('calc');
      final catalog = sealedCatalogFor(bytes);
      ((catalog['widgets'].single as Map)['zip']
          as Map<String, dynamic>)['sha256'] = '';
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        httpClient: catalogServer(catalog, {'calc': bytes}),
      );
      final files = await service.downloadWidget(
        CatalogEntry.fromJson(catalog['widgets'].single),
      );
      expect(files, contains('widget.js'));
    });

    test('sha mismatch aborts before unpacking', () async {
      final bytes = widgetZip('calc');
      final catalog = sealedCatalogFor(bytes);
      ((catalog['widgets'].single as Map)['zip']
          as Map<String, dynamic>)['sha256'] = 'deadbeef';
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        httpClient: catalogServer(catalog, {'calc': bytes}),
      );
      await expectLater(
        service.downloadWidget(
          CatalogEntry.fromJson(catalog['widgets'].single),
        ),
        throwsA(
          isA<CatalogError>().having((e) => '$e', 'text', contains('sha256')),
        ),
      );
    });

    test('empty or slash-bearing asset names are rejected', () async {
      final env = MemoryExecutionEnv();
      final service = CatalogService(env, httpClient: deadClient());
      for (final bad in ['', 'sub/dir.zip']) {
        final entry = CatalogEntry.fromJson(
          entryJson(zip: {'file': bad, 'sha256': '', 'sizeBytes': 0}),
        );
        await expectLater(
          service.downloadWidget(entry),
          throwsA(
            isA<CatalogError>().having(
              (e) => '$e',
              'text',
              contains('bad asset name'),
            ),
          ),
        );
      }
    });

    test('HTTP failure and transport failure surface as CatalogError', () async {
      final env = MemoryExecutionEnv();
      final entry = CatalogEntry.fromJson(entryJson());
      await expectLater(
        CatalogService(
          env,
          httpClient: MockClient(
            (request) async => http.Response('nope', 404),
          ),
        ).downloadWidget(entry),
        throwsA(
          isA<CatalogError>().having((e) => '$e', 'text', contains('404')),
        ),
      );
      await expectLater(
        CatalogService(env, httpClient: deadClient()).downloadWidget(entry),
        throwsA(
          isA<CatalogError>().having(
            (e) => '$e',
            'text',
            contains('download failed'),
          ),
        ),
      );
    });

    test('hostile archive layouts are rejected', () async {
      for (final evil in [
        '../evil.js',
        '/abs/evil.js',
        'other/evil.js',
        'calc/..\\evil.js',
        'calc//deep.js',
      ]) {
        final bytes = widgetZip(
          'calc',
          icon: false,
          entries: {evil: utf8.encode('bad')},
        );
        final catalog = sealedCatalogFor(bytes, icon: null);
        final env = MemoryExecutionEnv();
        final service = CatalogService(
          env,
          httpClient: catalogServer(catalog, {'calc': bytes}),
        );
        await expectLater(
          service.downloadWidget(
            CatalogEntry.fromJson(catalog['widgets'].single),
          ),
          throwsA(isA<CatalogError>()),
          reason: 'zip entry "$evil" must be rejected',
        );
      }
    });

    test('archive missing manifest or widget.js is rejected', () async {
      for (final missing in ['manifest.json', 'widget.js']) {
        final files = {
          'calc/manifest.json': utf8.encode('{}'),
          'calc/widget.js': utf8.encode(''),
        }..remove('calc/$missing');
        final archive = Archive();
        for (final hit in files.entries) {
          archive.addFile(
            ArchiveFile(hit.key, hit.value.length, hit.value),
          );
        }
        final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
        final catalog = sealedCatalogFor(bytes, icon: null);
        final env = MemoryExecutionEnv();
        final service = CatalogService(
          env,
          httpClient: catalogServer(catalog, {'calc': bytes}),
        );
        await expectLater(
          service.downloadWidget(
            CatalogEntry.fromJson(catalog['widgets'].single),
          ),
          throwsA(
            isA<CatalogError>().having((e) => '$e', 'text', contains(missing)),
          ),
        );
      }
    });
  });

  group('downloadWidget (web source path)', () {
    CatalogEntry webEntry([
      void Function(Map<String, dynamic>)? mutate,
    ]) {
      final json = entryJson();
      mutate?.call(json);
      return CatalogEntry.fromJson(json);
    }

    MockClient rawServer(
      List<String> requested, {
      int jsStatus = 200,
      String jsBody = '(function(){})();',
      String manifestBody = '{"id":"calc"}',
      bool throwOnFetch = false,
    }) => MockClient((request) async {
      requested.add(request.url.toString());
      if (throwOnFetch) {
        return Future.error(http.ClientException('socket closed'));
      }
      if (request.url.path.endsWith('manifest.json')) {
        return http.Response(manifestBody, 200);
      }
      if (request.url.path.endsWith('icon.svg')) {
        return http.Response('<svg/>', 200);
      }
      return http.Response(jsBody, jsStatus);
    });

    test('fetches preview sources verbatim plus the mirrored icon', () async {
      final requested = <String>[];
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        isWeb: true,
        rawBaseUrl: Uri.parse('https://raw.test/repo/'),
        httpClient: rawServer(requested),
      );
      final files = await service.downloadWidget(webEntry());
      expect(requested, [
        'https://raw.test/m/manifest.json',
        'https://raw.test/w/widget.js',
        'https://raw.test/repo/widgets/calc/icon.svg',
      ]);
      expect(utf8.decode(files['widget.js']!), '(function(){})();');
    });

    test('entries without an icon skip the icon request', () async {
      final requested = <String>[];
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        isWeb: true,
        httpClient: rawServer(requested),
      );
      final files = await service.downloadWidget(webEntry((j) {
        j['icon'] = null;
      }));
      expect(requested, hasLength(2));
      expect(files.keys.toList()..sort(), ['manifest.json', 'widget.js']);
    });

    test('missing preview URL fails loudly before any request', () async {
      final requested = <String>[];
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        isWeb: true,
        httpClient: rawServer(requested),
      );
      for (final mutate in [
        (Map<String, dynamic> j) => j['preview'] = null,
        (Map<String, dynamic> j) =>
            (j['preview'] as Map<String, dynamic>)['js'] = null,
        (Map<String, dynamic> j) =>
            (j['preview'] as Map<String, dynamic>)['manifest'] =
                'not-absolute',
        (Map<String, dynamic> j) =>
            (j['preview'] as Map<String, dynamic>)['js'] = 'ftp://x/y.js',
        (Map<String, dynamic> j) =>
            (j['preview'] as Map<String, dynamic>)['js'] = 'http://[::',
      ]) {
        await expectLater(
          service.downloadWidget(webEntry(mutate)),
          throwsA(
            isA<CatalogError>().having(
              (e) => '$e',
              'text',
              contains('preview URL'),
            ),
          ),
          reason: 'preview mutation must be rejected',
        );
        expect(requested, isEmpty);
      }
    });

    test('unsafe widget id or icon name fails before any request', () async {
      final requested = <String>[];
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        isWeb: true,
        httpClient: rawServer(requested),
      );
      await expectLater(
        service.downloadWidget(webEntry((j) {
          j['id'] = '../evil';
        })),
        throwsA(
          isA<CatalogError>().having((e) => '$e', 'text', contains('id')),
        ),
      );
      await expectLater(
        service.downloadWidget(webEntry((j) {
          j['icon'] = '../icon.svg';
        })),
        throwsA(
          isA<CatalogError>().having(
            (e) => '$e',
            'text',
            contains('unsafe icon name'),
          ),
        ),
      );
      expect(requested, isEmpty);
    });

    test('source fetch failures fail loudly', () async {
      final requested = <String>[];
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        isWeb: true,
        httpClient: rawServer(requested, jsStatus: 404),
      );
      await expectLater(
        service.downloadWidget(webEntry()),
        throwsA(
          isA<CatalogError>().having((e) => '$e', 'text', contains('404')),
        ),
      );
      final requested2 = <String>[];
      final service2 = CatalogService(
        env,
        isWeb: true,
        httpClient: rawServer(requested2, throwOnFetch: true),
      );
      await expectLater(
        service2.downloadWidget(webEntry()),
        throwsA(
          isA<CatalogError>().having(
            (e) => '$e',
            'text',
            contains('fetch failed'),
          ),
        ),
      );
    });

    test('malformed manifest or empty widget.js fails loudly', () async {
      final env = MemoryExecutionEnv();
      for (final (label, body) in [('bad', 'not json'), ('array', '[]')]) {
        final service = CatalogService(
          env,
          isWeb: true,
          httpClient: rawServer(
            <String>[],
            jsBody: '(function(){})();',
            manifestBody: body,
          ),
        );
        await expectLater(
          service.downloadWidget(webEntry()),
          throwsA(
            isA<CatalogError>().having(
              (e) => '$e',
              'text',
              contains('manifest.json'),
            ),
          ),
          reason: 'malformed manifest "$label" must be rejected',
        );
      }
      final emptyJs = CatalogService(
        env,
        isWeb: true,
        httpClient: rawServer(<String>[], jsBody: ''),
      );
      await expectLater(
        emptyJs.downloadWidget(webEntry()),
        throwsA(
          isA<CatalogError>().having(
            (e) => '$e',
            'text',
            contains('widget.js is empty'),
          ),
        ),
      );
    });
  });

  group('downloadWidgetHealing', () {
    test('a clean download never refetches the catalog', () async {
      final bytes = widgetZip('calc');
      var catalogCalls = 0;
      final catalog = sealedCatalogFor(bytes);
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        httpClient: MockClient((request) async {
          final name = request.url.pathSegments.last;
          if (name == 'catalog.json') {
            catalogCalls++;
            return http.Response.bytes(
              utf8.encode(jsonEncode(catalog)),
              200,
            );
          }
          return http.Response.bytes(bytes, 200);
        }),
      );
      await service.fetchCatalog();
      final files = await service.downloadWidgetHealing(
        CatalogEntry.fromJson(catalog['widgets'].single),
      );
      expect(files, contains('widget.js'));
      expect(catalogCalls, 1, reason: 'no heal on a clean install');
    });

    test('sha mismatch heals: refetch once and retry when bytes changed', () async {
      final bytesA = widgetZip('calc', icon: false);
      final bytesB = widgetZip('calc', icon: false, entries: {
        'calc/widget.js': utf8.encode('(function(){/* b */})();'),
      });
      var catalogCalls = 0;
      Map<String, dynamic> catalogFor(Uint8List bytes) =>
          sealedCatalogFor(bytes);
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        httpClient: MockClient((request) async {
          final name = request.url.pathSegments.last;
          if (name == 'catalog.json') {
            catalogCalls++;
            return http.Response.bytes(
              utf8.encode(
                jsonEncode(catalogFor(catalogCalls == 1 ? bytesA : bytesB)),
              ),
              200,
            );
          }
          // The asset name is stable across the "republish".
          return http.Response.bytes(bytesB, 200);
        }),
      );
      final stale = await service.fetchCatalog();
      final files = await service.downloadWidgetHealing(stale.entries.single);
      expect(utf8.decode(files['widget.js']!), contains('/* b */'));
      expect(catalogCalls, 2, reason: 'one stale fetch + one forced refetch');
    });

    test('sha mismatch with unchanged catalog rethrows', () async {
      final bytes = widgetZip('calc', icon: false);
      var catalogCalls = 0;
      final catalog = sealedCatalogFor(bytes);
      ((catalog['widgets'].single as Map)['zip']
          as Map<String, dynamic>)['sha256'] = 'deadbeef';
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        httpClient: MockClient((request) async {
          final name = request.url.pathSegments.last;
          if (name == 'catalog.json') {
            catalogCalls++;
            return http.Response.bytes(
              utf8.encode(jsonEncode(catalog)),
              200,
            );
          }
          return http.Response.bytes(bytes, 200);
        }),
      );
      final entry = CatalogEntry.fromJson(catalog['widgets'].single);
      await expectLater(
        service.downloadWidgetHealing(entry),
        throwsA(
          isA<CatalogError>().having((e) => '$e', 'text', contains('sha256')),
        ),
      );
      expect(catalogCalls, 2, reason: 'heal ran once, found the entry '
          'unchanged, rethrew');
    });

    test('non-sha failures rethrow without healing', () async {
      final env = MemoryExecutionEnv();
      var catalogCalls = 0;
      final service = CatalogService(
        env,
        httpClient: MockClient((request) async {
          final name = request.url.pathSegments.last;
          if (name == 'catalog.json') {
            catalogCalls++;
            return http.Response.bytes(
              utf8.encode(jsonEncode(sealedCatalogFor(widgetZip('calc')))),
              200,
            );
          }
          return http.Response('nope', 404);
        }),
      );
      final entry = CatalogEntry.fromJson(
        entryJson(zip: {'file': 'calc-1.0.0.zip', 'sha256': '', 'sizeBytes': 0}),
      );
      await expectLater(
        service.downloadWidgetHealing(entry),
        throwsA(
          isA<CatalogError>().having((e) => '$e', 'text', contains('404')),
        ),
      );
      expect(catalogCalls, 0, reason: 'only sha256 mismatches heal');
    });
  });
}
