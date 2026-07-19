/// Tests for the `web_fetch` tool: generic HTML → markdown conversion,
/// plain-text passthrough, error surfacing (invalid URL, HTTP failure,
/// unsupported content type), truncation, and site-handler routing.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

String _textOf(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join();

http.Client _client(Map<String, http.Response Function(http.Request)> routes) {
  return http_testing.MockClient((request) async {
    final key = '${request.url.host}${request.url.path}';
    final route = routes[key] ?? routes[request.url.host];
    if (route == null) return http.Response('not found', 404);
    return route(request);
  });
}

const _articlePage = '''
<!DOCTYPE html>
<html>
<head><title>Great Article</title><style>body{}</style></head>
<body>
<nav><a href="/">Home</a></nav>
<article>
<h1>Great Article</h1>
<p>First paragraph with <a href="/other">a link</a>.</p>
<pre><code class="language-dart">void main() {}</code></pre>
</article>
<footer>legal</footer>
</body>
</html>
''';

void main() {
  group('webFetchTool', () {
    test('converts an HTML page to markdown with the title as H1', () async {
      final tool = webFetchTool(
        config: WebSearchConfig(
          httpClient: _client({
            'example.com': (_) => http.Response(
              _articlePage,
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            ),
          }),
        ),
      );
      final result = await tool.execute(
        {'url': 'https://example.com/article'},
        null,
        null,
      );
      final text = _textOf(result);
      // The <title> is not duplicated: the article's own H1 already leads.
      expect(text, startsWith('# Great Article'));
      expect(
        text,
        contains('First paragraph with [a link](https://example.com/other).'),
      );
      expect(text, contains('```dart\nvoid main() {}\n```'));
      expect(text, isNot(contains('Home')));
      expect(text, isNot(contains('legal')));
    });

    test('prepends the <title> when the content lacks it', () async {
      final tool = webFetchTool(
        config: WebSearchConfig(
          httpClient: _client({
            'example.com': (_) => http.Response(
              '<html><head><title>Doc Title</title></head>'
              '<body><p>Body text.</p></body></html>',
              200,
              headers: {'content-type': 'text/html'},
            ),
          }),
        ),
      );
      final text = _textOf(
        await tool.execute({'url': 'https://example.com/'}, null, null),
      );
      expect(text, startsWith('# Doc Title\n\nBody text.'));
    });

    test('passes plain text and JSON through', () async {
      final tool = webFetchTool(
        config: WebSearchConfig(
          httpClient: _client({
            'example.com/notes.txt': (_) => http.Response(
              'plain notes',
              200,
              headers: {'content-type': 'text/plain'},
            ),
            'example.com/data.json': (_) => http.Response(
              '{"a": 1}',
              200,
              headers: {'content-type': 'application/json'},
            ),
          }),
        ),
      );
      expect(
        _textOf(
          await tool.execute(
            {'url': 'https://example.com/notes.txt'},
            null,
            null,
          ),
        ),
        'plain notes',
      );
      expect(
        _textOf(
          await tool.execute(
            {'url': 'https://example.com/data.json'},
            null,
            null,
          ),
        ),
        '{"a": 1}',
      );
    });

    test('rejects invalid URLs', () async {
      final tool = webFetchTool(config: WebSearchConfig());
      await expectLater(
        tool.execute({'url': 'not a url'}, null, null),
        throwsStateError,
      );
      await expectLater(
        tool.execute({'url': 'ftp://example.com/x'}, null, null),
        throwsStateError,
      );
    });

    test('surfaces HTTP failures', () async {
      final tool = webFetchTool(
        config: WebSearchConfig(
          httpClient: _client({
            'example.com': (_) => http.Response('gone', 404),
          }),
        ),
      );
      await expectLater(
        tool.execute({'url': 'https://example.com/missing'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('HTTP 404'),
          ),
        ),
      );
    });

    test('rejects unsupported content types', () async {
      final tool = webFetchTool(
        config: WebSearchConfig(
          httpClient: _client({
            'example.com': (_) => http.Response(
              '%PDF-1.4',
              200,
              headers: {'content-type': 'application/pdf'},
            ),
          }),
        ),
      );
      await expectLater(
        tool.execute({'url': 'https://example.com/doc.pdf'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Unsupported content type'),
          ),
        ),
      );
    });

    test('truncates oversized content with a notice', () async {
      final tool = webFetchTool(
        config: WebSearchConfig(
          maxFetchChars: 100,
          httpClient: _client({
            'example.com': (_) => http.Response(
              '<p>${'word ' * 100}</p>',
              200,
              headers: {'content-type': 'text/html'},
            ),
          }),
        ),
      );
      final text = _textOf(
        await tool.execute({'url': 'https://example.com/long'}, null, null),
      );
      expect(text.length, lessThan(250));
      expect(text, contains('content truncated at 100 characters'));
    });

    test('routes pub.dev URLs through the site handler', () async {
      final tool = webFetchTool(
        config: WebSearchConfig(
          httpClient: _client({
            'pub.dev/api/packages/http': (_) => http.Response(
              '{"name":"http","latest":{"version":"1.6.0","pubspec":{"description":"HTTP API."}},"versions":[]}',
              200,
              headers: {'content-type': 'application/json'},
            ),
            'pub.dev/api/packages/http/metrics': (_) => http.Response('', 404),
          }),
        ),
      );
      final text = _textOf(
        await tool.execute(
          {'url': 'https://pub.dev/packages/http'},
          null,
          null,
        ),
      );
      expect(text, contains('# http'));
      expect(text, contains('**Latest:** 1.6.0'));
      expect(
        text,
        contains('[Fetched https://pub.dev/packages/http via pub.dev]'),
      );
    });

    test(
      'falls back to the generic converter when the handler declines',
      () async {
        final tool = webFetchTool(
          config: WebSearchConfig(
            httpClient: _client({
              'pub.dev/api/packages/broken': (_) => http.Response('', 500),
              'pub.dev/packages/broken': (_) => http.Response(
                '<html><head><title>broken | Dart Package</title></head>'
                '<body><p>Fallback page.</p></body></html>',
                200,
                headers: {'content-type': 'text/html'},
              ),
            }),
          ),
        );
        final text = _textOf(
          await tool.execute(
            {'url': 'https://pub.dev/packages/broken'},
            null,
            null,
          ),
        );
        expect(text, contains('Fallback page.'));
        expect(text, isNot(contains('via pub.dev')));
      },
    );
  });
}
