/// Web search providers for the `web_search` tool, ported from oh-my-pi
/// `packages/coding-agent/src/web/search/providers/`:
///
/// - [DuckDuckGoSearchProvider] — keyless, scrapes DDG's no-JS HTML frontend
///   (`duckduckgo.ts`). omp tried the Instant Answer API first and dropped
///   it: it only answers Wikipedia/Wolfram-Alpha-style topics and returns
///   empty for the vast majority of agent queries.
/// - [BraveSearchProvider] — Brave Search REST API behind `BRAVE_API_KEY`
///   (`brave.ts`).
/// - [TavilySearchProvider] — Tavily search API behind `TAVILY_API_KEY`
///   (`tavily.ts`).
///
/// Deliberate divergences from omp: recency/max_tokens/temperature params
/// are not ported (the ported schema is `{query, count?, site?}`), and
/// availability is data-driven via [WebSearchProvider.apiKeyName] against a
/// secrets map instead of omp's `AuthStorage`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'html_text.dart';
import 'search_types.dart';

/// Default number of results per search (omp's `DEFAULT_NUM_RESULTS`).
const defaultWebSearchCount = 10;

/// Maximum number of results per search (omp's `MAX_NUM_RESULTS`).
const maxWebSearchCount = 20;

/// Clamps a requested result count to `1..[maxWebSearchCount]`, defaulting
/// to [defaultWebSearchCount] (omp's `clampNumResults`).
int clampWebSearchCount(int? count) {
  if (count == null || count <= 0) return defaultWebSearchCount;
  return count > maxWebSearchCount ? maxWebSearchCount : count;
}

/// One search request passed down the provider chain.
final class WebSearchRequest {
  /// Creates a request.
  const WebSearchRequest({
    required this.query,
    required this.count,
    required this.client,
    required this.timeout,
    required this.secrets,
  });

  /// The query text (already site-filter-annotated by the tool).
  final String query;

  /// Result cap, already clamped via [clampWebSearchCount].
  final int count;

  /// HTTP client (injectable; `MockClient` in tests).
  final http.Client client;

  /// Per-request timeout.
  final Duration timeout;

  /// Secrets available to keyed providers (name → value). Never logged.
  final Map<String, String> secrets;
}

/// A search backend the `web_search` tool can walk in its fallback chain.
abstract interface class WebSearchProvider {
  /// Provider id used in config and error messages (e.g. `duckduckgo`).
  String get id;

  /// Human-readable name (e.g. `DuckDuckGo`).
  String get label;

  /// Secret name this provider needs (e.g. `BRAVE_API_KEY`), or null when
  /// it is keyless (DuckDuckGo).
  String? get apiKeyName;

  /// Runs one search. Throws [WebSearchException] on failure so the chain
  /// advances to the next provider.
  Future<WebSearchResponse> search(WebSearchRequest request);
}

/// Whether [provider] can serve searches given [secrets]: keyless providers
/// are always available, keyed ones need their non-empty key.
bool isWebSearchProviderAvailable(
  WebSearchProvider provider,
  Map<String, String> secrets,
) {
  final keyName = provider.apiKeyName;
  if (keyName == null) return true;
  return secrets[keyName]?.isNotEmpty ?? false;
}

/// The default provider set in chain order: keyless DuckDuckGo first, then
/// the keyed providers (filtered by key availability when the chain runs).
final defaultWebSearchProviders = <WebSearchProvider>[
  const DuckDuckGoSearchProvider(),
  const BraveSearchProvider(),
  const TavilySearchProvider(),
];

/// Truncates provider error bodies so a huge HTML error page cannot flood
/// the tool result.
String _truncateErrorBody(String body) {
  const max = 200;
  final collapsed = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  return collapsed.length <= max
      ? collapsed
      : '${collapsed.substring(0, max)}…';
}

