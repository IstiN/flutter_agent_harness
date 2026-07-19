/// Shared plumbing for the `web_fetch` tool and its site handlers: the page
/// loader (timeout + byte cap + redirect-following), the fetched-page type,
/// and the [WebSiteHandler] extraction interface.
///
/// Ported subset of oh-my-pi `packages/coding-agent/src/web/scrapers/
/// types.ts` (`loadPage`, `RenderResult`, `SpecialHandler`), reduced to GET
/// fetching of textual content.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'providers.dart' show webSearchUserAgent;

/// A fetched web page: status, content type, and decoded body.
final class WebPage {
  /// Creates a page.
  const WebPage({
    required this.url,
    required this.finalUrl,
    required this.statusCode,
    required this.contentType,
    required this.body,
    this.truncated = false,
  });

  /// The originally requested URL.
  final Uri url;

  /// The URL after redirects (same as [url] when none).
  final Uri finalUrl;

  /// HTTP status code.
  final int statusCode;

  /// Lowercased MIME type without parameters (empty when unknown).
  final String contentType;

  /// Decoded response body (possibly cut at the byte cap).
  final String body;

  /// Whether [body] was cut mid-stream at the byte cap.
  final bool truncated;

  /// Whether the status is 2xx.
  bool get ok => statusCode >= 200 && statusCode < 300;
}

/// Fetches [uri] with a browser profile, following redirects and capping the
/// body at [maxBytes] (omp's `loadPage`, reduced: no user-agent rotation or
/// 429 retry — the tool surfaces failures directly).
Future<WebPage> loadWebPage(
  http.Client client,
  Uri uri, {
  required Duration timeout,
  required int maxBytes,
  Map<String, String>? headers,
}) async {
  final request = http.Request('GET', uri)
    ..followRedirects = true
    ..maxRedirects = 5
    ..headers.addAll({
      'User-Agent': webSearchUserAgent,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,'
          'text/plain;q=0.8,*/*;q=0.5',
      'Accept-Language': 'en-US,en;q=0.5',
    });
  if (headers != null) request.headers.addAll(headers);

  final response = await client.send(request).timeout(timeout);
  final rawContentType = response.headers['content-type'] ?? '';
  final contentType = rawContentType.split(';').first.trim().toLowerCase();

  final chunks = <int>[];
  var truncated = false;
  await for (final chunk in response.stream.timeout(timeout)) {
    final remaining = maxBytes - chunks.length;
    if (chunk.length > remaining) {
      chunks.addAll(chunk.sublist(0, remaining));
      truncated = true;
      break;
    }
    chunks.addAll(chunk);
  }

  return WebPage(
    url: uri,
    finalUrl: response.request?.url ?? uri,
    statusCode: response.statusCode,
    contentType: contentType,
    body: _decodeBody(chunks, rawContentType),
    truncated: truncated,
  );
}

/// Decodes the body honoring a declared charset, defaulting to UTF-8
/// (tolerating malformed sequences).
String _decodeBody(List<int> bytes, String contentTypeHeader) {
  final charset = RegExp(
    r'charset\s*=\s*"?([\w-]+)"?',
    caseSensitive: false,
  ).firstMatch(contentTypeHeader)?.group(1);
  if (charset != null &&
      (charset.toLowerCase() == 'iso-8859-1' ||
          charset.toLowerCase() == 'latin1')) {
    return latin1.decode(bytes);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// The extraction context handed to [WebSiteHandler]s: shared HTTP plumbing
/// so handlers reuse the tool's client, timeout, and byte cap.
final class WebFetchContext {
  /// Creates a context.
  const WebFetchContext({
    required this.client,
    required this.timeout,
    required this.maxBytes,
  });

  /// Shared HTTP client (injectable; `MockClient` in tests).
  final http.Client client;

  /// Per-request timeout.
  final Duration timeout;

  /// Response body cap in bytes.
  final int maxBytes;

  /// Fetches [uri] through the shared plumbing.
  Future<WebPage> fetch(Uri uri, {Map<String, String>? headers}) => loadWebPage(
    client,
    uri,
    timeout: timeout,
    maxBytes: maxBytes,
    headers: headers,
  );
}

/// One extracted page: structured markdown plus the method that produced it
/// (omp's `RenderResult`, reduced).
final class WebFetchResult {
  /// Creates a result.
  const WebFetchResult({required this.markdown, required this.method});

  /// The page content as structured markdown.
  final String markdown;

  /// Extraction method label (the handler id, e.g. `pub.dev`).
  final String method;
}

/// A site-specific extraction handler (omp's `SpecialHandler`). Handlers
/// are tried in order before the generic HTML→markdown converter; the first
/// non-null result wins.
abstract interface class WebSiteHandler {
  /// Handler id, used as the extraction method label.
  String get id;

  /// Attempts to fetch and render [uri]. Returns null when this handler does
  /// not apply (different site) or extraction fails — the caller then falls
  /// through to the next handler or the generic converter.
  Future<WebFetchResult?> tryFetch(Uri uri, WebFetchContext context);
}
