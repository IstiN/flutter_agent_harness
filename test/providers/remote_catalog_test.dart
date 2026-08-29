import 'package:flutter_agent_harness/src/providers/remote_catalog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('RemoteModelsCatalog.fromJson', () {
    test('parses providers, windows, and media lists', () {
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'minimax': {
            'contextWindows': {'MiniMax-M3': 1000000, 'MiniMax-M2.7': 204800},
            'media': {
              'imageGeneration': ['image-01'],
              'videoGeneration': ['video-01'],
              'speech': ['speech-01'],
              'transcription': ['asr-01'],
            },
          },
        },
      });
      expect(catalog.providers.keys, ['minimax']);
      final entry = catalog.providers['minimax']!;
      expect(entry.contextWindows['MiniMax-M3'], 1000000);
      expect(entry.contextWindows['MiniMax-M2.7'], 204800);
      expect(entry.media['imageGeneration'], ['image-01']);
      expect(entry.media['videoGeneration'], ['video-01']);
      expect(entry.media['speech'], ['speech-01']);
      expect(entry.media['transcription'], ['asr-01']);
    });

    test('returns empty catalog on non-map root', () {
      expect(RemoteModelsCatalog.fromJson('not-a-map').providers, isEmpty);
    });

    test('returns empty catalog when providers key is not a map', () {
      expect(
        RemoteModelsCatalog.fromJson({'providers': 'oops'}).providers,
        isEmpty,
      );
    });

    test('skips entries with wrong shape without throwing', () {
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'broken': 'not-a-map',
          'good': {
            'contextWindows': {'m1': 1000},
          },
        },
      });
      expect(catalog.providers.keys, ['good']);
      expect(catalog.providers['broken'], isNull);
    });

    test('drops window values that are not positive numbers', () {
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'p': {
            'contextWindows': {
              'm1': 100000,
              'bad1': 0,
              'bad2': -1,
              'bad3': 'x',
            },
          },
        },
      });
      expect(catalog.providers['p']!.contextWindows.keys, ['m1']);
    });

    test('drops media lists whose values are not lists', () {
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'p': {
            'media': {'imageGeneration': 'oops'},
          },
        },
      });
      expect(catalog.providers['p']!.media, isEmpty);
    });

    test('drops non-string media entries', () {
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'p': {
            'media': {
              'imageGeneration': [123, 'good', null],
            },
          },
        },
      });
      expect(catalog.providers['p']!.media['imageGeneration'], ['good']);
    });

    test('skips empty media lists after dedupe', () {
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'p': {
            'media': {'imageGeneration': []},
          },
        },
      });
      expect(
        catalog.providers['p']!.media.containsKey('imageGeneration'),
        isFalse,
      );
    });

    test('ignores deprecated defaultModelId without keeping it', () {
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'p': {'defaultModelId': 'M3'},
        },
      });
      expect(catalog.providers['p']!.contextWindows, isEmpty);
      expect(catalog.providers['p']!.media, isEmpty);
    });
  });

  group('mergeWithRemoteCatalog', () {
    test('endpoint windows win where both report a value', () {
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'minimax': {
            'contextWindows': {'M2.7': 204800, 'M3': 1000000},
          },
        },
      });
      const endpoint = (['M2.7', 'M3'], {'M2.7': 99999}, <String, int>{});
      final merged = mergeWithRemoteCatalog(
        endpointInfo: endpoint,
        providerKind: 'minimax',
        catalog: catalog,
      );
      // Chat ids stay endpoint-only — the catalog must NEVER add ids to
      // the chat list. Provider's /v1/models is the source of truth.
      expect(merged.$1, ['M2.7', 'M3']);
      expect(merged.$2['M2.7'], 99999);
      expect(merged.$2['M3'], 1000000);
    });

    test('does not seed chat ids from catalog context-window keys', () {
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'minimax': {
            'contextWindows': {'M3': 1000000, 'M2.7': 204800},
          },
        },
      });
      const endpoint = (['other-model'], <String, int>{}, <String, int>{});
      final merged = mergeWithRemoteCatalog(
        endpointInfo: endpoint,
        providerKind: 'minimax',
        catalog: catalog,
      );
      // The chat list comes from the endpoint only — even though the
      // catalog has M3 and M2.7 keys, those are window metadata, not
      // model ids. Seeding them here would override the live endpoint.
      expect(merged.$1, ['other-model']);
      expect(merged.$2, {'M3': 1000000, 'M2.7': 204800});
    });

    test('mediaSlot ids replace the chat list with catalog seeds', () {
      // The media-slot path discards the endpoint's chat list and
      // answers the catalog's per-slot media ids. The picker must
      // never see chat ids (e.g. m1) in the media picker.
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'minimax': {
            'media': {
              'imageGeneration': ['image-01', 'image-02'],
            },
          },
        },
      });
      const endpoint = (['m1'], <String, int>{}, <String, int>{});
      final merged = mergeWithRemoteCatalog(
        endpointInfo: endpoint,
        providerKind: 'minimax',
        catalog: catalog,
        mediaSlot: ['imageGeneration'],
      );
      expect(merged.$1, ['image-01', 'image-02']);
    });

    test('null providerKind is a passthrough', () {
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'minimax': {
            'media': {
              'imageGeneration': ['image-01'],
            },
          },
        },
      });
      const endpoint = (['m1'], <String, int>{}, <String, int>{});
      final merged = mergeWithRemoteCatalog(
        endpointInfo: endpoint,
        providerKind: null,
        catalog: catalog,
        mediaSlot: ['imageGeneration'],
      );
      expect(merged.$1, ['m1']);
    });

    test('unknown providerKind is a passthrough', () {
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'minimax': {
            'media': {
              'imageGeneration': ['image-01'],
            },
          },
        },
      });
      const endpoint = (['m1'], <String, int>{}, <String, int>{});
      final merged = mergeWithRemoteCatalog(
        endpointInfo: endpoint,
        providerKind: 'openai',
        catalog: catalog,
        mediaSlot: ['imageGeneration'],
      );
      expect(merged.$1, ['m1']);
    });

    test('media slot path: drops chat ids, answers only catalog seeds', () {
      // The chat list is irrelevant for media slots — the picker
      // should see ONLY media models, never chat ids.
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'minimax': {
            'contextWindows': {'MiniMax-M3': 1000000},
            'media': {
              'imageGeneration': ['image-01', 'image-01-live'],
            },
          },
        },
      });
      const endpoint = (
        ['MiniMax-M3', 'MiniMax-M2.7'],
        <String, int>{},
        <String, int>{},
      );
      final merged = mergeWithRemoteCatalog(
        endpointInfo: endpoint,
        providerKind: 'minimax',
        catalog: catalog,
        mediaSlot: ['imageGeneration'],
      );
      expect(merged.$1, ['image-01', 'image-01-live']);
    });

    test('media slot path: missing slot answers an empty list', () {
      // No media entries for the slot in the catalog → empty list, not
      // a passthrough. The picker falls through to manual entry.
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'minimax': {'media': <String, List<String>>{}},
        },
      });
      const endpoint = (['m1'], <String, int>{}, <String, int>{});
      final merged = mergeWithRemoteCatalog(
        endpointInfo: endpoint,
        providerKind: 'minimax',
        catalog: catalog,
        mediaSlot: ['imageGeneration'],
      );
      expect(merged.$1, isEmpty);
    });

    test('null catalog is a passthrough', () {
      const endpoint = (['m'], {'m': 100}, <String, int>{});
      final merged = mergeWithRemoteCatalog(
        endpointInfo: endpoint,
        providerKind: 'minimax',
        catalog: null,
      );
      expect(merged.$1, endpoint.$1);
      expect(merged.$2, endpoint.$2);
    });
  });

  group('remoteMediaModelsFor', () {
    test('returns the catalog list for the slot, empty when silent', () {
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'minimax': {
            'media': {
              'imageGeneration': ['image-01'],
            },
          },
        },
      });
      expect(
        remoteMediaModelsFor(
          providerKind: 'minimax',
          slot: 'imageGeneration',
          catalog: catalog,
        ),
        ['image-01'],
      );
      expect(
        remoteMediaModelsFor(
          providerKind: 'minimax',
          slot: 'videoGeneration',
          catalog: catalog,
        ),
        isEmpty,
      );
      expect(
        remoteMediaModelsFor(
          providerKind: 'openai',
          slot: 'imageGeneration',
          catalog: catalog,
        ),
        isEmpty,
      );
    });
  });

  group('remoteChatModelsFor', () {
    test('returns contextWindow keys for the requested provider', () {
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'minimax': {
            'contextWindows': {
              'MiniMax-M3': 1000000,
              'MiniMax-M2.7': 204800,
              'MiniMax-M2': 204800,
            },
          },
        },
      });
      expect(remoteChatModelsFor(providerKind: 'minimax', catalog: catalog), [
        'MiniMax-M3',
        'MiniMax-M2.7',
        'MiniMax-M2',
      ]);
    });

    test('returns empty list when the catalog is null', () {
      expect(
        remoteChatModelsFor(providerKind: 'minimax', catalog: null),
        isEmpty,
      );
    });

    test('returns empty list when the provider is unknown', () {
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'minimax': {
            'contextWindows': {'MiniMax-M3': 1000000},
          },
        },
      });
      expect(
        remoteChatModelsFor(providerKind: 'openai', catalog: catalog),
        isEmpty,
      );
    });

    test('returns empty list when the provider has no contextWindows', () {
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'minimax': {
            'media': {
              'imageGeneration': ['image-01'],
            },
          },
        },
      });
      expect(
        remoteChatModelsFor(providerKind: 'minimax', catalog: catalog),
        isEmpty,
      );
    });

    test('providerKind null is treated as no-match', () {
      final catalog = RemoteModelsCatalog.fromJson({
        'providers': {
          'minimax': {
            'contextWindows': {'MiniMax-M3': 1000000},
          },
        },
      });
      expect(
        remoteChatModelsFor(providerKind: null, catalog: catalog),
        isEmpty,
      );
    });

    test('RemoteCatalogEnrichment.chatFallbackFor delegates', () async {
      final fake = RemoteCatalogEnrichment();
      await fake.preload(
        client: MockClient((req) async {
          return http.Response(
            '{"providers": {"minimax": {"contextWindows": '
            '{"MiniMax-M3": 1000000}}}}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      expect(fake.chatFallbackFor('minimax'), ['MiniMax-M3']);
      expect(fake.chatFallbackFor('openai'), isEmpty);
    });
  });

  group('fetchRemoteModelsCatalog', () {
    test('decodes a valid payload', () async {
      final client = MockClient((req) async {
        return http.Response(
          '{"providers": {"minimax": '
          '{"contextWindows": {"M3": 1000000}}}}',
          200,
        );
      });
      final catalog = await fetchRemoteModelsCatalog(
        url: Uri.parse('https://example.test/models-catalog.json'),
        client: client,
      );
      expect(catalog, isNotNull);
      expect(catalog!.providers['minimax']?.contextWindows['M3'], 1000000);
    });

    test('returns null on non-200', () async {
      final client = MockClient((req) async => http.Response('not found', 404));
      final catalog = await fetchRemoteModelsCatalog(
        url: Uri.parse('https://example.test/models-catalog.json'),
        client: client,
      );
      expect(catalog, isNull);
    });

    test('returns null on client exception (no throw)', () async {
      final client = MockClient((req) async {
        throw http.ClientException('boom');
      });
      final catalog = await fetchRemoteModelsCatalog(
        url: Uri.parse('https://example.test/models-catalog.json'),
        client: client,
      );
      expect(catalog, isNull);
    });

    test('swallows a malformed JSON body (no throw)', () async {
      final client = MockClient(
        (req) async => http.Response('this is not json', 200),
      );
      final catalog = await fetchRemoteModelsCatalog(
        url: Uri.parse('https://example.test/models-catalog.json'),
        client: client,
      );
      expect(catalog, isNull);
    });
  });

  group('RemoteCatalogEnrichment', () {
    test(
      'preload caches the catalog; mergeFor layers it on the endpoint info',
      () async {
        final enrichment = RemoteCatalogEnrichment();
        final client = MockClient(
          (req) async => http.Response(
            '{"providers": {"minimax": '
            '{"contextWindows": {"M3": 1000000}}}}',
            200,
          ),
        );
        await enrichment.preload(
          url: Uri.parse('https://example.test/catalog.json'),
          client: client,
        );
        expect(enrichment.cached, isNotNull);
        const endpoint = (['M3', 'm2.7'], <String, int>{}, <String, int>{});
        final merged = enrichment.mergeFor(endpoint, 'minimax');
        expect(merged.$2['M3'], 1000000);
        expect(enrichment.mediaFor('minimax', 'imageGeneration'), isEmpty);
      },
    );

    test('preload falls back to the bundled catalog on failure', () async {
      final enrichment = RemoteCatalogEnrichment();
      final client = MockClient((req) async => http.Response('bad', 500));
      await enrichment.preload(
        url: Uri.parse('https://example.test/catalog.json'),
        client: client,
      );
      // Network/parse failure: the in-process bundled catalog seeds the
      // enrichment so the picker still has data-driven context windows
      // and media lists. Without this the picker collapses to "1 model"
      // for any provider whose /v1/models fetch also fails.
      expect(enrichment.cached, isNotNull);
      expect(
        enrichment.cached!.providers['minimax']?.contextWindows['MiniMax-M3'],
        1000000,
      );
    });

    test('mediaFor returns the catalog list for the slot', () async {
      final enrichment = RemoteCatalogEnrichment();
      final client = MockClient(
        (req) async => http.Response(
          '{"providers": {"minimax": '
          '{"media": {"imageGeneration": ["image-01"]}}}}',
          200,
        ),
      );
      await enrichment.preload(
        url: Uri.parse('https://example.test/catalog.json'),
        client: client,
      );
      expect(enrichment.mediaFor('minimax', 'imageGeneration'), ['image-01']);
    });

    test(
      'bundledRemoteModelsCatalog ships MiniMax chat ids and media lists',
      () {
        final minimax = bundledRemoteModelsCatalog.providers['minimax']!;
        expect(minimax.contextWindows.keys, contains('MiniMax-M3'));
        expect(minimax.contextWindows['MiniMax-M3'], 1000000);
        expect(
          minimax.media['imageGeneration'],
          containsAll(['image-01', 'image-01-live']),
        );
        expect(minimax.media['videoGeneration'], ['MiniMax-H3']);
        expect(minimax.media['musicGeneration'], contains('music-3.0'));
        expect(minimax.media['speech'], contains('speech-2.8-hd'));
      },
    );

    test(
      'mergeFor layers media ids from the catalog for a media slot',
      () async {
        final enrichment = RemoteCatalogEnrichment();
        final client = MockClient(
          (req) async => http.Response(
            '{"providers": {"minimax": '
            '{"media": {"imageGeneration": ["image-01", "image-01-live"]}}}}',
            200,
          ),
        );
        await enrichment.preload(
          url: Uri.parse('https://example.test/catalog.json'),
          client: client,
        );
        // For media slots the chat endpoint's id list is ignored
        // entirely — the picker must only see media models, not chat
        // models like MiniMax-M3. The catalog seed is the answer.
        final merged = enrichment.mergeFor(
          (
            const <String>['MiniMax-M3'],
            const <String, int>{},
            const <String, int>{},
          ),
          'minimax',
          mediaSlot: const ['imageGeneration'],
        );
        expect(merged.$1, isNot(contains('MiniMax-M3')));
        expect(merged.$1, contains('image-01'));
        expect(merged.$1, contains('image-01-live'));
      },
    );
  });
}
