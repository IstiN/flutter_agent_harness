/// The `web_search` tool: one query through an ordered provider chain —
/// keyless DuckDuckGo first, then keyed providers (Brave, Tavily) whose API
/// key exists in the configured [SecretsStore] — returning ranked results
/// with `[n]` citation markers, titles, URLs, and snippets.
///
/// Ported from oh-my-pi's unified web search tool (`packages/coding-agent/
/// src/web/search/index.ts`), reduced to the three ported providers. The
/// chain order itself is a deliberate divergence: omp walks its long
/// keyed-first order and keeps DuckDuckGo near-last; this port's `auto`
/// chain leads with the keyless provider so the tool works with zero
/// configuration and only burns keyed quota when the free path fails.
library;

import 'dart:async';

import 'package:http/http.dart' as http;

import '../agent/agent_loop.dart' show ToolExecutionResult;
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import '../cancel_token.dart';
import '../secrets/secrets_store.dart';
import 'fetch_types.dart';
import 'providers.dart';
import 'search_types.dart';
import 'site_handlers.dart';

/// Configuration for [webSearchTool] and [webFetchTool].
final class WebSearchConfig {
  /// Creates a configuration. All defaults yield a keyless DuckDuckGo-only
  /// chain; keyed providers join the `auto` chain when their key is present
  /// in [secrets].
  const WebSearchConfig({
    this.providers = const ['auto'],
    this.secrets,
    this.httpClient,
    this.timeout = const Duration(seconds: 20),
    this.maxResults = defaultWebSearchCount,
    this.siteHandlers,
    this.maxFetchBytes = 2 * 1024 * 1024,
    this.maxFetchChars = 50 * 1024,
  });

  /// Ordered provider ids (`duckduckgo`, `brave`, `tavily`) or `auto` for
  /// the default chain. Keyed providers are skipped unless their key is in
  /// [secrets].
  final List<String> providers;

  /// Read-only source of API keys (`BRAVE_API_KEY`, `TAVILY_API_KEY`).
  /// Values never appear in tool output.
  final SecretsStore? secrets;

  /// HTTP client override (tests inject a `MockClient`).
  final http.Client? httpClient;

  /// Per-request timeout for search and fetch calls.
  final Duration timeout;

  /// Default result count when the tool call omits `count`.
  final int maxResults;

  /// Site-specific extraction handlers for `web_fetch`, tried before the
  /// generic HTML→markdown converter. Defaults to
  /// [defaultWebSiteHandlers] (pub.dev).
  final List<WebSiteHandler>? siteHandlers;

  /// Network read cap for `web_fetch` page bodies.
  final int maxFetchBytes;

  /// Output cap for `web_fetch` markdown.
  final int maxFetchChars;

  /// Handlers with the default applied.
  List<WebSiteHandler> get effectiveSiteHandlers =>
      siteHandlers ?? defaultWebSiteHandlers();
}

/// Resolves [providerIds] (`auto` expands to the default chain) into an
/// ordered, deduplicated list of available providers (omp's
/// `resolveProviderCandidates`, reduced). Keyed providers without a key in
/// [secrets] are skipped; unknown ids throw.
List<WebSearchProvider> resolveWebSearchChain(
  List<String> providerIds, {
  required Map<String, String> secrets,
}) {
  final byId = {for (final p in defaultWebSearchProviders) p.id: p};
  final resolved = <WebSearchProvider>[];
  for (final id in providerIds.isEmpty ? const ['auto'] : providerIds) {
    if (id == 'auto') {
      resolved.addAll(defaultWebSearchProviders);
      continue;
    }
    final provider = byId[id];
    if (provider == null) {
      throw StateError(
        'Unknown web search provider: $id '
        '(known: ${byId.keys.join(', ')}, auto)',
      );
    }
    resolved.add(provider);
  }
  final seen = <String>{};
  return [
    for (final provider in resolved)
      if (seen.add(provider.id) &&
          isWebSearchProviderAvailable(provider, secrets))
        provider,
  ];
}

