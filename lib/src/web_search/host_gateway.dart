/// The product-profile host web-tools gateway (gh-2391 addendum 9 item 3):
/// when the profile declares `tools.webSearch.url` / `tools.webFetch.url`,
/// `web_search` and `web_fetch` post to the host's own endpoints with the
/// bridged session key as Bearer — the ONLY provider, no DuckDuckGo/Brave/
/// Tavily chain, no key prompts, and no browser-side fetch at all (CORS
/// made the stock chain unusable inside branded web builds).
///
/// Stock profiles (no host urls) never enter this file.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../agent/agent_loop.dart' show ToolExecutionResult;
import '../cancel_token.dart';
import 'fetch_types.dart';
import 'search_types.dart';
import 'web_fetch_tool.dart' show renderWebPageForHost;
import 'web_search_tool.dart';

/// Runs `web_search` through the host gateway: `POST {query, max_results}`
/// → Perplexity-shaped `{results: [{title, url, snippet, …}]}`.
Future<ToolExecutionResult> executeHostWebSearch(
  WebSearchConfig config, {
  required String query,
  required int count,
  CancelToken? cancelToken,
}) async {
  cancelToken?.throwIfCancelled();
  final response = await _postHostJson(config, config.hostSearchUrl!, {
    'query': query,
    'max_results': count,
  }, cancelToken);
  final results = response['results'];
  if (results is! List) {
    throw StateError('Host web search returned no results array');
  }
  final sources = <WebSearchSource>[
    for (final entry in results)
      if (entry is Map && entry['url'] is String)
        WebSearchSource(
          title: _asString(entry['title'])?.trim().isNotEmpty == true
              ? _asString(entry['title'])!
              : entry['url'] as String,
          url: entry['url'] as String,
          snippet: _asString(entry['snippet']),
        ),
  ];
  final searchResponse = WebSearchResponse(provider: 'host', sources: sources);
  if (!searchResponse.hasRenderableContent) {
    return ToolExecutionResult.text('No results found for: $query');
  }
  return ToolExecutionResult.text(formatWebSearchResults(searchResponse));
}

/// Runs `web_fetch` through the host gateway: `POST {url}` →
/// `{url, content_type, title?, truncated, body}` — the body is RAW
/// HTML/text (server-side SSRF guards, no browser fetch); the stock
/// renderer (HTML→markdown, text passthrough, caps) applies unchanged.
Future<ToolExecutionResult> executeHostWebFetch(
  WebSearchConfig config,
  Uri uri,
  CancelToken? cancelToken,
) async {
  cancelToken?.throwIfCancelled();
  final response = await _postHostJson(config, config.hostFetchUrl!, {
    'url': uri.toString(),
  }, cancelToken);
  final finalUrl = Uri.tryParse(_asString(response['url']) ?? '') ?? uri;
  final page = WebPage(
    url: uri,
    finalUrl: finalUrl,
    statusCode: 200,
    contentType: (_asString(response['content_type']) ?? '')
        .split(';')
        .first
        .trim()
        .toLowerCase(),
    body: _asString(response['body']) ?? '',
    truncated: response['truncated'] == true,
  );
  return ToolExecutionResult.text(renderWebPageForHost(page, config));
}

/// Tolerant string read for host payloads (ai-teammate review): a
/// malformed-but-200 body (`"snippet": 42`) degrades the field instead of
/// crashing the tool with a raw cast TypeError.
String? _asString(Object? value) => value is String ? value : null;

/// One POST to the host endpoint with the live bridged Bearer, decoding
/// the JSON body. Failures surface as ordinary tool errors: 401 reads as
/// an expired session (re-sign-in, never a key prompt), everything else
/// carries the status plus the host's own error message.
Future<Map<String, dynamic>> _postHostJson(
  WebSearchConfig config,
  Uri endpoint,
  Map<String, Object?> payload,
  CancelToken? cancelToken,
) async {
  final base = config.httpClient ?? http.Client();
  final token = config.hostBearerToken?.call() ?? '';
  try {
    final response = await base
        .post(
          endpoint,
          headers: {
            'content-type': 'application/json',
            'accept': 'application/json',
            if (token.isNotEmpty) 'authorization': 'Bearer $token',
          },
          body: jsonEncode(payload),
        )
        .timeout(config.timeout);
    cancelToken?.throwIfCancelled();
    if (response.statusCode == 401) {
      throw StateError(
        'Host session expired (HTTP 401) — sign in again to use web tools',
      );
    }
    if (response.statusCode != 200) {
      throw StateError(
        'Host web tool request failed: HTTP ${response.statusCode} '
        '${_hostErrorMessage(response)}',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Host web tool returned a non-object response');
    }
    return decoded;
  } on TimeoutException {
    throw StateError('Host web tool request timed out: $endpoint');
  } on http.ClientException catch (error) {
    throw StateError('Host web tool request failed: ${error.message}');
  } finally {
    if (config.httpClient == null) base.close();
  }
}

/// The host's own `{"error": …}` / `{"message": …}` text, when present.
String _hostErrorMessage(http.Response response) {
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map) {
      final message = decoded['error'] ?? decoded['message'];
      if (message is String && message.isNotEmpty) return message;
    }
  } on Object {
    // Non-JSON error bodies fall through to the trimmed raw text.
  }
  final text = response.body.trim();
  return text.length <= 200 ? text : text.substring(0, 200);
}