/// Runs one provider HTTP call with the request timeout, converting
/// transport failures into [WebSearchException]s so the chain falls through.
Future<http.Response> _send(
  WebSearchProvider provider,
  WebSearchRequest request,
  Future<http.Response> Function() call,
) async {
  try {
    return await call().timeout(request.timeout);
  } on TimeoutException {
    throw WebSearchException(
      provider.id,
      '${provider.label} request timed out',
    );
  } on http.ClientException catch (error) {
    throw WebSearchException(
      provider.id,
      '${provider.label} request failed: ${error.message}',
    );
  }
}

// ---------------------------------------------------------------------------
// DuckDuckGo (keyless HTML frontend)
// ---------------------------------------------------------------------------

/// DuckDuckGo's no-JS HTML search frontend. POST `q=…` to receive a static
/// results page we can parse without a real browser (omp's endpoint choice;
/// see the note on [DuckDuckGoSearchProvider]).
const duckDuckGoHtmlUrl = 'https://html.duckduckgo.com/html/';

/// DuckDuckGo search via the keyless no-JS HTML frontend.
final class DuckDuckGoSearchProvider implements WebSearchProvider {
  /// Creates the provider.
  const DuckDuckGoSearchProvider();

  @override
  String get id => 'duckduckgo';

  @override
  String get label => 'DuckDuckGo';

  @override
  String? get apiKeyName => null;

  @override
  Future<WebSearchResponse> search(WebSearchRequest request) async {
    final body = await _postHtmlSearch(request);
    final parsed = parseDuckDuckGoResults(body, limit: request.count);
    return WebSearchResponse(provider: id, sources: parsed);
  }

  Future<String> _postHtmlSearch(WebSearchRequest request) async {
    final response = await _send(
      this,
      request,
      () => request.client.post(
        Uri.parse(duckDuckGoHtmlUrl),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent': webSearchUserAgent,
          'Referer': 'https://html.duckduckgo.com/',
        },
        body: {
          'q': request.query,
          'kl': 'us-en',
          // Matches a real browser form submission (omp's template).
          'b': '',
        },
      ),
    );

    final body = response.body;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebSearchException(
        id,
        'DuckDuckGo HTML error (${response.statusCode})',
        response.statusCode,
      );
    }
    if (isDuckDuckGoAnomalyPage(body)) {
      throw const WebSearchException(
        'duckduckgo',
        'DuckDuckGo blocked the request with a bot-detection challenge. '
            'Configure a keyed provider (BRAVE_API_KEY, TAVILY_API_KEY) for '
            'reliable web search.',
        429,
      );
    }
    return body;
  }
}

/// Shared browser-profiled user agent for the keyless scrape endpoints.
const webSearchUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// `true` when DDG returned its bot-challenge page instead of results. DDG
/// mixes 200/202 statuses on these, so the body marker is the reliable
/// signal (omp's `isAnomalyResponse`).
bool isDuckDuckGoAnomalyPage(String html) =>
    html.contains('anomaly-modal') || html.contains('anomaly.js');

/// Resolves a DDG result href back to the underlying target URL (omp's
/// `unwrapResultUrl`): DDG routes outbound clicks through
/// `//duckduckgo.com/l/?uddg=<encoded>`; also handles protocol-relative and
/// plain absolute URLs.
String? unwrapDuckDuckGoUrl(String href) {
  if (href.isEmpty) return null;
  final decoded = href.replaceAll('&amp;', '&');
  final wrapped = RegExp(r'[?&]uddg=([^&]+)').firstMatch(decoded);
  if (wrapped != null) {
    try {
      return Uri.decodeComponent(wrapped.group(1)!);
    } on Object {
      return null;
    }
  }
  if (decoded.startsWith('//')) return 'https:$decoded';
  if (decoded.startsWith('http://') || decoded.startsWith('https://')) {
    return decoded;
  }
  return null;
}

