/// Tests for the keyed providers (Brave, Tavily): request shape (auth
/// header/param, query fields), response parsing, availability against the
/// secrets map, and error surfacing.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/src/web_search/providers.dart';
import 'package:flutter_agent_harness/src/web_search/search_types.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

WebSearchRequest _request(
  http.Client client, {
  Map<String, String> secrets = const {'BRAVE_API_KEY': 'brave-key-123'},
  int count = 10,
}) {
  return WebSearchRequest(
    query: 'dart http',
    count: count,
    client: client,
    timeout: const Duration(seconds: 5),
    secrets: secrets,
  );
}

void main() {
  group('BraveSearchProvider', () {
    test('requires BRAVE_API_KEY for availability', () {
      const provider = BraveSearchProvider();
      expect(provider.apiKeyName, 'BRAVE_API_KEY');
      expect(isWebSearchProviderAvailable(provider, const {}), isFalse);
      expect(
        isWebSearchProviderAvailable(provider, const {'BRAVE_API_KEY': ''}),
        isFalse,
      );
      expect(
        isWebSearchProviderAvailable(provider, const {
          'BRAVE_API_KEY': 'brave-key-123',
        }),
        isTrue,
      );
    });

    test('sends the documented request shape and parses results', () async {
      Uri? seenUrl;
      String? seenToken;
      String? seenAccept;
      final client = http_testing.MockClient((request) async {
        expect(request.method, 'GET');
        seenUrl = request.url;
        seenToken = request.headers['X-Subscription-Token'];
        seenAccept = request.headers['Accept'];
        return http.Response(
          jsonEncode({
            'web': {
              'results': [
                {
                  'title': 'http | Dart Package',
                  'url': 'https://pub.dev/packages/http',
                  'description': 'A composable HTTP API.',
                  'extra_snippets': ['Multi-platform.', 'Future-based.'],
                  'age': '2025-01-01',
                },
                {'url': 'https://dart.dev', 'description': null},
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      const provider = BraveSearchProvider();
      final response = await provider.search(_request(client, count: 5));

      expect(seenUrl?.host, 'api.search.brave.com');
      expect(seenUrl?.path, '/res/v1/web/search');
      expect(seenUrl?.queryParameters['q'], 'dart http');
      expect(seenUrl?.queryParameters['count'], '5');
      expect(seenUrl?.queryParameters['extra_snippets'], 'true');
      expect(seenToken, 'brave-key-123');
      expect(seenAccept, 'application/json');

      expect(response.provider, 'brave');
      expect(response.sources, hasLength(2));
      expect(response.sources[0].title, 'http | Dart Package');
      expect(
        response.sources[0].snippet,
        'A composable HTTP API.\nMulti-platform.\nFuture-based.',
      );
      // Missing title falls back to the URL; missing snippet stays null.
      expect(response.sources[1].title, 'https://dart.dev');
      expect(response.sources[1].snippet, isNull);
    });

    test('throws a status-tagged error on API failure', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response('{"error": "Invalid token"}', 401),
      );
      const provider = BraveSearchProvider();
      await expectLater(
        provider.search(_request(client)),
        throwsA(
          isA<WebSearchException>()
              .having((e) => e.provider, 'provider', 'brave')
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.message, 'message', contains('Invalid token')),
        ),
      );
    });

    test('fails fast when the key is missing', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response('{}', 200),
      );
      const provider = BraveSearchProvider();
      await expectLater(
        provider.search(_request(client, secrets: const {})),
        throwsA(
          isA<WebSearchException>().having(
            (e) => e.message,
            'message',
            contains('BRAVE_API_KEY'),
          ),
        ),
      );
    });
  });

  group('TavilySearchProvider', () {
    test('requires TAVILY_API_KEY for availability', () {
      const provider = TavilySearchProvider();
      expect(provider.apiKeyName, 'TAVILY_API_KEY');
      expect(isWebSearchProviderAvailable(provider, const {}), isFalse);
      expect(
        isWebSearchProviderAvailable(provider, const {
          'TAVILY_API_KEY': 'tvly-key',
        }),
        isTrue,
      );
    });

    test(
      'posts the documented body with bearer auth and parses results',
      () async {
        String? seenAuth;
        Map<String, dynamic>? seenBody;
        final client = http_testing.MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.toString(), tavilySearchUrl);
          seenAuth = request.headers['Authorization'];
          seenBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'answer': 'Use package:http for requests.',
              'results': [
                {
                  'title': 'http | Dart Package',
                  'url': 'https://pub.dev/packages/http',
                  'content': 'A composable HTTP API.',
                },
              ],
              'request_id': 'req-1',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        });

        const provider = TavilySearchProvider();
        final response = await provider.search(
          _request(
            client,
            secrets: const {'TAVILY_API_KEY': 'tvly-key'},
            count: 7,
          ),
        );

        expect(seenAuth, 'Bearer tvly-key');
        expect(seenBody, {
          'query': 'dart http',
          'search_depth': 'basic',
          'max_results': 7,
          'include_answer': 'advanced',
          'include_raw_content': false,
        });

        expect(response.provider, 'tavily');
        expect(response.answer, 'Use package:http for requests.');
        expect(response.sources.single.title, 'http | Dart Package');
        expect(response.sources.single.snippet, 'A composable HTTP API.');
      },
    );

    test('throws a status-tagged error on API failure', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response('{"detail": "Unauthorized"}', 403),
      );
      const provider = TavilySearchProvider();
      await expectLater(
        provider.search(
          _request(client, secrets: const {'TAVILY_API_KEY': 'tvly-key'}),
        ),
        throwsA(
          isA<WebSearchException>()
              .having((e) => e.provider, 'provider', 'tavily')
              .having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
    });
  });

  group('clampWebSearchCount', () {
    test('defaults, floors, and caps', () {
      expect(clampWebSearchCount(null), defaultWebSearchCount);
      expect(clampWebSearchCount(0), defaultWebSearchCount);
      expect(clampWebSearchCount(-3), defaultWebSearchCount);
      expect(clampWebSearchCount(5), 5);
      expect(clampWebSearchCount(99), maxWebSearchCount);
    });
  });
}
