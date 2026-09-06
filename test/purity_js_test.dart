/// Core purity import guard (REG-C1, issue #30): `lib/` is pure Dart
/// compiled for the web, so NO file under `lib/` may import or export
/// `dart:js_interop`, `dart:js`, or `package:web` — zero exceptions.
///
/// The designated js/web entrypoints all live OUTSIDE `lib/`:
/// `bin/`, `browser_ext/dart/` (agent_main.dart and the src/ chrome/js
/// bindings), and `flutter_app/`.
///
/// `dart:io` keeps its existing surface: `lib/io.dart` is the designated
/// entry point and the only top-level `lib/*.dart` allowed to import it
/// (io-backed implementations under `lib/src/` are reached through that
/// barrel; the dart2js build in scripts/build_browser_ext.sh enforces
/// that the web agent never pulls them in).
///
/// VM-only: walks the source tree on disk.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Matches js/web import/export directives at line start; ignores
/// comment lines (they never start a line with `import`/`export`).
final _jsWebImport = RegExp(
  r"""^(?:import|export)\s+['"](dart:js_interop|dart:js|package:web)""",
  multiLine: true,
);

final _ioImport = RegExp(r"""^import\s+['"]dart:io""", multiLine: true);

void main() {
  test('no js/web imports anywhere under lib/ (REG-C1)', () {
    final offenders = <String>[];
    for (final entry in Directory('lib').listSync(recursive: true)) {
      if (entry is! File || !entry.path.endsWith('.dart')) continue;
      if (_jsWebImport.hasMatch(entry.readAsStringSync())) {
        offenders.add(entry.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'js/web imports belong in bin/, browser_ext/dart/, and '
          'flutter_app/ — never in core lib/',
    );
  });

  test('dart:io imports stay out of top-level lib/ barrels except io.dart', () {
    final offenders = Directory('lib')
        .listSync()
        .whereType<File>()
        .where(
          (file) =>
              file.path.endsWith('.dart') &&
              file.path != 'lib/io.dart' &&
              _ioImport.hasMatch(file.readAsStringSync()),
        )
        .map((file) => file.path)
        .toList();
    expect(
      offenders,
      isEmpty,
      reason: 'lib/io.dart is the designated dart:io entry point',
    );
  });
}
