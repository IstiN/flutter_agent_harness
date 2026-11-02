/// Guard: Material-styled UI cannot creep back into `flutter_app/lib`.
///
/// The app UI is built from the fa_ui styleguide (`FaSurface`, `FaButton`,
/// `FaIconButton`, `FaTextField`, `FahColors.of(context)`,
/// `buildFaTheme`/`FaDesignTokens`) — not from raw Material primitives.
/// This guard is a RATCHET over five patterns:
///
/// | section           | catches                                              |
/// |-------------------|------------------------------------------------------|
/// | `icons`           | material icon glyphs (`Icons.add`, ...)              |
/// | `material_colors` | hardcoded Material palette swatches (`Colors.blue`,  |
/// |                   | `Colors.white54`, `Colors.green.shade400`, ...;      |
/// |                   | `Colors.transparent` is exempt — a plain constant,   |
/// |                   | not a style decision)                                |
/// | `material_widgets`| raw Material widgets that have styleguide equivalents|
/// |                   | (buttons → `FaButton`, `IconButton` → `FaIconButton`,|
/// |                   | `TextField` → `FaTextField`)                         |
/// | `material_app`    | `MaterialApp(` outside the app root `lib/main.dart`  |
/// | `theme_data`      | raw `ThemeData(` constructors anywhere in lib (the   |
/// |                   | theme comes from fa_ui's `buildFaTheme`)             |
///
/// How the ratchet works:
/// * `test/ui/styleguide_material_allowlist.txt` pins the MAXIMUM allowed
///   number of matches per lib file, per section.
/// * A match in a file that is not allowlisted, or a count ABOVE its
///   ceiling, FAILS the guard.
/// * A count BELOW its ceiling passes and prints a shrink hint.
///
/// How to SHRINK the ratchet (do this whenever you remove usages):
/// 1. replace the Material usages with styleguide APIs,
/// 2. regenerate the baseline from the repo root:
/// ```sh
/// scripts/check_material_usage.sh \
///   > flutter_app/test/ui/styleguide_material_allowlist.txt
/// ```
/// 3. re-run `flutter test test/ui/styleguide_guard_test.dart`.
///
/// Never raise a ceiling by hand to silence the guard: shrink the real
/// usage first. If a growth is a deliberate, reviewable migration step,
/// regenerate and call the increase out explicitly in the PR.
///
/// NOTE: `scripts/check_material_usage.sh` mirrors these counting rules to
/// (re)generate the baseline; this test is the authority. If you touch the
/// patterns here, update the script in the same change.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Path of the ratchet baseline, relative to the flutter_app package root.
const String allowlistPath = 'test/ui/styleguide_material_allowlist.txt';

/// The app root owns `MaterialApp` and may build the root theme; every
/// other screen must inherit from it.
const String appRoot = 'lib/main.dart';

/// Material palette identifiers (after normalization: trailing digits and
/// `Accent` stripped, e.g. `white54` → `white`, `redAccent` → `red`).
/// `transparent` is deliberately absent (exempt).
const Set<String> _materialSwatches = {
  'amber', 'black', 'blue', 'blueGrey', 'brown', 'cyan', 'deepOrange',
  'deepPurple', 'green', 'grey', 'indigo', 'lightBlue', 'lightGreen',
  'lime', 'orange', 'pink', 'purple', 'red', 'teal', 'violet', 'white',
  'yellow',
};

final RegExp _colorToken = RegExp(r'\bColors\.([A-Za-z_]\w*)\b');

/// Counts hardcoded Material palette swatches in [source].
int countMaterialColorSwatches(String source) {
  var n = 0;
  for (final match in _colorToken.allMatches(source)) {
    var token = match.group(1)!;
    token = token.replaceFirst(RegExp(r'\d+$'), '');
    token = token.replaceFirst(RegExp(r'Accent$'), '');
    if (_materialSwatches.contains(token)) n++;
  }
  return n;
}

/// One ratchet section: a name, a per-file match counter, and a human
/// hint pointing at the styleguide replacement.
class _Section {
  const _Section(
    this.name,
    this.hint, {
    required this.count,
    this.rootExempt = false,
  });

