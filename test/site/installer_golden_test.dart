// gh-1596 UT-2 — golden drift: every emitted installer is byte-identical
// to a fresh regeneration from its sources. The sources now include the
// LIVE provider catalog (`provider_catalog.dart`), the live approval-mode
// enum and the CLI's offline model presets — so a catalog change without
// `dart run scripts/gen_installers.dart` fails here (AC6's drift hook,
// extended to the data sections).
//
// The renderer is imported as a library: `renderInstallers()` is pure
// (returns the artifact contents, no writes), so the test never mutates
// the working tree.
import 'dart:io';

import 'package:test/test.dart';

import '../../scripts/gen_installers.dart' as gen;

String _repoRoot() {
  var dir = Directory.current;
  while (true) {
    if (Directory('${dir.path}/site').existsSync() &&
        Directory('${dir.path}/scripts').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('run from inside the flutter_agent repo');
    }
    dir = parent;
  }
}

void main() {
  final root = _repoRoot();
  final rendered = gen.renderInstallers();

  test('the renderer covers every generated installer artifact', () {
    expect(rendered.keys.toSet(), {
      'site/install.sh',
      'site/install.ps1',
      'site/install.bat',
      'site/setup.sh',
      'site/setup.ps1',
    });
  });

  for (final artifact in rendered.keys) {
    test('$artifact is byte-identical to a fresh regeneration (UT-2)', () {
      final committed = File('$root/$artifact').readAsStringSync();
      expect(
        committed,
        rendered[artifact],
        reason:
            '$artifact drifted from its sources (template + yaml + '
            'live catalog). Regenerate and commit:\n'
            '  dart run scripts/gen_installers.dart',
      );
    });
    if (artifact.endsWith('.ps1')) {
      // PS 5.1 reads BOM-less scripts in the system ANSI code page and
      // mojibakes the UTF-8 glyphs at parse time — the write-time BOM is
      // part of the artifact (readAsStringSync strips it, so assert bytes).
      test('$artifact keeps its UTF-8 BOM', () {
        final bytes = File('$root/$artifact').readAsBytesSync();
        expect(
          bytes.sublist(0, 3),
          [0xEF, 0xBB, 0xBF],
          reason:
              '$artifact lost its UTF-8 BOM — PS 5.1 would parse the '
              'banner/glyphs through the ANSI code page',
        );
      });
    }
  }
}
