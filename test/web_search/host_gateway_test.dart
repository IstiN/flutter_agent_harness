/// gh-2391 addendum 9 item 3: the product-profile host web-tools gateway.
/// With `tools.webSearch.url` / `tools.webFetch.url` configured the tools
/// post to the host with the bridged Bearer — the only provider, no chain,
/// no key prompts, no direct browser fetch. Stock configs are untouched.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

const _searchUrl = 'https://api.aiin.by/v1/search/perplexity';
const _fetchUrl = 'https://api.aiin.by/v1/web/fetch';

/// A client that serves ONLY the host gateway; any other request (e.g. a
/// DuckDuckGo fall-through or a direct target fetch) fails the test.
http.Client _hostOnlyClient(
  List<http.Request> log,
  Map<String, http.Response Function(http.Request)> routes,
) {
  return http_testing.MockClient((request) async {
    log.add(request);
    final handler = routes[request.url.toString()];
    if (handler == null) {
      throw StateError('unexpected non-host request: ${request.url}');
    }
    return handler(request);
  });
}

String _textOf(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join();

void main() {
  group('host web_search (gh-2391 addendum 9 item 3)', () {
    test('posts query+count with the bridged Bearer, maps results', () async {
      final log = <http.Request>[];
      final client = _hostOnlyClient(log, {
        _searchUrl: (request) {
          expect(request.method, 'POST');
          expect(request.headers['authorization'], 'Bearer bridged-secret');
          expect(request.headers['content-type'], 'application/json');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['query'], 'dart async');
          expect(body['max_results'], 5);
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'title': 'Dart async',
                  'url': 'https://dart.dev/async',
                  'snippet': 'Asynchronous programming',
                  'date': '2026-01-01',
                  'score': 0.9,
                },
              ],
            }),
            200,
          );
        },
      });
      final tool = webSearchTool(
        config: WebSearchConfig(
          httpClient: client,
          hostSearchUrl: Uri.parse(_searchUrl),
          hostBearerToken: () => 'bridged-secret',
        ),
      );
      final result = await tool.execute(
        {'query': 'dart async', 'count': 5},
        null,
        null,
      );
      expect(log, hasLength(1));
      final text = _textOf(result);
      expect(text, contains('Dart async'));
      expect(text, contains('https://dart.dev/async'));
      expect(text, contains('Asynchronous programming'));
    });

    test('401 reads as an expired session, never a key prompt', () async {
      final log = <http.Request>[];
      final client = _hostOnlyClient(log, {
        _searchUrl: (_) => http.Response('{"error":"unauthorized"}', 401),
      });
      final tool = webSearchTool(
        config: WebSearchConfig(
          httpClient: client,
          hostSearchUrl: Uri.parse(_searchUrl),
          hostBearerToken: () => '',
        ),
      );
      expect(
        () => tool.execute({'query': 'x'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('401'), contains('sign in again')),
          ),
        ),
      );
    });

    test('non-200 surfaces the status and the host error message', () async {
      final client = _hostOnlyClient(<http.Request>[], {
        _searchUrl: (_) => http.Response('{"error":"insufficient balance"}', 402),
      });
      final tool = webSearchTool(
        config: WebSearchConfig(
          httpClient: client,
          hostSearchUrl: Uri.parse(_searchUrl),
        ),
      );
      expect(
        () => tool.execute({'query': 'x'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('402'), contains('insufficient balance')),
          ),
        ),
      );
    });

    test('an empty results array answers no-results (not an error)', () async {
      final client = _hostOnlyClient(<http.Request>[], {
        _searchUrl: (_) => http.Response('{"results": []}', 200),
      });
      final tool = webSearchTool(
        config: WebSearchConfig(
          httpClient: client,
          hostSearchUrl: Uri.parse(_searchUrl),
        ),
      );
      final result = await tool.execute({'query': 'zzz'}, null, null);
      expect(_textOf(result), contains('No results found for: zzz'));
    });
  });

  group('host web_fetch (gh-2391 addendum 9 item 3)', () {
    test('posts the url, converts the raw HTML body client-side', () async {
      final log = <http.Request>[];
      final client = _hostOnlyClient(log, {
        _fetchUrl: (request) {
          expect(request.method, 'POST');
          expect(request.headers['authorization'], 'Bearer bridged-secret');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['url'], 'https://example.com/page');
          return http.Response(
            jsonEncode({
              'url': 'https://example.com/final',
              'content_type': 'text/html',
              'title': 'Ignored - extracted from the body',
              'truncated': false,
              'body':
                  '<html><head><title>Host Page</title></head>'
                  '<body><h2>Section</h2><p>Hello <b>host</b>.</p></body></html>',
            }),
            200,
          );
        },
      });
      final tool = webFetchTool(
        config: WebSearchConfig(
          httpClient: client,
          hostFetchUrl: Uri.parse(_fetchUrl),
          hostBearerToken: () => 'bridged-secret',
        ),
      );
      final result = await tool.execute(
        {'url': 'https://example.com/page'},
        null,
        null,
      );
      expect(log, hasLength(1));
      expect(_textOf(result), contains('Host Page'));
      expect(_textOf(result), contains('Section'));
      expect(_textOf(result), contains('Hello **host**.'));
    });

    test('text-like bodies pass through trimmed', () async {
      final client = _hostOnlyClient(<http.Request>[], {
        _fetchUrl: (_) => http.Response(
          jsonEncode({
            'url': 'https://example.com/notes.txt',
            'content_type': 'text/plain',
            'truncated': false,
            'body': '  plain host text  ',
          }),
          200,
        ),
      });
      final tool = webFetchTool(
        config: WebSearchConfig(
          httpClient: client,
          hostFetchUrl: Uri.parse(_fetchUrl),
        ),
      );
      final result = await tool.execute(
        {'url': 'https://example.com/notes.txt'},
        null,
        null,
      );
      expect(_textOf(result), contains('plain host text'));
    });
  });

  test('withNetworkGate preserves the host fields', () {
    final config = WebSearchConfig(
      hostSearchUrl: Uri.parse(_searchUrl),
      hostFetchUrl: Uri.parse(_fetchUrl),
      hostBearerToken: () => 'k',
    );
    final gated = config.withNetworkGate(null);
    expect(gated.hostSearchUrl, config.hostSearchUrl);
    expect(gated.hostFetchUrl, config.hostFetchUrl);
    expect(gated.hostBearerToken, same(config.hostBearerToken));
  });
}
