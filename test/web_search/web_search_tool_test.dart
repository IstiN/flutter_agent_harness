/// Tests for the `web_search` tool: chain resolution (auto order, key
/// gating, unknown ids), fall-through on provider failure, the all-fail and
/// no-results endings, the `count`/`site` params, secret hygiene, and
/// registration through [builtinTools].
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

const _ddgPage = '''
<div class="results">
  <div class="result results_links results_links_deep web-result">
    <div class="links_main links_deep result__body">
      <h2 class="result__title">
        <a class="result__a" href="https://pub.dev/packages/http">http | Dart Package</a>
      </h2>
      <a class="result__snippet" href="https://pub.dev/packages/http">A composable HTTP API.</a>
    </div>
  </div>
</div>
''';

String _braveJson(String title) => jsonEncode({
  'web': {
    'results': [
      {'title': title, 'url': 'https://example.com/1', 'description': 'one'},
      {'title': 'Two', 'url': 'https://example.com/2', 'description': 'two'},
    ],
  },
});

/// Routes requests by host and records the call order.
http.Client _chainClient(
  Map<String, http.Response Function(http.Request)> routes, {
  List<String>? calls,
}) {
  return http_testing.MockClient((request) async {
    calls?.add(request.url.host);
    final route = routes[request.url.host];
    if (route == null) return http.Response('not found', 404);
    return route(request);
  });
}

