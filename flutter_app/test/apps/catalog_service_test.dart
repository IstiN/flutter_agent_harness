import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fa/apps/catalog_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Builds a fake release asset server: catalog.json plus per-widget zips
/// laid out `<id>/<file>` exactly like the publish workflow produces.
http.Client fakeServer(Map<String, dynamic> catalog) {
  Uint8List zipOf(String id) {
    final archive = Archive();
    final files = {
      '$id/manifest.json': utf8.encode('{"id":"$id"}'),
      '$id/widget.js': utf8.encode('(function(){})();'),
      if ((catalog['widgets'] as List).any(
        (w) => w['id'] == id && w['icon'] != null,
      ))
        '$id/icon.svg': utf8.encode('<svg/>'),
    };
    final sorted = files.keys.toList()..sort();
    for (final name in sorted) {
      final data = files[name]!;
      archive.addFile(ArchiveFile(name, data.length, data));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  return MockClient((request) async {
    final name = request.url.pathSegments.last;
    if (name == 'catalog.json') {
      return http.Response(jsonEncode(catalog), 200);
    }
    for (final w in catalog['widgets'] as List) {
      if ('${w['id']}-${w['version']}.zip' == name) {
        return http.Response.bytes(zipOf(w['id'] as String), 200);
      }
    }
    return http.Response('not found', 404);
  });
}

Map<String, dynamic> goodCatalog() => {
  'schemaVersion': 1,
  'generatedAt': '2026-08-26T21:18:21Z',
  'sourceRepo': 'https://github.com/IstiN/fa_widgets',
  'widgets': [
    {
      'id': 'calculator',
      'name': 'Calculator',
      'version': '1.2.0',
      'description': 'Scientific calculator',
      'author': 'Fa',
      'tags': ['productivity'],
      'permissions': {'network': false, 'allowedCommands': <String>[]},
      'minRuntime': '0.4.79',
      'icon': 'icon.svg',
      'zip': {'file': 'calculator-1.2.0.zip', 'sha256': '', 'sizeBytes': 100},
    },
    {
      'id': 'focus-timer',
      'name': 'Focus Timer',
      'version': '1.0.0',
      'description': 'Pomodoro timer',
      'tags': ['productivity', 'timer'],
      'permissions': {'network': false, 'allowedCommands': <String>[]},
      'minRuntime': '0.4.79',
      'icon': null,
      'zip': {'file': 'focus-timer-1.0.0.zip', 'sha256': '', 'sizeBytes': 50},
    },
  ],
};

/// Fills every zip.sha256 with the hash of what [server] would serve —
/// round-trips the fixture through a throwaway service instance.
Future<Map<String, dynamic>> sealedCatalog(Map<String, dynamic> catalog) async {
  final sealed = jsonDecode(jsonEncode(catalog)) as Map<String, dynamic>;
  for (final w in sealed['widgets'] as List) {
    final probe = await _captureZip(w['id'] as String);
    (w['zip'] as Map<String, dynamic>)['sha256'] = sha256
        .convert(probe)
        .toString();
    (w['zip'] as Map<String, dynamic>)['sizeBytes'] = probe.length;
  }
  return sealed;
}

final List<Uint8List> captured = [];
Future<Uint8List> _captureZip(String id) async {
  // Rebuild deterministically via a one-off client hit.
  final client = fakeServer(goodCatalog());
  final response = await client.get(
    Uri.parse('$kDefaultWidgetsBaseUrl/calculator-1.2.0.zip'),
  );
  if (id != 'calculator') return response.bodyBytes;
  captured.clear();
  captured.add(response.bodyBytes);
  return response.bodyBytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CatalogEntry.fromJson platforms', () {
    Map<String, dynamic> base() =>
        Map<String, dynamic>.from(goodCatalog()['widgets'][0] as Map);

    test('parses declared platforms', () {
      final json = base()..['platforms'] = ['ios', 'macos'];
      expect(CatalogEntry.fromJson(json).platforms, ['ios', 'macos']);
    });

    test('absent platforms default to empty', () {
      expect(CatalogEntry.fromJson(base()).platforms, isEmpty);
    });

    test('null or non-list platforms are treated as absent', () {
      expect(
        CatalogEntry.fromJson(base()..['platforms'] = null).platforms,
        isEmpty,
      );
      expect(
        CatalogEntry.fromJson(base()..['platforms'] = 'ios').platforms,
        isEmpty,
      );
    });

    test('non-string items are dropped', () {
      final json = base()..['platforms'] = ['ios', 42, null, 'macos'];
      expect(CatalogEntry.fromJson(json).platforms, ['ios', 'macos']);
    });
  });

  group('CatalogService.fetchCatalog', () {
    test('parses entries and stamps freshness', () async {
      final env = MemoryExecutionEnv();
      var hits = 0;
      final service = CatalogService(
        env,
        httpClient: MockClient((request) async {
          hits++;
          return http.Response(jsonEncode(goodCatalog()), 200);
        }),
        clock: () => DateTime.utc(2026, 8, 26, 12),
      );
      final result = await service.fetchCatalog();
      expect(result.stale, isFalse);
      expect(hits, 1);
      expect(result.entries.map((e) => e.id).toList(), [
        'calculator',
        'focus-timer',
      ]);
      final calc = result.entries.first;
      expect(calc.name, 'Calculator');
      expect(calc.version, '1.2.0');
      expect(calc.iconFile, 'icon.svg');
      expect(calc.zipFile, 'calculator-1.2.0.zip');
      expect(calc.network, isFalse);
    });

    test('non-ASCII descriptions survive a charset-less response', () async {
      // GitHub release assets / raw URLs send no charset, so http's
      // `response.body` would latin1-decode the UTF-8 bytes into mojibake
      // ("→" → "â\x86\x92"). The service must decode the BYTES as UTF-8.
      final catalog = goodCatalog();
      (catalog['widgets'] as List)[0]['description'] = 'Dodge → steer · Таймер';
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        httpClient: MockClient((request) async {
          return http.Response.bytes(utf8.encode(jsonEncode(catalog)), 200);
        }),
      );
      final result = await service.fetchCatalog();
      final calc = result.entries.firstWhere((e) => e.id == 'calculator');
      expect(calc.description, 'Dodge → steer · Таймер');
    });

    test('TTL cache serves the second fetch without a network hit', () async {
      final env = MemoryExecutionEnv();
      var hits = 0;
      final service = CatalogService(
        env,
        httpClient: MockClient((request) async {
          hits++;
          return http.Response(jsonEncode(goodCatalog()), 200);
        }),
        clock: () => DateTime.utc(2026, 8, 26, 12),
      );
      await service.fetchCatalog();
      final second = await service.fetchCatalog();
      expect(hits, 1, reason: 'within TTL the cache answers');
      expect(second.stale, isFalse);
      expect(second.entries, hasLength(2));
      expect(
        (await env.exists(CatalogService.cacheFile)).valueOrNull,
        isTrue,
        reason: 'cache persisted into apps/',
      );
    });

    test('force bypasses the TTL', () async {
      final env = MemoryExecutionEnv();
      var hits = 0;
      final service = CatalogService(
        env,
        httpClient: MockClient((request) async {
          hits++;
          return http.Response(jsonEncode(goodCatalog()), 200);
        }),
      );
      await service.fetchCatalog();
      await service.fetchCatalog(force: true);
      expect(hits, 2);
    });

    test('network failure falls back to the stale cache', () async {
      final env = MemoryExecutionEnv();
      var failNow = false;
      late CatalogService service;
      service = CatalogService(
        env,
        httpClient: MockClient((request) async {
          if (failNow) return http.Response('boom', 500);
          return http.Response(jsonEncode(goodCatalog()), 200);
        }),
        clock: () => DateTime.utc(2026, 8, 26, 12),
      );
      await service.fetchCatalog();
      failNow = true;
      final fallback = await service.fetchCatalog(force: true);
      expect(fallback.stale, isTrue);
      expect(fallback.error, isNotNull);
      expect(fallback.entries, hasLength(2));
    });

    test('no cache and no network rethrows', () async {
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        httpClient: MockClient((request) async {
          return http.Response('boom', 503);
        }),
      );
      await expectLater(service.fetchCatalog(), throwsA(isA<CatalogError>()));
    });

    test('corrupt cache payload is ignored, not fatal', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(CatalogService.cacheFile, '{not json');
      var hits = 0;
      final service = CatalogService(
        env,
        httpClient: MockClient((request) async {
          hits++;
          return http.Response(jsonEncode(goodCatalog()), 200);
        }),
      );
      final result = await service.fetchCatalog();
      expect(hits, 1);
      expect(result.entries, hasLength(2));
    });
  });

  group('CatalogService.downloadWidget', () {
    test('unpacks the single-root archive into relative paths', () async {
      final sealed = await sealedCatalog(goodCatalog());
      final env = MemoryExecutionEnv();
      final service = CatalogService(env, httpClient: fakeServer(sealed));
      final files = await service.downloadWidget(
        CatalogEntry.fromJson(sealed['widgets'][0] as Map<String, dynamic>),
      );
      expect(files.keys.toList()..sort(), [
        'icon.svg',
        'manifest.json',
        'widget.js',
      ]);
      expect(utf8.decode(files['manifest.json']!), contains('"calculator"'));
    });

    test('sha mismatch aborts before any unpacking', () async {
      final catalog = goodCatalog();
      (((catalog['widgets'] as List)[0] as Map<String, dynamic>)['zip']
              as Map<String, dynamic>)['sha256'] =
          'deadbeef';
      final env = MemoryExecutionEnv();
      final service = CatalogService(env, httpClient: fakeServer(catalog));
      await expectLater(
        service.downloadWidget(
          CatalogEntry.fromJson(catalog['widgets'][0] as Map<String, dynamic>),
        ),
        throwsA(
          isA<CatalogError>().having((e) => '$e', 'text', contains('sha256')),
        ),
      );
    });

    test(
      'healing download refetches a stale catalog and retries once',
      () async {
        // The stale cache references bytes A; the "republish" replaced the
        // same-named asset with bytes B and an updated catalog hash.
        Uint8List zipBytes(String marker) {
          final archive = Archive();
          final manifest = utf8.encode('{"id":"w"}');
          final js = utf8.encode('/* $marker */');
          archive.addFile(
            ArchiveFile('w/manifest.json', manifest.length, manifest),
          );
          archive.addFile(ArchiveFile('w/widget.js', js.length, js));
          return Uint8List.fromList(ZipEncoder().encode(archive));
        }

        final bytesB = zipBytes('b');
        final hashA = sha256.convert(zipBytes('a')).toString();
        final hashB = sha256.convert(bytesB).toString();
        var catalogCalls = 0;
        Map<String, dynamic> catalogFor(String hash) => {
          'widgets': [
            {
              'id': 'w',
              'name': 'W',
              'version': '1.0.0',
              'permissions': {'network': false, 'allowedCommands': []},
              'zip': {
                'file': 'w-1.0.0.zip',
                'sha256': hash,
                'sizeBytes': bytesB.length,
              },
            },
          ],
        };
        final client = MockClient((request) async {
          final name = request.url.pathSegments.last;
          if (name == 'catalog.json') {
            catalogCalls++;
            return http.Response(
              jsonEncode(catalogFor(catalogCalls == 1 ? hashA : hashB)),
              200,
            );
          }
          if (name == 'w-1.0.0.zip') return http.Response.bytes(bytesB, 200);
          return http.Response('nf', 404);
        });
        final env = MemoryExecutionEnv();
        final service = CatalogService(env, httpClient: client);
        final stale = await service.fetchCatalog(); // caches the hashA entry
        final files = await service.downloadWidgetHealing(stale.entries.single);
        expect(utf8.decode(files['widget.js']!), '/* b */');
        expect(catalogCalls, 2); // one stale fetch + one forced refetch
      },
    );

    test('path escape / foreign roots are rejected', () async {
      Uint8List evilZip(String entryName) {
        final archive = Archive()
          ..addFile(ArchiveFile(entryName, 3, utf8.encode('bad')));
        return Uint8List.fromList(ZipEncoder().encode(archive));
      }

      for (final evil in ['../evil.js', '/abs/evil.js', 'other/evil.js']) {
        final bytes = evilZip(evil);
        final catalog = goodCatalog();
        final zip =
            (catalog['widgets'][0] as Map)['zip'] as Map<String, dynamic>;
        zip['sha256'] = sha256.convert(bytes).toString();
        zip['sizeBytes'] = bytes.length;
        final env = MemoryExecutionEnv();
        final service = CatalogService(
          env,
          httpClient: MockClient((request) async {
            return http.Response.bytes(bytes, 200);
          }),
        );
        await expectLater(
          service.downloadWidget(
            CatalogEntry.fromJson(
              Map<String, dynamic>.from(
                catalog['widgets'][0] as Map<dynamic, dynamic>,
              ),
            ),
          ),
          throwsA(isA<CatalogError>()),
          reason: 'entry $evil must be rejected',
        );
      }
    });

    test('HTTP failure surfaces as CatalogError', () async {
      final env = MemoryExecutionEnv();
      final service = CatalogService(
        env,
        httpClient: MockClient((request) async {
          return http.Response('nope', 404);
        }),
      );
      await expectLater(
        service.downloadWidget(
          CatalogEntry.fromJson(
            Map<String, dynamic>.from(goodCatalog()['widgets'][0] as Map),
          ),
        ),
        throwsA(isA<CatalogError>()),
      );
    });
  });
}
