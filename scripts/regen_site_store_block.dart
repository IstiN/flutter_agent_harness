// Regenerates EVERY generated App Store placement in site/index.html from
// the `links:` config defaults (issues #691 + #881) — the site is static,
// so the single source of truth flows into it as CI-checked generated
// blocks: test/site/appstore_assets_test.dart fails when a committed block
// is not what the renderer emits for the defaults.
//
// Owned placements: header badge, hero CTA, deep block. Any new placement
// must go through here — a hand-edited copy silently rots when links change
// (the hand-edit scan guard in the assets test enforces it for
// apps.apple.com).
//
// Usage (from the repo root):
//   dart run scripts/regen_site_store_block.dart
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

void main() {
  final file = File('site/index.html');
  if (!file.existsSync()) {
    stderr.writeln('site/index.html not found — run from the repo root');
    exitCode = 1;
    return;
  }
  final links = const LinksConfig();
  final placements = [
    (appStoreHeaderStartMarker, appStoreHeaderEndMarker,
        renderAppStoreHeaderBadgeHtml(links)),
    (appStoreHeroStartMarker, appStoreHeroEndMarker,
        renderAppStoreHeroCtaHtml(links)),
    (appStoreBlockStartMarker, appStoreBlockEndMarker,
        renderAppStoreBlockHtml(links)),
  ];
  var text = file.readAsStringSync();
  var changed = false;
  for (final (startMarker, endMarker, rendered) in placements) {
    final start = text.indexOf(startMarker);
    final end = text.indexOf(endMarker);
    if (start < 0 || end < start) {
      stderr.writeln(
        'generated-block markers missing in site/index.html — add '
        '"$startMarker" … "$endMarker" first',
      );
      exitCode = 1;
      return;
    }
    final afterEnd = end + endMarker.length;
    final updated = text.replaceRange(
      start,
      afterEnd,
      '$startMarker\n'
      '$rendered\n'
      '  $endMarker',
    );
    if (updated != text) changed = true;
    text = updated;
  }
  if (!changed) {
    stdout.writeln('site/index.html App Store blocks already up to date');
    return;
  }
  file.writeAsStringSync(text);
  stdout.writeln('site/index.html App Store blocks regenerated');
}
