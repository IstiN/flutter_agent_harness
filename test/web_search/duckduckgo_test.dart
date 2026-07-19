/// Tests for the DuckDuckGo HTML provider: canned-markup parsing (including
/// markup-rot resilience), redirect unwrapping, and bot-challenge detection.
library;

import 'package:flutter_agent_harness/src/web_search/providers.dart';
import 'package:flutter_agent_harness/src/web_search/search_types.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

/// The classic html.duckduckgo.com result page shape (two results, one
/// redirect-wrapped with a snippet, one absolute URL without).
const _classicResultsPage = '''
<!DOCTYPE html>
<html>
<head><title>DuckDuckGo Search</title></head>
<body>
<div id="links" class="results">
  <div class="result results_links results_links_deep web-result">
    <div class="links_main links_deep result__body">
      <h2 class="result__title">
        <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fpub.dev%2Fpackages%2Fhttp&amp;rut=9f86d0">http | Dart <b>Package</b></a>
      </h2>
      <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fpub.dev%2Fpackages%2Fhttp&amp;rut=9f86d0">A composable, multi-platform, <b>Future</b>-based API for HTTP requests &amp; more.</a>
      <div class="result__extras">
        <div class="result__extras__url">
          <a class="result__url" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fpub.dev%2Fpackages%2Fhttp&amp;rut=9f86d0">pub.dev/packages/http</a>
        </div>
      </div>
    </div>
  </div>
  <div class="result results_links results_links_deep web-result">
    <div class="links_main links_deep result__body">
      <h2 class="result__title">
        <a rel="nofollow" class="result__a" href="https://dart.dev/tools/pub/cmd">Pub commands &amp; docs</a>
      </h2>
    </div>
  </div>
  <div class="nav-link">
    <a href="/html/?q=http&amp;s=30">Next</a>
  </div>
</div>
</body>
</html>
''';

/// The same results after simulated markup rot: attribute order swapped,
/// single quotes, extra unknown classes, the snippet moved to a `<div>`,
/// one unwrappable (relative) href, and entity variants.
const _rottenResultsPage = '''
<div class="results">
  <div class='web-result result results_links'>
    <div class="result__body">
      <h2>
        <a href='//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Frotten&amp;rut=1' class='result__a shiny'>Tom &amp; Jerry&#x27;s Guide</a>
      </h2>
      <div class="result__snippet new-style">Entities &lt;decoded&gt; &quot;here&quot;.</div>
    </div>
  </div>
  <div class="result results_links">
    <div class="result__body">
      <h2><a class="result__a" href="/relative/local">Unwrappable href</a></h2>
      <div class="result__snippet">This result must be skipped.</div>
    </div>
  </div>
  <div class="result results_links">
    <div class="result__body">
      <h2><a class="result__a" href="https://example.org/no-snippet">No Snippet Here</a></h2>
    </div>
  </div>
</div>
''';

const _anomalyPage = '''
<html><body>
<div class="anomaly-modal">
  <form class="challenge-form" action="/anomaly.js">Prove you are human</form>
</div>
</body></html>
''';

WebSearchRequest _request(
  http.Client client, {
  String query = 'dart http',
  int count = 10,
}) {
  return WebSearchRequest(
    query: query,
    count: count,
    client: client,
    timeout: const Duration(seconds: 5),
    secrets: const {},
  );
}