  final String name;
  final String hint;

  /// Number of occurrences of the pattern in [source].
  final int Function(String source) count;

  /// Whether `lib/main.dart` (the app root) is exempt for this section.
  final bool rootExempt;
}

const _sections = <_Section>[
  _Section(
    'icons',
    'use the shared icon helpers / existing styleguide iconography '
    'instead of new material glyphs',
    count: _countIcons,
  ),
  _Section(
    'material_colors',
    'use FahColors.of(context) / FaDesignTokens / theme colorScheme '
    'roles instead of hardcoded Material swatches '
    '(Colors.transparent is exempt)',
    count: countMaterialColorSwatches,
  ),
  _Section(
    'material_widgets',
    'use the fa_ui equivalents instead: FaButton (all button variants), '
    'FaIconButton (IconButton), FaTextField (TextField)',
    count: _countRawMaterialWidgets,
  ),
  _Section(
    'material_app',
    'only lib/main.dart may construct MaterialApp; screens inherit the '
    'root widget',
    count: _countMaterialApp,
    rootExempt: true,
  ),
  _Section(
    'theme_data',
    'the theme comes from fa_ui buildFaTheme/buildFaTheme overrides; '
    'do not inline raw ThemeData( in app code',
    count: _countThemeData,
    rootExempt: true,
  ),
];

int _countIcons(String source) =>
    RegExp(r'\bIcons\.[A-Za-z_]\w*').allMatches(source).length;

int _countRawMaterialWidgets(String source) => RegExp(
  r'\b(?:ElevatedButton|FilledButton|TextButton|OutlinedButton|IconButton'
  r'|TextField)(?:\.[A-Za-z_]\w*)?\s*\(',
).allMatches(source).length;

int _countMaterialApp(String source) =>
    RegExp(r'\bMaterialApp(?:\.[A-Za-z_]\w*)?\s*\(')
        .allMatches(source)
        .length;

int _countThemeData(String source) =>
    RegExp(r'\bThemeData\s*\(').allMatches(source).length;

/// Whether [path] (relative, forward slashes, e.g. `lib/ui/x.dart`)
/// participates in the scan. `lib/l10n/` is generated localizations,
/// `*.g.dart` is generated code.
bool _scanned(String path) =>
    path.endsWith('.dart') &&
    !path.startsWith('lib/l10n/') &&
    !path.endsWith('.g.dart');

/// Current per-file occurrence counts for [section] under [libRoot].
///
/// Keys are always rooted at `lib/...` regardless of where [libRoot]
/// lives, so real scans and self-test fixtures key identically.
Map<String, int> _scanSection(_Section section, String libRoot) {
  final root = libRoot.endsWith('/') ? libRoot.substring(0, libRoot.length - 1) : libRoot;
  final counts = <String, int>{};
  for (final entity in Directory(root).listSync(recursive: true)) {
    if (entity is! File) continue;
    final path = entity.path.replaceAll('\\', '/');
    final key = 'lib/${path.substring(root.length + 1)}';
    if (!_scanned(key)) continue;
    if (section.rootExempt && key == appRoot) continue;
    final n = section.count(entity.readAsStringSync());
    if (n > 0) counts[key] = n;
  }
  return counts;
}

/// Result of comparing current counts against the allowlist ceilings.
class _Diff {
  _Diff(this.violations, this.shrinkHints);

  final List<String> violations;
  final List<String> shrinkHints;
}

_Diff _diffCounts(String sectionName, Map<String, int> current,
    Map<String, int> ceilings,) {
  final violations = <String>[];
  final hints = <String>[];
  for (final entry in current.entries) {
    final ceiling = ceilings[entry.key];
    if (ceiling == null) {
      violations.add(
        '$sectionName: ${entry.key} has NEW usage (${entry.value}x) — '
        'the file is not in the allowlist',
      );
    } else if (entry.value > ceiling) {
      violations.add(
        '$sectionName: ${entry.key} count grew $ceiling → ${entry.value}',
      );
    }
  }
  for (final entry in ceilings.entries) {
    final now = current[entry.key] ?? 0;
    if (now < entry.value) {
      hints.add('$sectionName: ${entry.key} shrank ${entry.value} → $now');
    }
  }
  return _Diff(violations, hints);
}

