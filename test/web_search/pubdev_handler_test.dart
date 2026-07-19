/// Tests for the pub.dev site handler: URL matching, API JSON → markdown
/// rendering (metadata, score, dependencies, versions), metrics tolerance,
/// and decline paths that fall back to the generic converter.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/src/web_search/fetch_types.dart';
import 'package:flutter_agent_harness/src/web_search/site_handlers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

const _packageJson = {
  'name': 'http',
  'publisherId': 'dart.dev',
  'latest': {
    'version': '1.6.0',
    'pubspec': {
      'description':
          'A composable, multi-platform, Future-based API for HTTP requests.',
      'repository': 'https://github.com/dart-lang/http/tree/master/pkgs/http',
      'homepage': 'https://dart.dev',
      'environment': {'sdk': '^3.4.0'},
      'dependencies': {
        'async': '^2.5.0',
        'http_parser': '^4.0.0',
        'meta': '^1.3.0',
        'web': '>=0.5.0 <2.0.0',
        'some_git_dep': {'git': 'https://github.com/x/y.git'},
        'null_dep': null,
      },
    },
  },
  'versions': [
    {'version': '1.5.0', 'published': '2025-06-01T10:00:00.000Z'},
    {'version': '1.6.0', 'published': '2025-11-10T18:27:56.434747Z'},
  ],
};

const _metricsJson = {
  'score': {
    'grantedPoints': 160,
    'maxPoints': 160,
    'likeCount': 8457,
    'popularityScore': 0.99,
    'downloadCount30Days': 9596670,
  },
};

WebFetchContext _context(http.Client client) => WebFetchContext(
  client: client,
  timeout: const Duration(seconds: 5),
  maxBytes: 1024 * 1024,
);

http.Client _client(Map<String, http.Response> routes) {
  return http_testing.MockClient((request) async {
    return routes[request.url.path] ?? http.Response('not found', 404);
  });
}

void main() {
  group('PubDevHandler', () {
    test('renders package metadata, score, dependencies, and versions', () async {
      final client = _client({
        '/api/packages/http': http.Response(jsonEncode(_packageJson), 200),
        '/api/packages/http/metrics': http.Response(
          jsonEncode(_metricsJson),
          200,
        ),
      });
      const handler = PubDevHandler();
      final result = await handler.tryFetch(
        Uri.parse('https://pub.dev/packages/http'),
        _context(client),
      );

      expect(result, isNotNull);
      expect(result!.method, 'pub.dev');
      final md = result.markdown;
      expect(md, contains('# http'));
      expect(md, contains('A composable, multi-platform, Future-based API'));
      expect(md, contains('**Latest:** 1.6.0 · **Publisher:** dart.dev'));
      expect(md, contains('**Likes:** 8,457'));
      expect(md, contains('**Pub Points:** 160/160'));
      expect(md, contains('**Popularity:** 99%'));
      expect(md, contains('**Downloads (30d):** 9,596,670'));
      expect(md, contains('**Homepage:** https://dart.dev'));
      expect(
        md,
        contains(
          '**Repository:** https://github.com/dart-lang/http/tree/master/pkgs/http',
        ),
      );
      expect(md, contains('**SDK:** sdk: ^3.4.0'));
      expect(md, contains('## Dependencies (6)'));
      expect(md, contains('- async: ^2.5.0'));
      expect(md, contains('- some_git_dep: complex'));
      expect(md, contains('- null_dep\n'));
      expect(md, contains('## Recent versions'));
      expect(md, contains('- 1.6.0 (2025-11-10)'));
      expect(md, contains('- 1.5.0 (2025-06-01)'));
    });

    test('tolerates a missing metrics endpoint', () async {
      final client = _client({
        '/api/packages/http': http.Response(jsonEncode(_packageJson), 200),
      });
      const handler = PubDevHandler();
      final result = await handler.tryFetch(
        Uri.parse('https://pub.dev/packages/http'),
        _context(client),
      );
      expect(result, isNotNull);
      expect(result!.markdown, isNot(contains('**Likes:**')));
      expect(result.markdown, contains('**Latest:** 1.6.0'));
    });

    test('declines non-pub.dev hosts', () async {
      final client = _client({});
      const handler = PubDevHandler();
      final result = await handler.tryFetch(
        Uri.parse('https://example.com/packages/http'),
        _context(client),
      );
      expect(result, isNull);
    });

    test('declines non-package paths', () async {
      final client = _client({});
      const handler = PubDevHandler();
      final result = await handler.tryFetch(
        Uri.parse('https://pub.dev/documentation'),
        _context(client),
      );
      expect(result, isNull);
    });

    test('declines when the API fails or returns malformed JSON', () async {
      const handler = PubDevHandler();
      final failing = _client({'/api/packages/gone': http.Response('', 404)});
      expect(
        await handler.tryFetch(
          Uri.parse('https://pub.dev/packages/gone'),
          _context(failing),
        ),
        isNull,
      );

      final malformed = _client({
        '/api/packages/bad': http.Response('not json', 200),
      });
      expect(
        await handler.tryFetch(
          Uri.parse('https://pub.dev/packages/bad'),
          _context(malformed),
        ),
        isNull,
      );
    });

    test('handles www.pub.dev and deeper package paths', () async {
      final client = _client({
        '/api/packages/http': http.Response(jsonEncode(_packageJson), 200),
        '/api/packages/http/metrics': http.Response('', 404),
      });
      const handler = PubDevHandler();
      final result = await handler.tryFetch(
        Uri.parse('https://www.pub.dev/packages/http/versions/1.6.0'),
        _context(client),
      );
      expect(result, isNotNull);
      expect(result!.markdown, contains('# http'));
    });
  });

  group('defaultWebSiteHandlers', () {
    test('ships the pub.dev handler', () {
      expect(defaultWebSiteHandlers().map((h) => h.id), ['pub.dev']);
    });
  });
}