void main() {
  group('parseDuckDuckGoResults', () {
    test('parses the classic results page', () {
      final results = parseDuckDuckGoResults(_classicResultsPage);
      expect(results, hasLength(2));

      expect(results[0].title, 'http | Dart Package');
      expect(results[0].url, 'https://pub.dev/packages/http');
      expect(
        results[0].snippet,
        'A composable, multi-platform, Future-based API for HTTP requests & more.',
      );

      expect(results[1].title, 'Pub commands & docs');
      expect(results[1].url, 'https://dart.dev/tools/pub/cmd');
      expect(results[1].snippet, isNull);
    });

    test('survives markup rot', () {
      final results = parseDuckDuckGoResults(_rottenResultsPage);
      expect(results, hasLength(2));

      expect(results[0].title, "Tom & Jerry's Guide");
      expect(results[0].url, 'https://example.com/rotten');
      expect(results[0].snippet, 'Entities <decoded> "here".');

      expect(results[1].title, 'No Snippet Here');
      expect(results[1].url, 'https://example.org/no-snippet');
      expect(results[1].snippet, isNull);
    });

    test('deduplicates URLs and honors the limit', () {
      final duplicated = List.filled(3, _classicResultsPage).join('\n');
      final results = parseDuckDuckGoResults(duplicated, limit: 1);
      expect(results, hasLength(1));
      expect(results.single.url, 'https://pub.dev/packages/http');
    });

    test('returns an empty list when the page has no results', () {
      expect(
        parseDuckDuckGoResults('<html><body>No results.</body></html>'),
        isEmpty,
      );
    });
  });

  group('unwrapDuckDuckGoUrl', () {
    test('unwraps uddg redirect URLs', () {
      expect(
        unwrapDuckDuckGoUrl(
          '//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1&amp;rut=x',
        ),
        'https://example.com/a?b=1',
      );
    });

    test('passes through protocol-relative and absolute URLs', () {
      expect(unwrapDuckDuckGoUrl('//example.com/x'), 'https://example.com/x');
      expect(unwrapDuckDuckGoUrl('http://example.com'), 'http://example.com');
    });

    test('rejects relative and empty hrefs', () {
      expect(unwrapDuckDuckGoUrl('/local/path'), isNull);
      expect(unwrapDuckDuckGoUrl(''), isNull);
    });
  });

  group('isDuckDuckGoAnomalyPage', () {
    test('detects the bot-challenge page', () {
      expect(isDuckDuckGoAnomalyPage(_anomalyPage), isTrue);
      expect(isDuckDuckGoAnomalyPage(_classicResultsPage), isFalse);
    });
  });

  group('DuckDuckGoSearchProvider', () {
    test('is keyless and always available', () {
      const provider = DuckDuckGoSearchProvider();
      expect(provider.apiKeyName, isNull);
      expect(isWebSearchProviderAvailable(provider, const {}), isTrue);
    });

    test('posts the query to the HTML frontend and parses results', () async {
      String? seenContentType;
      Map<String, String>? seenForm;
      final client = http_testing.MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), duckDuckGoHtmlUrl);
        seenContentType = request.headers['content-type'];
        seenForm = Uri.parse('http://x/?${request.body}').queryParameters;
        return http.Response(_classicResultsPage, 200);
      });

      const provider = DuckDuckGoSearchProvider();
      final response = await provider.search(_request(client));

      expect(response.provider, 'duckduckgo');
      expect(response.sources, hasLength(2));
      expect(seenContentType, contains('application/x-www-form-urlencoded'));
      expect(seenForm?['q'], 'dart http');
      expect(seenForm?['kl'], 'us-en');
      expect(seenForm, containsPair('b', ''));
    });

    test('caps the sources at the requested count', () async {
      final page = List.filled(4, _classicResultsPage).join('\n');
      final client = http_testing.MockClient(
        (request) async => http.Response(page, 200),
      );
      const provider = DuckDuckGoSearchProvider();
      // The fixture has two unique results; a count of 1 must cap them.
      final response = await provider.search(_request(client, count: 1));
      expect(response.sources, hasLength(1));
      expect(response.sources.single.url, 'https://pub.dev/packages/http');
    });

    test('throws a 429-tagged error on the anomaly page', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response(_anomalyPage, 202),
      );
      const provider = DuckDuckGoSearchProvider();
      await expectLater(
        provider.search(_request(client)),
        throwsA(
          isA<WebSearchException>()
              .having((e) => e.provider, 'provider', 'duckduckgo')
              .having((e) => e.statusCode, 'statusCode', 429)
              .having((e) => e.message, 'message', contains('bot-detection')),
        ),
      );
    });

    test('throws on non-2xx responses', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response('oops', 500),
      );
      const provider = DuckDuckGoSearchProvider();
      await expectLater(
        provider.search(_request(client)),
        throwsA(
          isA<WebSearchException>()
              .having((e) => e.statusCode, 'statusCode', 500)
              .having((e) => e.message, 'message', contains('500')),
        ),
      );
    });
  });
}