/// Formats a response for the model (omp's `formatForLLM`, reduced to the
/// fields the ported providers produce): the answer first when present,
/// then `[n] title / url / snippet` sources.
String formatWebSearchResults(WebSearchResponse response) {
  final parts = <String>[];
  final answer = response.answer;
  if (answer != null && answer.trim().isNotEmpty) {
    parts.add(answer.trim());
    if (response.sources.isNotEmpty) parts.add('\n## Sources');
  }
  for (var i = 0; i < response.sources.length; i++) {
    final source = response.sources[i];
    parts.add('[${i + 1}] ${source.title}\n    ${source.url}');
    final snippet = source.snippet;
    if (snippet != null && snippet.trim().isNotEmpty) {
      parts.add('    ${_truncate(snippet.trim(), 240)}');
    }
  }
  return parts.join('\n');
}

String _truncate(String text, int maxLength) =>
    text.length <= maxLength ? text : '${text.substring(0, maxLength - 1)}…';

/// Creates the `web_search` tool.
///
/// Parameters:
/// - `query` (string, required): the search query.
/// - `count` (integer, optional): max results (default [WebSearchConfig.maxResults],
///   clamped to 1..20).
/// - `site` (string, optional): restrict results to one domain (appended as
///   a `site:` filter, which all ported providers support).
AgentTool webSearchTool({required WebSearchConfig config}) {
  return AgentTool(
    name: 'web_search',
    label: 'web_search',
    tier: ApprovalTier.read,
    description:
        'Search the web and return ranked results with [n] citation markers, '
        'titles, URLs, and snippets. Runs a provider chain (DuckDuckGo first, '
        'keyed providers when configured) and falls through on failure. '
        'Follow up with web_fetch on a result URL to read the full page.',
    parameters: const {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'The search query'},
        'count': {
          'type': 'integer',
          'description':
              'Maximum number of results to return (default: 10, max: 20)',
        },
        'site': {
          'type': 'string',
          'description':
              "Restrict results to a single domain, e.g. 'pub.dev' "
              '(appended as a site: filter)',
        },
      },
      'required': ['query'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final query = (arguments['query'] as String).trim();
      if (query.isEmpty) throw StateError('query must not be empty');
      final count = clampWebSearchCount(
        (arguments['count'] as num?)?.toInt() ?? config.maxResults,
      );
      final site = (arguments['site'] as String?)?.trim();
      final effectiveQuery = site != null && site.isNotEmpty
          ? '$query site:$site'
          : query;

      final secrets = await config.secrets?.readAll() ?? const {};
      final chain = resolveWebSearchChain(config.providers, secrets: secrets);
      if (chain.isEmpty) {
        throw StateError(
          'No web search provider configured. DuckDuckGo needs no key; set '
          'BRAVE_API_KEY or TAVILY_API_KEY for the keyed providers.',
        );
      }

      final client = config.httpClient ?? http.Client();
      try {
        final request = WebSearchRequest(
          query: effectiveQuery,
          count: count,
          client: client,
          timeout: config.timeout,
          secrets: secrets,
        );
        return await _executeChain(chain, request, query, cancelToken);
      } finally {
        if (config.httpClient == null) client.close();
      }
    },
  );
}

/// Walks the chain sequentially: the first provider with renderable content
/// wins; failures and empty responses fall through (omp's `executeSearch`).
Future<ToolExecutionResult> _executeChain(
  List<WebSearchProvider> chain,
  WebSearchRequest request,
  String displayQuery,
  CancelToken? cancelToken,
) async {
  final errors = <WebSearchException>[];
  var sawEmptyResponse = false;

  for (final provider in chain) {
    cancelToken?.throwIfCancelled();
    try {
      final response = await provider.search(request);
      if (response.hasRenderableContent) {
        return ToolExecutionResult.text(formatWebSearchResults(response));
      }
      // A successful but empty response is held as the "no results" answer
      // while the chain keeps looking (omp treats it as a 204 fall-through).
      sawEmptyResponse = true;
    } on WebSearchException catch (error) {
      errors.add(error);
    } on Object catch (error) {
      errors.add(WebSearchException(provider.id, '$error'));
    }
  }

  if (sawEmptyResponse) {
    var text = 'No results found for: $displayQuery';
    if (errors.isNotEmpty) {
      text += '\n\nSome providers failed: ${errors.join('; ')}';
    }
    return ToolExecutionResult.text(text);
  }

  // All providers failed: report the last error when only one ran, or the
  // full per-provider summary when the chain fell through (omp semantics —
  // strictly more actionable than the last error alone).
  if (errors.length == 1) {
    throw StateError('Web search failed: ${errors.single}');
  }
  throw StateError('All web search providers failed: ${errors.join('; ')}');
}