String _textOf(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join();

void main() {
  group('resolveWebSearchChain', () {
    test('auto order is keyless DuckDuckGo first, keyed providers after', () {
      final chain = resolveWebSearchChain(
        const ['auto'],
        secrets: const {'BRAVE_API_KEY': 'k', 'TAVILY_API_KEY': 't'},
      );
      expect(chain.map((p) => p.id), ['duckduckgo', 'brave', 'tavily']);
    });

    test('keyed providers drop out when their key is absent', () {
      final chain = resolveWebSearchChain(const ['auto'], secrets: const {});
      expect(chain.map((p) => p.id), ['duckduckgo']);
    });

    test('explicit provider lists are honored and deduplicated', () {
      final chain = resolveWebSearchChain(
        const ['brave', 'duckduckgo', 'brave'],
        secrets: const {'BRAVE_API_KEY': 'k'},
      );
      expect(chain.map((p) => p.id), ['brave', 'duckduckgo']);
    });

    test('an explicit keyed provider without a key resolves empty', () {
      final chain = resolveWebSearchChain(const ['brave'], secrets: const {});
      expect(chain, isEmpty);
    });

    test('unknown provider ids throw', () {
      expect(
        () => resolveWebSearchChain(const ['google'], secrets: const {}),
        throwsStateError,
      );
    });
  });

  group('webSearchTool', () {
    test('returns ranked DDG results with citation markers', () async {
      final tool = webSearchTool(
        config: WebSearchConfig(
          httpClient: _chainClient({
            'html.duckduckgo.com': (_) => http.Response(_ddgPage, 200),
          }),
        ),
      );
      final result = await tool.execute({'query': 'dart http'}, null, null);
      final text = _textOf(result);
      expect(text, contains('[1] http | Dart Package'));
      expect(text, contains('https://pub.dev/packages/http'));
      expect(text, contains('A composable HTTP API.'));
    });

    test('falls through to the next provider on failure', () async {
      final calls = <String>[];
      final tool = webSearchTool(
        config: WebSearchConfig(
          secrets: InMemorySecretsStore({'BRAVE_API_KEY': 'brave-key'}),
          httpClient: _chainClient({
            'html.duckduckgo.com': (_) => http.Response('boom', 500),
            'api.search.brave.com': (_) =>
                http.Response(_braveJson('Brave One'), 200),
          }, calls: calls),
        ),
      );
      final result = await tool.execute({'query': 'dart'}, null, null);
      expect(calls, ['html.duckduckgo.com', 'api.search.brave.com']);
      final text = _textOf(result);
      expect(text, contains('[1] Brave One'));
      expect(text, contains('[2] Two'));
    });

    test('falls through on the DDG anomaly page', () async {
      final calls = <String>[];
      final tool = webSearchTool(
        config: WebSearchConfig(
          secrets: InMemorySecretsStore({'BRAVE_API_KEY': 'brave-key'}),
          httpClient: _chainClient({
            'html.duckduckgo.com': (_) =>
                http.Response('<div class="anomaly-modal">x</div>', 202),
            'api.search.brave.com': (_) =>
                http.Response(_braveJson('Brave One'), 200),
          }, calls: calls),
        ),
      );
      final result = await tool.execute({'query': 'dart'}, null, null);
      expect(calls, ['html.duckduckgo.com', 'api.search.brave.com']);
      expect(_textOf(result), contains('[1] Brave One'));
    });

    test('all-fail reports every provider error', () async {
      final tool = webSearchTool(
        config: WebSearchConfig(
          secrets: InMemorySecretsStore({'BRAVE_API_KEY': 'brave-key'}),
          httpClient: _chainClient({
            'html.duckduckgo.com': (_) => http.Response('boom', 500),
            'api.search.brave.com': (_) => http.Response('bad key', 401),
          }),
        ),
      );
      await expectLater(
        tool.execute({'query': 'dart'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf([
              contains('All web search providers failed'),
              contains('duckduckgo'),
              contains('brave'),
            ]),
          ),
        ),
      );
    });

    test('single-provider all-fail reports that provider error', () async {
      final tool = webSearchTool(
        config: WebSearchConfig(
          providers: const ['duckduckgo'],
          httpClient: _chainClient({
            'html.duckduckgo.com': (_) => http.Response('boom', 500),
          }),
        ),
      );
      await expectLater(
        tool.execute({'query': 'dart'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf([contains('Web search failed'), contains('duckduckgo')]),
          ),
        ),
      );
    });

    test('no-key chain only calls DuckDuckGo', () async {
      final calls = <String>[];
      final tool = webSearchTool(
        config: WebSearchConfig(
          httpClient: _chainClient({
            'html.duckduckgo.com': (_) => http.Response(_ddgPage, 200),
          }, calls: calls),
        ),
      );
      await tool.execute({'query': 'dart'}, null, null);
      expect(calls, ['html.duckduckgo.com']);
    });

    test('unconfigured chain fails with guidance', () async {
      final tool = webSearchTool(
        config: WebSearchConfig(providers: const ['brave']),
      );
      await expectLater(
        tool.execute({'query': 'dart'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('No web search provider configured'),
          ),
        ),
      );
    });

    test('empty provider responses yield a no-results answer', () async {
      final tool = webSearchTool(
        config: WebSearchConfig(
          httpClient: _chainClient({
            'html.duckduckgo.com': (_) =>
                http.Response('<html><body>Nothing.</body></html>', 200),
          }),
        ),
      );
      final result = await tool.execute({'query': 'obscure thing'}, null, null);
      expect(_textOf(result), contains('No results found for: obscure thing'));
    });

    test('count caps the returned results', () async {
      final tool = webSearchTool(
        config: WebSearchConfig(
          secrets: InMemorySecretsStore({'BRAVE_API_KEY': 'brave-key'}),
          httpClient: _chainClient({
            'html.duckduckgo.com': (_) => http.Response('boom', 500),
            'api.search.brave.com': (_) =>
                http.Response(_braveJson('Brave One'), 200),
          }),
        ),
      );
      final result = await tool.execute(
        {'query': 'dart', 'count': 1},
        null,
        null,
      );
      final text = _textOf(result);
      expect(text, contains('[1] Brave One'));
      expect(text, isNot(contains('[2]')));
    });

    test('site appends a site: filter to the provider query', () async {
      String? seenQuery;
      final tool = webSearchTool(
        config: WebSearchConfig(
          httpClient: _chainClient({
            'html.duckduckgo.com': (request) {
              seenQuery = Uri.parse(
                'http://x/?${request.body}',
              ).queryParameters['q'];
              return http.Response(_ddgPage, 200);
            },
          }),
        ),
      );
      await tool.execute({'query': 'http', 'site': 'pub.dev'}, null, null);
      expect(seenQuery, 'http site:pub.dev');
    });

    test('empty query is rejected', () async {
      final tool = webSearchTool(config: WebSearchConfig());
      await expectLater(
        tool.execute({'query': '   '}, null, null),
        throwsStateError,
      );
    });

    test('secrets never leak into the output', () async {
      const key = 'brave-super-secret-key';
      final tool = webSearchTool(
        config: WebSearchConfig(
          secrets: InMemorySecretsStore({'BRAVE_API_KEY': key}),
          httpClient: _chainClient({
            'html.duckduckgo.com': (_) => http.Response('boom', 500),
            'api.search.brave.com': (_) =>
                http.Response(_braveJson('Brave One'), 200),
          }),
        ),
      );
      final result = await tool.execute({'query': 'dart'}, null, null);
      expect(_textOf(result), isNot(contains(key)));
    });

    test('renders the Tavily answer above a Sources section', () async {
      final tool = webSearchTool(
        config: WebSearchConfig(
          providers: const ['tavily'],
          secrets: InMemorySecretsStore({'TAVILY_API_KEY': 'tvly'}),
          httpClient: _chainClient({
            'api.tavily.com': (_) => http.Response(
              jsonEncode({
                'answer': 'package:http is the answer.',
                'results': [
                  {
                    'title': 'http',
                    'url': 'https://pub.dev/packages/http',
                    'content': 'snippet',
                  },
                ],
              }),
              200,
            ),
          }),
        ),
      );
      final text = _textOf(await tool.execute({'query': 'dart'}, null, null));
      expect(text, startsWith('package:http is the answer.'));
      expect(text, contains('## Sources'));
      expect(text, contains('[1] http'));
    });
  });

  group('formatWebSearchResults', () {
    test('omits the Sources header without an answer', () {
      const response = WebSearchResponse(
        provider: 'duckduckgo',
        sources: [WebSearchSource(title: 't', url: 'https://x.dev')],
      );
      expect(formatWebSearchResults(response), isNot(contains('## Sources')));
    });

    test('truncates long snippets at 240 chars', () {
      final response = WebSearchResponse(
        provider: 'duckduckgo',
        sources: [
          WebSearchSource(title: 't', url: 'https://x.dev', snippet: 'a' * 300),
        ],
      );
      final text = formatWebSearchResults(response);
      expect(text, contains('${'a' * 239}…'));
      expect(text, isNot(contains('a' * 240)));
    });
  });

  group('builtinTools registration', () {
    test('web tools are absent without a config', () {
      final names = builtinTools(MemoryExecutionEnv()).map((t) => t.name);
      expect(names, isNot(contains('web_search')));
      expect(names, isNot(contains('web_fetch')));
    });

    test('web tools register behind the config', () {
      final names = builtinTools(
        MemoryExecutionEnv(),
        webSearch: WebSearchConfig(),
      ).map((t) => t.name);
      expect(names, containsAll(['web_search', 'web_fetch']));
    });

    test('web tools are read-tier for the approval gate', () {
      final tools = builtinTools(
        MemoryExecutionEnv(),
        webSearch: WebSearchConfig(),
      );
      for (final tool in tools.where(
        (t) => t.name == 'web_search' || t.name == 'web_fetch',
      )) {
        expect(tool.tier, ApprovalTier.read);
      }
    });
  });
}