/// Parses the allowlist format: `# comment`, `[section]` headers, and
/// `<lib path> <max count>` lines.
Map<String, Map<String, int>> parseAllowlist(String content) {
  final sections = <String, Map<String, int>>{};
  String? current;
  for (final rawLine in content.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      current = line.substring(1, line.length - 1);
      sections.putIfAbsent(current, () => <String, int>{});
      continue;
    }
    if (current == null) {
      throw FormatException('allowlist entry before any [section]: $line');
    }
    final parts = line.split(RegExp(r'\s+'));
    final count = int.tryParse(parts.last);
    if (parts.length < 2 || count == null || count < 0 || !parts.first.startsWith('lib/')) {
      throw FormatException('malformed allowlist entry: $line');
    }
    sections[current]![parts.first] = count;
  }
  return sections;
}

Map<String, Map<String, int>> _loadAllowlist() =>
    parseAllowlist(File(allowlistPath).readAsStringSync());

void _emitSummary(String name, Map<String, int> current,
    Map<String, int> ceilings, _Diff diff,) {
  final total = current.values.fold<int>(0, (a, b) => a + b);
  // ignore: avoid_print
  print(
    '[material-ratchet] $name: $total occurrences in ${current.length} '
    'files (allowlist ceiling files: ${ceilings.length})',
  );
  for (final hint in diff.shrinkHints) {
    // ignore: avoid_print
    print('[material-ratchet] shrink available: $hint');
  }
}

String _howToShrink(String name) =>
    'Section "$name" grew beyond the ratchet allowlist. New '
    'Material-styled UI is not allowed in flutter_app/lib. Either revert '
    'to the styleguide, or — after a deliberate cleanup — regenerate the '
    'baseline from the repo root:\n'
    '  scripts/check_material_usage.sh '
    '> flutter_app/test/ui/styleguide_material_allowlist.txt\n'
    'then re-run: flutter test test/ui/styleguide_guard_test.dart';

