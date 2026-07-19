/// Site-specific extraction handlers for the `web_fetch` tool (omp's
/// `web/scrapers/` role). v1 ships the [WebSiteHandler] interface plus one
/// handler — [PubDevHandler], our own ecosystem — behind
/// [defaultWebSiteHandlers]; GitHub and arXiv handlers are follow-ups.
library;

import 'dart:convert';

import 'fetch_types.dart';

/// The site handlers tried, in order, before the generic HTML→markdown
/// converter.
List<WebSiteHandler> defaultWebSiteHandlers() => [const PubDevHandler()];

/// Renders pub.dev package pages (`/packages/<name>`) from the pub.dev API
/// instead of scraping the HTML page (ported from omp's
/// `scrapers/pub-dev.ts`): metadata, score metrics, SDK constraints,
/// dependencies, and recent versions as structured markdown.
final class PubDevHandler implements WebSiteHandler {
  /// Creates the handler.
  const PubDevHandler();

  @override
  String get id => 'pub.dev';

  static final _packagePathPattern = RegExp(r'^/packages/([^/]+)');

  @override
  Future<WebFetchResult?> tryFetch(Uri uri, WebFetchContext context) async {
    if (uri.host != 'pub.dev' && uri.host != 'www.pub.dev') return null;
    final match = _packagePathPattern.firstMatch(uri.path);
    if (match == null) return null;
    final packageName = Uri.decodeComponent(match.group(1)!);

    final WebPage packagePage;
    final Object? data;
    try {
      packagePage = await context.fetch(
        Uri.parse('https://pub.dev/api/packages/$packageName'),
      );
      if (!packagePage.ok) return null;
      data = jsonDecode(packagePage.body);
    } on Object {
      return null; // malformed/unreachable API → generic converter fallback
    }
    if (data is! Map) return null;
    final latest = data['latest'];
    if (latest is! Map) return null;

    final score = await _fetchScore(context, packageName);
    final markdown = _render(data, latest, score);
    return WebFetchResult(markdown: markdown, method: id);
  }

  /// Fetches the score metrics (likes/points/popularity). Failure is
  /// tolerated — the package metadata alone is already useful.
  Future<Map<dynamic, dynamic>?> _fetchScore(
    WebFetchContext context,
    String packageName,
  ) async {
    try {
      final page = await context.fetch(
        Uri.parse('https://pub.dev/api/packages/$packageName/metrics'),
      );
      if (!page.ok) return null;
      final data = jsonDecode(page.body);
      if (data is Map && data['score'] is Map) {
        return data['score'] as Map<dynamic, dynamic>;
      }
    } on Object {
      // Score unavailable — render without it.
    }
    return null;
  }

  String _render(
    Map<dynamic, dynamic> data,
    Map<dynamic, dynamic> latest,
    Map<dynamic, dynamic>? score,
  ) {
    final pubspec = latest['pubspec'];
    final spec = pubspec is Map ? pubspec : const <dynamic, dynamic>{};
    final name =
        data['name'] as String? ?? spec['name'] as String? ?? 'package';

    final md = StringBuffer('# $name\n\n');
    final description = spec['description'] as String?;
    if (description != null && description.trim().isNotEmpty) {
      md.write('${description.trim()}\n\n');
    }

    md.write('**Latest:** ${latest['version']}');
    final publisher = data['publisherId'] as String?;
    if (publisher != null && publisher.isNotEmpty) {
      md.write(' · **Publisher:** $publisher');
    }
    md.write('\n');

    final metrics = <String>[
      if (score?['likeCount'] case final int likes)
        '**Likes:** ${_formatCount(likes)}',
      if (score?['grantedPoints'] case final int points)
        '**Pub Points:** $points/${score?['maxPoints'] ?? '?'}',
      if (score?['popularityScore'] case final num popularity)
        '**Popularity:** ${(popularity * 100).round()}%',
      if (score?['downloadCount30Days'] case final int downloads)
        '**Downloads (30d):** ${_formatCount(downloads)}',
    ];
    if (metrics.isNotEmpty) md.write('${metrics.join(' · ')}\n');
    md.write('\n');

    for (final (label, key) in [
      ('Homepage', 'homepage'),
      ('Repository', 'repository'),
      ('Documentation', 'documentation'),
    ]) {
      final value = spec[key] as String?;
      if (value != null && value.isNotEmpty) md.write('**$label:** $value\n');
    }

    final environment = spec['environment'];
    if (environment is Map && environment.isNotEmpty) {
      final constraints = [
        for (final entry in environment.entries)
          if (entry.value != null) '${entry.key}: ${entry.value}',
      ];
      if (constraints.isNotEmpty) {
        md.write('**SDK:** ${constraints.join(', ')}\n');
      }
    }
    md.write('\n');

    final dependencies = spec['dependencies'];
    if (dependencies is Map && dependencies.isNotEmpty) {
      md.write('## Dependencies (${dependencies.length})\n\n');
      const cap = 20;
      var shown = 0;
      for (final entry in dependencies.entries) {
        if (shown >= cap) break;
        final constraint = switch (entry.value) {
          final String value => ': $value',
          final Map _ => ': complex',
          _ => '',
        };
        md.write('- ${entry.key}$constraint\n');
        shown++;
      }
      if (dependencies.length > cap) {
        md.write('\n[…${dependencies.length - cap} dependencies elided…]\n');
      }
      md.write('\n');
    }

    final versions = data['versions'];
    if (versions is List && versions.isNotEmpty) {
      // The API lists versions ascending by publish date; show the newest few.
      final recent = versions.reversed.take(5);
      md.write('## Recent versions\n\n');
      for (final entry in recent) {
        if (entry is! Map) continue;
        final published = _datePrefix(entry['published'] as String?);
        final suffix = published.isEmpty ? '' : ' ($published)';
        md.write('- ${entry['version']}$suffix\n');
      }
    }

    return md.toString().trim();
  }

  /// Extracts a `YYYY-MM-DD` prefix from an ISO timestamp (omp's
  /// `formatIsoDate`, reduced).
  String _datePrefix(String? value) {
    if (value == null) return '';
    return RegExp(r'^\d{4}-\d{2}-\d{2}').firstMatch(value)?.group(0) ?? '';
  }

  /// Formats a count with thousands separators (omp's `formatNumber`).
  String _formatCount(int value) {
    final digits = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}
