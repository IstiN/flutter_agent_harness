// Regenerates the fa1.dev App Store block in site/index.html from the
// `links:` config defaults (issue #691) — the site is static, so the
// single source of truth flows into it as a CI-checked generated block:
// test/site/appstore_block_sync_test.dart fails when the committed
// block is not what [renderAppStoreBlockHtml] emits for the defaults.
//
// Usage (from the repo root):
//   dart run scripts/regen_site_store_block.dart
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show
        LinksConfig,
        appStoreBlockEndMarker,
        appStoreBlockStartMarker,
        renderAppStoreBlockHtml;

void main() {
  final file = File('site/index.html');
  if (!file.existsSync()) {
    stderr.writeln('site/index.html not found — run from the repo root');
    exitCode = 1;
    return;
  }
  final text = file.readAsStringSync();
  final start = text.indexOf(appStoreBlockStartMarker);
  final end = text.indexOf(appStoreBlockEndMarker);
  if (start < 0 || end < start) {
    stderr.writeln(
      'generated-block markers missing in site/index.html — add '
      '"$appStoreBlockStartMarker" … "$appStoreBlockEndMarker" first',
    );
    exitCode = 1;
    return;
  }
  final afterEnd = end + appStoreBlockEndMarker.length;
  final updated = text.replaceRange(
    start,
    afterEnd,
    '$appStoreBlockStartMarker\n'
    '${renderAppStoreBlockHtml(const LinksConfig())}\n'
    '  $appStoreBlockEndMarker',
  );
  if (updated == text) {
    stdout.writeln('site/index.html App Store block already up to date');
    return;
  }
  file.writeAsStringSync(updated);
  stdout.writeln('site/index.html App Store block regenerated');
}
