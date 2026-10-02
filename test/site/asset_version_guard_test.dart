// Guard (review gh-881 round 2): every cache-busted reference to a
// shared site asset — `styles.css?v=N`, `main.js?v=N`,
// `analytics.js?v=N` — must carry the SAME version across all pages of
// `site/`. The bump is a manual per-page edit; this fails when a page
// is missed instead of silently serving stale CSS/JS to returning
// visitors (blog/post.html shipped ?v=2 while the rest moved to v=3).
import 'dart:io';

import 'package:test/test.dart';

final _assetVersion =
    RegExp(r'((?:styles\.css|main\.js|analytics\.js)\?v=)(\d+)');

void main() {
  test('every shared-asset version reference in site/ agrees per asset', () {
    final siteRoot = Directory('site');
    expect(siteRoot.existsSync(), isTrue, reason: 'run from the repo root');
    final versions = <String, Set<String>>{};
    for (final file in siteRoot
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.html'))) {
      for (final m in _assetVersion.allMatches(file.readAsStringSync())) {
        versions.putIfAbsent(m.group(1)!, () => {}).add(m.group(2)!);
      }
    }
    expect(versions, isNotEmpty, reason: 'no asset references found');
    for (final entry in versions.entries) {
      expect(entry.value, hasLength(1),
          reason: '${entry.key} is referenced with multiple cache-bust '
              'versions across site/ — bump every page together');
    }
  });
}