void main() {
  for (final section in _sections) {
    test('material ratchet: ${section.name} does not grow', () {
      final allowlist = _loadAllowlist();
      final ceilings = allowlist[section.name] ?? const {};
      final current = _scanSection(section, 'lib');
      final diff = _diffCounts(section.name, current, ceilings);
      _emitSummary(section.name, current, ceilings, diff);
      expect(
        diff.violations,
        isEmpty,
        reason:
            '${diff.violations.join('\n')}\n\n${_howToShrink(section.name)}',
      );
    });
  }

  test('allowlist is well-formed and points at scanned lib files', () {
    final file = File(allowlistPath);
    expect(file.existsSync(), isTrue, reason: 'missing ratchet baseline');
    final allowlist = parseAllowlist(file.readAsStringSync());
    expect(
      allowlist.keys,
      containsAll(_sections.map((s) => s.name)),
      reason:
          'every section header must exist even when empty — regenerate '
          'with scripts/check_material_usage.sh',
    );
    final problems = <String>[];
    for (final section in _sections) {
      for (final path in allowlist[section.name]?.keys ?? const <String>[]) {
        if (!File(path).existsSync()) {
          problems.add('${section.name}: $path does not exist — remove '
              'the stale entry (regenerate the allowlist)');
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  group('detector self-test (the guard demonstrably catches violations)', () {
    test('patterns count material primitives and ignore look-alikes', () {
      // icons
      expect(_countIcons('Icon(Icons.add)'), 1);
      expect(_countIcons('a ? Icons.check : Icons.close'), 2);
      expect(_countIcons('FahIcons.plus'), 0); // not the material Icons
      // material_colors
      expect(countMaterialColorSwatches('color: Colors.blue'), 1);
      expect(countMaterialColorSwatches('Colors.green.shade400'), 1);
      expect(countMaterialColorSwatches('Colors.white54'), 1);
      expect(countMaterialColorSwatches('Colors.redAccent'), 1);
      expect(countMaterialColorSwatches('FahColors.of(context)'), 0);
      expect(countMaterialColorSwatches('Colors.transparent'), 0);
      // material_widgets
      expect(_countRawMaterialWidgets('TextButton.icon('), 1);
      expect(_countRawMaterialWidgets('const IconButton('), 1);
      expect(_countRawMaterialWidgets('FaButton('), 0);
      expect(_countRawMaterialWidgets('CupertinoTextField('), 0);
      // material_app / theme_data
      expect(_countMaterialApp('return MaterialApp('), 1);
      expect(_countMaterialApp('MaterialApp.router('), 1);
      expect(_countThemeData('ThemeData('), 1);
      expect(_countThemeData('required ThemeData theme,'), 0);
    });

    test('the scan+diff pipeline flags new and grown usage end-to-end',
        () {
      final tmp = Directory.systemTemp.createTempSync('material_guard');
      try {
        final lib = Directory('${tmp.path}/lib')..createSync();
        Directory('${tmp.path}/lib/l10n')
          ..createSync()
          ..existsSync();
        File('${lib.path}/good.dart')
            .writeAsStringSync('// clean, styleguide-only\n');
        File('${lib.path}/okay.dart')
            .writeAsStringSync('Icon(Icons.add);\n');
        File('${lib.path}/bad_new.dart').writeAsStringSync(
          'Icon(Icons.delete);\ncolor: Colors.red;\nTextButton(\n',
        );
        File('${lib.path}/main.dart')
            .writeAsStringSync('return MaterialApp(\n  ThemeData(\n');
        File('${tmp.path}/lib/l10n/generated.dart')
            .writeAsStringSync('Icon(Icons.abc);\ncolor: Colors.blue;\n');

        final icons = _sections.firstWhere((s) => s.name == 'icons');
        final colors = _sections.firstWhere((s) => s.name == 'material_colors');
        final widgets =
            _sections.firstWhere((s) => s.name == 'material_widgets');
        final materialApp =
            _sections.firstWhere((s) => s.name == 'material_app');
        final themeData = _sections.firstWhere((s) => s.name == 'theme_data');

        final okayCeilings = {'lib/okay.dart': 1};
        final grownDiff =
            _diffCounts('icons', _scanSection(icons, lib.path), {
          'lib/okay.dart': 1,
        });
        expect(
          grownDiff.violations,
          containsAll([
            'icons: lib/bad_new.dart has NEW usage (1x) — the file is '
                'not in the allowlist',
          ]),
          reason: 'a file with Icons. usage but no allowlist entry must '
              'be reported',
        );
        expect(
          grownDiff.violations,
          isNot(contains(contains('lib/okay.dart'))),
          reason: 'counts at the ceiling must pass',
        );
        expect(
          grownDiff.shrinkHints,
          isEmpty,
          reason: 'okay.dart is exactly at its ceiling — nothing to shrink',
        );

        // A lowered current count produces a shrink hint, not a failure.
        final shrinkDiff = _diffCounts('icons', {
          'lib/okay.dart': 1,
        }, {
          'lib/okay.dart': 2,
        });
        expect(shrinkDiff.violations, isEmpty);
        expect(shrinkDiff.shrinkHints.single,
            contains('lib/okay.dart shrank 2 → 1'));

        // Growth within an allowlisted file fails.
        final grewDiff = _diffCounts('icons', {
          'lib/okay.dart': 3,
        }, okayCeilings);
        expect(grewDiff.violations.single,
            'icons: lib/okay.dart count grew 1 → 3');

        // The app root and generated files are exempt where designed.
        expect(
          _scanSection(materialApp, lib.path),
          isEmpty,
          reason: 'main.dart MaterialApp( is exempt (app root)',
        );
        expect(
          _scanSection(themeData, lib.path),
          isEmpty,
          reason: 'main.dart ThemeData( is exempt (app root)',
        );
        expect(
          _scanSection(icons, lib.path).keys,
          isNot(contains('lib/l10n/generated.dart')),
          reason: 'lib/l10n is generated and skipped',
        );
        expect(
          _scanSection(colors, lib.path).keys,
          isNot(contains('lib/l10n/generated.dart')),
        );
        expect(
          _scanSection(widgets, lib.path),
          containsPair('lib/bad_new.dart', 1),
        );
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
}