/// Walks the DDG results page and pulls out result blocks in document order
/// (omp's `parseHtmlResults`, rebuilt on the forgiving [scanHtml] tokenizer
/// so minor markup rot — attribute order, quote style, extra classes,
/// snippet element variants — does not break parsing).
///
/// Each result lives in a `<div class="… result …">` container with an
/// `<a class="… result__a …">` title link and an optional `result__snippet`
/// element. Sponsored rows, missing snippets, and the pagination row are
/// tolerated; duplicate URLs are dropped.
List<WebSearchSource> parseDuckDuckGoResults(String html, {int? limit}) {
  final tokens = scanHtml(html).toList(growable: false);
  final results = <WebSearchSource>[];
  final seen = <String>{};

  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    if (token is! HtmlTag || token.closing || token.name != 'div') continue;
    if (!token.hasClass('result')) continue;

    final end = _subtreeEnd(tokens, i);
    final source = _parseResultBlock(tokens, i + 1, end);
    if (source != null && seen.add(source.url)) {
      results.add(source);
      if (limit != null && results.length >= limit) return results;
    }
    i = end;
  }
  return results;
}

/// Finds the close-tag index of the subtree rooted at the open tag
/// [openIndex] (see [skipHtmlSubtree]).
int _subtreeEnd(List<Object> tokens, int openIndex) =>
    skipHtmlSubtree(tokens, openIndex);

/// Extracts the title link and snippet from one result block
/// (`tokens[start..end]`, exclusive of the container's own tags).
WebSearchSource? _parseResultBlock(List<Object> tokens, int start, int end) {
  String? url;
  String? title;
  String? snippet;

  for (var i = start; i < end; i++) {
    final token = tokens[i];
    if (token is! HtmlTag || token.closing) continue;

    if (url == null && token.name == 'a' && token.hasClass('result__a')) {
      final textEnd = _subtreeEnd(tokens, i);
      url = unwrapDuckDuckGoUrl(token.attributes['href'] ?? '');
      final text = _collectText(tokens, i + 1, textEnd);
      title = text.isEmpty ? null : text;
      i = textEnd;
      continue;
    }
    if (snippet == null &&
        (token.name == 'a' || token.name == 'div' || token.name == 'span') &&
        token.hasClass('result__snippet')) {
      final textEnd = _subtreeEnd(tokens, i);
      final text = _collectText(tokens, i + 1, textEnd);
      snippet = text.isEmpty ? null : text;
      i = textEnd;
    }
  }

  if (url == null || title == null) return null;
  return WebSearchSource(title: title, url: url, snippet: snippet);
}

/// Concatenates the decoded text of `tokens[start..end]` (markup dropped).
String _collectText(List<Object> tokens, int start, int end) {
  final buffer = StringBuffer();
  for (var i = start; i < end; i++) {
    final token = tokens[i];
    if (token is HtmlText) buffer.write(token.text);
  }
  return stripHtmlTags(buffer.toString());
}

// ---------------------------------------------------------------------------
// Brave Search API (BRAVE_API_KEY)
// ---------------------------------------------------------------------------

/// Brave Search API endpoint (omp's `BRAVE_SEARCH_URL`).
const braveSearchUrl = 'https://api.search.brave.com/res/v1/web/search';

/// Brave web search via the official REST API, keyed by `BRAVE_API_KEY`.
final class BraveSearchProvider implements WebSearchProvider {
  /// Creates the provider.
  const BraveSearchProvider();

  @override
  String get id => 'brave';

  @override
  String get label => 'Brave';

  @override
  String? get apiKeyName => 'BRAVE_API_KEY';

  @override
  Future<WebSearchResponse> search(WebSearchRequest request) async {
    final apiKey = request.secrets[apiKeyName];
    if (apiKey == null || apiKey.isEmpty) {
      throw WebSearchException(id, 'BRAVE_API_KEY not found in secrets');
    }

    final uri = Uri.parse(braveSearchUrl).replace(
      queryParameters: {
        'q': request.query,
        'count': '${request.count}',
        'extra_snippets': 'true',
      },
    );
    final response = await _send(
      this,
      request,
      () => request.client.get(
        uri,
        headers: {'Accept': 'application/json', 'X-Subscription-Token': apiKey},
      ),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebSearchException(
        id,
        'Brave API error (${response.statusCode}): '
        '${_truncateErrorBody(response.body)}',
        response.statusCode,
      );
    }

    final Object? data = jsonDecode(response.body);
    final web = data is Map ? data['web'] : null;
    final results = web is Map ? web['results'] : null;
    final sources = _mapJsonResults(results, request.count, _braveSnippet);
    return WebSearchResponse(provider: id, sources: sources);
  }

