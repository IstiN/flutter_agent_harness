/// The `web_fetch` tool: fetches a page and returns its content as
/// structured markdown, so `web_search` results compose with page reading.
/// Site-specific handlers ([WebSiteHandler], e.g. pub.dev) run first; other
/// pages go through the generic HTML→markdown converter, which preserves
/// link anchors, headings, lists, and code blocks while stripping
/// navigation/boilerplate (omp's `fetch` tool role, reduced to textual
/// content).
library;

import 'dart:async';

import 'package:http/http.dart' as http;

import '../agent/agent_loop.dart' show ToolExecutionResult;
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import 'fetch_types.dart';
import 'html_markdown.dart';
import 'html_text.dart';
import 'web_search_tool.dart';

/// Creates the `web_fetch` tool, sharing [WebSearchConfig]'s HTTP plumbing.
///
/// Parameters:
/// - `url` (string, required): absolute http(s) URL of the page to fetch.
AgentTool webFetchTool({required WebSearchConfig config}) {
  return AgentTool(
    name: 'web_fetch',
    label: 'web_fetch',
    tier: ApprovalTier.read,
    description:
        'Fetch a web page and return its main content as Markdown: headings, '
        'link anchors, lists, and code blocks are preserved, navigation and '
        'boilerplate are stripped. Known sites (pub.dev) are rendered via '
        'dedicated handlers. Use it to read pages found with web_search.',
    parameters: const {
      'type': 'object',
      'properties': {
        'url': {
          'type': 'string',
          'description': 'The absolute http(s) URL to fetch',
        },
      },
      'required': ['url'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final url = (arguments['url'] as String).trim();
      final uri = Uri.tryParse(url);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        throw StateError(
          'Invalid URL: $url (expected an absolute http(s) URL)',
        );
      }

      final client = config.httpClient ?? http.Client();
      try {
        final context = WebFetchContext(
          client: client,
          timeout: config.timeout,
          maxBytes: config.maxFetchBytes,
        );

        for (final handler in config.effectiveSiteHandlers) {
          cancelToken?.throwIfCancelled();
          final result = await handler.tryFetch(uri, context);
          if (result != null) {
            return ToolExecutionResult.text(
              '${_cap(result.markdown, config.maxFetchChars)}\n\n'
              '[Fetched $url via ${result.method}]',
            );
          }
        }

        final page = await _fetchChecked(context, uri);
        cancelToken?.throwIfCancelled();
        return ToolExecutionResult.text(_renderPage(page, config));
      } finally {
        if (config.httpClient == null) client.close();
      }
    },
  );
}

/// Fetches [uri], converting transport and HTTP failures into tool errors.
Future<WebPage> _fetchChecked(WebFetchContext context, Uri uri) async {
  final WebPage page;
  try {
    page = await context.fetch(uri);
  } on TimeoutException {
    throw StateError('Timed out fetching $uri');
  } on http.ClientException catch (error) {
    throw StateError('Failed to fetch $uri: ${error.message}');
  }
  if (page.statusCode >= 400) {
    throw StateError('Failed to fetch $uri: HTTP ${page.statusCode}');
  }
  return page;
}

/// Renders a fetched page as markdown (or passes text through) with the
/// output cap and fetch notices.
String _renderPage(WebPage page, WebSearchConfig config) {
  final notices = <String>[
    if (page.truncated)
      'page exceeded the ${config.maxFetchBytes}-byte read cap',
  ];

  final String content;
  switch (page.contentType) {
    case '' || 'text/html' || 'application/xhtml+xml':
      final markdown = htmlToMarkdown(page.body, baseUrl: page.finalUrl);
      final title = extractHtmlTitle(page.body);
      content = _prependTitle(markdown, title);
    case 'text/plain' ||
        'text/markdown' ||
        'application/json' ||
        'text/csv' ||
        'application/xml' ||
        'text/xml':
      content = page.body.trim();
    default:
      throw StateError(
        'Unsupported content type "${page.contentType}" at ${page.url} '
        '(only HTML and plain-text content are supported)',
      );
  }

  if (content.isEmpty) {
    return '[No readable content at ${page.url}]';
  }
  var output = _cap(content, config.maxFetchChars, notices);
  if (notices.isNotEmpty) output += '\n\n[${notices.join('. ')}]';
  return output;
}

/// Adds the page `<title>` as an H1 unless the markdown already leads with
/// an equivalent heading.
String _prependTitle(String markdown, String? title) {
  if (title == null || title.isEmpty) return markdown;
  if (markdown.startsWith('# $title')) return markdown;
  return '# $title\n\n$markdown';
}

String _cap(String content, int maxChars, [List<String>? notices]) {
  if (content.length <= maxChars) return content;
  notices?.add('content truncated at $maxChars characters');
  return content.substring(0, maxChars);
}
