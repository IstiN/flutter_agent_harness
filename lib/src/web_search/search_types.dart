/// Unified types for the `web_search` provider chain, ported from oh-my-pi
/// `packages/coding-agent/src/web/search/types.ts` (reduced to the subset the
/// ported providers produce: sources plus an optional synthesized answer).
library;

/// One ranked search result: title, URL, and an optional snippet.
final class WebSearchSource {
  /// Creates a source.
  const WebSearchSource({required this.title, required this.url, this.snippet});

  /// Result title (falls back to the URL when the provider has none).
  final String title;

  /// Result URL (already unwrapped from redirect trackers).
  final String url;

  /// Preview text, when the provider supplies one.
  final String? snippet;
}

/// One provider's answer to a search query (omp's `SearchResponse`).
final class WebSearchResponse {
  /// Creates a response.
  const WebSearchResponse({
    required this.provider,
    this.answer,
    this.sources = const [],
  });

  /// Id of the provider that produced this response.
  final String provider;

  /// Synthesized answer text (Tavily only; DDG/Brave return sources only).
  final String? answer;

  /// Ranked results, best first.
  final List<WebSearchSource> sources;

  /// Whether there is anything worth showing the model (omp's
  /// `hasRenderableSearchContent`, reduced to the ported fields).
  bool get hasRenderableContent =>
      (answer?.trim().isNotEmpty ?? false) || sources.isNotEmpty;
}

/// A provider failure carrying the originating provider id and, for HTTP
/// failures, the status code (omp's `SearchProviderError`).
final class WebSearchException implements Exception {
  /// Creates an exception.
  const WebSearchException(this.provider, this.message, [this.statusCode]);

  /// Id of the provider that failed.
  final String provider;

  /// Human-readable failure description. Never contains secrets.
  final String message;

  /// HTTP status code when the failure came from a response.
  final int? statusCode;

  @override
  String toString() => '$provider: $message';
}