  /// Joins the description with any extra snippets (omp's `buildSnippet`).
  String? _braveSnippet(Map<dynamic, dynamic> item) {
    final snippets = <String>[];
    final description = item['description'] as String?;
    if (description != null && description.trim().isNotEmpty) {
      snippets.add(description.trim());
    }
    final extra = item['extra_snippets'];
    if (extra is List) {
      for (final snippet in extra) {
        if (snippet is! String || snippet.trim().isEmpty) continue;
        if (!snippets.contains(snippet.trim())) snippets.add(snippet.trim());
      }
    }
    return snippets.isEmpty ? null : snippets.join('\n');
  }
}

// ---------------------------------------------------------------------------
// Tavily search API (TAVILY_API_KEY)
// ---------------------------------------------------------------------------

/// Tavily search endpoint (omp's `TAVILY_SEARCH_URL`).
const tavilySearchUrl = 'https://api.tavily.com/search';

/// Tavily search via the agent-focused API, keyed by `TAVILY_API_KEY`.
final class TavilySearchProvider implements WebSearchProvider {
  /// Creates the provider.
  const TavilySearchProvider();

  @override
  String get id => 'tavily';

  @override
  String get label => 'Tavily';

  @override
  String? get apiKeyName => 'TAVILY_API_KEY';

  /// Builds the Tavily request body (omp's `buildRequestBody`, reduced: no
  /// recency/topic mapping — `topic` stays at the default general scope).
  static Map<String, dynamic> buildRequestBody(WebSearchRequest request) {
    return {
      'query': request.query,
      'search_depth': 'basic',
      'max_results': request.count,
      'include_answer': 'advanced',
      'include_raw_content': false,
    };
  }

  @override
  Future<WebSearchResponse> search(WebSearchRequest request) async {
    final apiKey = request.secrets[apiKeyName];
    if (apiKey == null || apiKey.isEmpty) {
      throw WebSearchException(id, 'TAVILY_API_KEY not found in secrets');
    }

    final response = await _send(
      this,
      request,
      () => request.client.post(
        Uri.parse(tavilySearchUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode(buildRequestBody(request)),
      ),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebSearchException(
        id,
        'Tavily API error (${response.statusCode}): '
        '${_truncateErrorBody(response.body)}',
        response.statusCode,
      );
    }

    final Object? data = jsonDecode(response.body);
    if (data is! Map) {
      throw WebSearchException(id, 'Tavily returned malformed JSON');
    }
    final answer = data['answer'] as String?;
    final sources = _mapJsonResults(
      data['results'],
      request.count,
      (item) => (item['content'] as String?)?.trim(),
    );
    return WebSearchResponse(
      provider: id,
      answer: answer?.trim().isNotEmpty == true ? answer!.trim() : null,
      sources: sources,
    );
  }
}

/// Maps a JSON result list to sources capped at [count], with [snippetOf]
/// extracting the provider-specific snippet field. Missing titles fall back
/// to the URL (omp's shared source normalization).
List<WebSearchSource> _mapJsonResults(
  Object? results,
  int count,
  String? Function(Map<dynamic, dynamic> item) snippetOf,
) {
  final sources = <WebSearchSource>[];
  if (results is! List) return sources;
  for (final item in results) {
    if (item is! Map) continue;
    final url = item['url'] as String?;
    if (url == null || url.isEmpty) continue;
    final title = item['title'] as String?;
    sources.add(
      WebSearchSource(
        title: title != null && title.trim().isNotEmpty ? title : url,
        url: url,
        snippet: snippetOf(item),
      ),
    );
    if (sources.length >= count) break;
  }
  return sources;
}
