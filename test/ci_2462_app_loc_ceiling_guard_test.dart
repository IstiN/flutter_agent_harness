// gh-2462 Defect B — the loc-ceiling belt over flutter_app, repo-side.
//
// The god-file ceiling (2800 lines, wc -l semantics) for flutter_app is
// enforced by `flutter_app/crap4dart.yaml` `gates.loc` inside CI's
// app-crap-gate job — and ONLY there. PR #2438 (fb6543e0796e) grew
// flutter_app/lib/ui/screens/settings.dart 2792 → 2801 and its only
// validation dispatch was cancelled (gh-2462 Defect A), so the gate never
// ran and main carried a real 2801 > 2800 violation (#2457). The gate
// stages in scripts/ci_fast_gate.sh scope loc/crap to lib/bin (core) —
// an app-only commit never crosses a repo-side ceiling check until the
// SM's ci.yml dispatch, i.e. exactly the run a cancel can erase.
//
// This belt runs in the CORE suite (CI `test-core` has NO path gate — it
// executes on every ci.yml dispatch, app-only PRs included) and asserts
// the ceiling directly: every non-generated flutter_app .dart file stays
// within the `max_lines` pinned in flutter_app/crap4dart.yaml (read from
// the config — single source of truth, the CI gate and this belt can
// never disagree). The checker itself is proven against a fixture
// reproducing the incident shape (2801-line file ⇒ violation, 2800 ⇒
// clean) so a future detector drift fails loudly, not silently.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

final appRoot = 'flutter_app';

/// (max_lines, exclude globs) read from flutter_app/crap4dart.yaml — the
/// SAME source the CI app-crap-gate enforces, so this belt tracks any
/// deliberate config change and flags drift instead of pinning a stale
/// number.
(int, List<String>) locConfig() {
  final doc =
      loadYaml(File('$appRoot/crap4dart.yaml').readAsStringSync()) as YamlMap;
  final gates = doc['gates'] as YamlMap;
  final loc = gates['loc'] as YamlMap;
  expect(loc['enabled'], isTrue, reason: 'gates.loc must stay enabled');
  return (
    loc['max_lines'] as int,
    List<String>.from(loc['exclude'] as YamlList),
  );
}

/// wc -l semantics: a trailing incomplete line does not count (the CI loc
/// gate counts the same way — max_lines is a newline count).
int lineCount(String content) => '\n'.allMatches(content).length;

bool _globMatch(String relPath, String glob) {
  // The only glob shapes the config uses: `**.ext` suffix patterns and
  // `dir/**` / `prefix*` patterns. Translate conservatively:
  //   **  → any run of characters including '/'
  //   *   → any run of characters excluding '/'
  final escaped = glob.split('').map((c) {
    if (c == '*') return c; // handled below
    if (RegExp(r'[A-Za-z0-9_/.-]').hasMatch(c)) return c;
    return '\\$c'; // escape regex metacharacters
  }).join();
  final pattern = escaped
      .replaceAll('**', '\u0000')
      .replaceAll('*', '[^/]*')
      .replaceAll('\u0000', '.*');
  return RegExp('^$pattern\$').hasMatch(relPath);
}

/// The loc gate's scan scope: the config's top-level `sources` (relative
/// dirs under flutter_app/ — today `[lib]`), so this belt covers exactly
/// what the CI gate covers and never more.
List<Directory> scanRoots() {
  final doc =
      loadYaml(File('$appRoot/crap4dart.yaml').readAsStringSync()) as YamlMap;
  return [
    for (final s in List<String>.from(doc['sources'] as YamlList))
      Directory('$appRoot/$s'),
  ];
}

/// Files under the config's `sources` dirs that the loc gate scans, i.e.
/// non-generated .dart sources minus the config's exclude globs.
List<File> scannableFiles() {
  final (_, exclude) = locConfig();
  final files = <File>[];
  for (final dir in scanRoots()) {
    for (final e in dir.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final rel = e.path.split('/').skip(1).join('/'); // strip `flutter_app/`
      if (exclude.any((g) => _globMatch(rel, g))) continue;
      files.add(e);
    }
  }
  return files..sort((a, b) => a.path.compareTo(b.path));
}

/// The violation set: (file, lines) over maxLines for a list of absolute
/// file paths — shared by the tree belt below and the incident fixture.
List<(String, int)> locViolations(Iterable<File> files, int maxLines) => [
  for (final f in files)
    if (lineCount(f.readAsStringSync()) > maxLines)
      (f.path, lineCount(f.readAsStringSync())),
];

void main() {
  group('gh-2462 Defect B — flutter_app loc ceiling (repo-side belt)', () {
    test('config pins the 2800 ceiling with the known exclude set', () {
      final (maxLines, _) = locConfig();
      expect(maxLines, 2800, reason: 'AGENTS.md god-file ceiling');
    });

    test('checker catches the #2438 incident shape (2801 > 2800) and passes '
        'the at-ceiling file (2800)', () {
      final (maxLines, _) = locConfig();
      final fixture = Directory.systemTemp.createTempSync('gh-2462-loc-');
      addTearDown(() => fixture.deleteSync(recursive: true));
      // Exactly the offending shape: one line OVER the ceiling…
      final over = File('${fixture.path}/settings_like.dart')
        ..writeAsStringSync(
          '${List.filled(maxLines + 1, '// over').join('\n')}\n',
        );
      // …and one line AT the ceiling (the repaired main-tree state).
      final at = File('${fixture.path}/at_ceiling.dart')
        ..writeAsStringSync('${List.filled(maxLines, '// at').join('\n')}\n');
      final violations = locViolations([over, at], maxLines);
      expect(
        violations,
        hasLength(1),
        reason:
            '2801 lines ⇒ the #2438 '
            'violation the app-crap-gate never got to catch (cancelled run)',
      );
      expect(violations.single.$1, over.path);
      expect(violations.single.$2, maxLines + 1);
      expect(
        locViolations([at], maxLines),
        isEmpty,
        reason: '2800 = at-ceiling is LEGAL (ceiling, not sub-ceiling)',
      );
    });

    test('every non-generated flutter_app .dart file stays ≤ max_lines', () {
      final (maxLines, _) = locConfig();
      final violations = locViolations(scannableFiles(), maxLines);
      expect(
        violations,
        isEmpty,
        reason:
            'god-file ceiling violated: ${violations.map((v) => '${v.$1} '
                '(${v.$2} > $maxLines)').join(', ')}. Split by concern into '
            'part files per AGENTS.md — never by extracting public API. '
            'PR #2438 landed exactly this class (settings.dart 2801 > '
            '2800) because the only gate sat behind the cancelled '
            'validation dispatch (gh-2462).',
      );
    });

    test('settings.dart — the file that broke the ceiling in fb6543e0796e — '
        'is within the limit', () {
      final (maxLines, _) = locConfig();
      final f = File('$appRoot/lib/ui/screens/settings.dart');
      final lines = lineCount(f.readAsStringSync());
      expect(
        lines,
        lessThanOrEqualTo(maxLines),
        reason:
            'the #2457 offending file must stay ≤ $maxLines on main '
            '(was 2801 in fb6543e0796e)',
      );
    });
  });
}
