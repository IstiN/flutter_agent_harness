// gh-2472 rework — the loc-ceiling belt over the CORE sources, repo-side.
//
// The god-file ceiling (2800 lines, wc -l semantics) for lib/bin is
// enforced by the ROOT `crap4dart.yaml` `gates.loc` inside CI's
// `CRAP + duplication` job — and ONLY there (the pre-commit hook gates
// staged files, which a merge-bot merge never crosses). PR #2475 grew
// lib/src/cli/agent_cli.dart 2798 → 2806 (> 2800) and the ceiling fired
// on the validation dispatch AFTER the review legs had already greened —
// the same slipped-through class gh-2462 closed for flutter_app with
// test/ci_2462_app_loc_ceiling_guard_test.dart.
//
// This belt runs in the CORE suite (CI `test-core` runs on every ci.yml
// dispatch, review legs included) and asserts the ceiling directly: every
// non-generated lib/bin .dart file stays within the `max_lines` pinned in
// crap4dart.yaml (read from the config — single source of truth, the CI
// gate and this belt can never disagree). The checker itself is proven
// against a fixture reproducing the incident shape (2801-line file ⇒
// violation, 2800 ⇒ clean) so a future detector drift fails loudly, not
// silently.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// (max_lines, exclude globs) read from the ROOT crap4dart.yaml — the
/// SAME source the CI `CRAP + duplication` job enforces, so this belt
/// tracks any deliberate config change and flags drift instead of pinning
/// a stale number.
(int, List<String>) locConfig() {
  final doc = loadYaml(File('crap4dart.yaml').readAsStringSync()) as YamlMap;
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
  // `dir/**` / `prefix*` patterns. Translate conservatively (the
  // gh-2462 translation, kept byte-identical so the two belts can never
  // disagree on a path):
  //   **  → any run of characters including '/'
  //   *   → any run of characters excluding '/'
  // `.` is a regex metacharacter and MUST take the escape branch like any
  // other non-glob special char — leaving it literal turns `**.g.dart`
  // into `^.*.g.dart$`, which over-matches hand-written `landing.dart`.
  final escaped = glob.split('').map((c) {
    if (c == '*') return c; // handled below
    if (RegExp(r'[A-Za-z0-9_/-]').hasMatch(c)) return c;
    return '\\$c'; // escape regex metacharacters (incl. `.`)
  }).join();
  final pattern = escaped
      .replaceAll('**', '\u0000')
      .replaceAll('*', '[^/]*')
      .replaceAll('\u0000', '.*');
  return RegExp('^$pattern\$').hasMatch(relPath);
}

/// The loc gate's scan scope: the config's top-level `sources` (relative
/// dirs under the package root — today `[lib, bin]`), so this belt covers
/// exactly what the CI gate covers and never more.
List<Directory> scanRoots() {
  final doc = loadYaml(File('crap4dart.yaml').readAsStringSync()) as YamlMap;
  return [
    for (final s in List<String>.from(doc['sources'] as YamlList)) Directory(s),
  ];
}

/// Files under the config's `sources` dirs that the loc gate scans, i.e.
/// non-generated .dart sources minus the gates.loc exclude globs. Paths
/// stay package-root-relative (`lib/src/…`, `bin/…`) — the same shape the
/// config's exclude globs match against.
List<File> scannableFiles() {
  final (_, exclude) = locConfig();
  final files = <File>[];
  for (final dir in scanRoots()) {
    for (final e in dir.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (exclude.any((g) => _globMatch(e.path, g))) continue;
      files.add(e);
    }
  }
  return files..sort((a, b) => a.path.compareTo(b.path));
}

/// The violation set: (file, lines) over maxLines for a list of files —
/// shared by the tree belt below and the incident fixture. Each file is
/// read exactly once.
List<(String, int)> locViolations(Iterable<File> files, int maxLines) {
  final violations = <(String, int)>[];
  for (final f in files) {
    final lines = lineCount(f.readAsStringSync());
    if (lines > maxLines) violations.add((f.path, lines));
  }
  return violations;
}

void main() {
  group('gh-2472 rework — core loc ceiling (repo-side belt)', () {
    test('config pins the 2800 ceiling with the known exclude set', () {
      final (maxLines, _) = locConfig();
      expect(maxLines, 2800, reason: 'AGENTS.md god-file ceiling');
    });

    test('glob translation escapes regex metacharacters — a `**.g.dart` '
        'exclude never swallows a hand-written `landing.dart`', () {
      // Every regex metacharacter in a glob — `.` included — must be
      // escaped in the translation, or the generated-file exclude would
      // silently over-match hand-written files and this belt would skip
      // files the CI loc gate scans (the silent-miss class gh-2462
      // closed for the app belt).
      expect(
        _globMatch('lib/util/landing.dart', '**.g.dart'),
        isFalse,
        reason: 'landing.dart does not end in a LITERAL `.g.dart`',
      );
      expect(
        _globMatch('lib/util/onboarding.dart', '**.g.dart'),
        isFalse,
        reason: 'onboarding.dart ends in `ing.dart`, not `.g.dart`',
      );
      expect(
        _globMatch('lib/util/prompts.g.dart', '**.g.dart'),
        isTrue,
        reason: 'the generated-file glob still matches its real target',
      );
      expect(
        _globMatch('bin/some_dir/file.freezed.dart', '**.freezed.dart'),
        isTrue,
      );
      expect(_globMatch('lib/util/a.b.dart', '**.dart'), isTrue);
      expect(
        _globMatch(
          'lib/l10n/app_localizations_en.dart',
          '**/l10n/app_localizations*.dart',
        ),
        isTrue,
        reason: 'the gen-l10n exclude keeps matching its real target',
      );
      expect(
        _globMatch(
          'lib/src/l10n/other.dart',
          '**/l10n/app_localizations*.dart',
        ),
        isFalse,
      );
    });

    test('checker catches the #2475 incident shape (2801 > 2800) and passes '
        'the at-ceiling file (2800)', () {
      final (maxLines, _) = locConfig();
      final fixture = Directory.systemTemp.createTempSync('gh-2472-loc-');
      addTearDown(() => fixture.deleteSync(recursive: true));
      // Exactly the offending shape: one line OVER the ceiling…
      final over = File('${fixture.path}/agent_cli_like.dart')
        ..writeAsStringSync(
          '${List.filled(maxLines + 1, '// over').join('\n')}\n',
        );
      // …and one line AT the ceiling (legal — the ceiling, not
      // sub-ceiling).
      final at = File('${fixture.path}/at_ceiling.dart')
        ..writeAsStringSync('${List.filled(maxLines, '// at').join('\n')}\n');
      final violations = locViolations([over, at], maxLines);
      expect(
        violations,
        hasLength(1),
        reason:
            '2801 lines ⇒ the #2475 violation the review legs never '
            'saw (the CRAP job runs after them)',
      );
      expect(violations.single.$1, over.path);
      expect(violations.single.$2, maxLines + 1);
      expect(
        locViolations([at], maxLines),
        isEmpty,
        reason: '2800 = at-ceiling is LEGAL (ceiling, not sub-ceiling)',
      );
    });

    test('every non-generated lib/bin .dart file stays ≤ max_lines', () {
      final (maxLines, _) = locConfig();
      final violations = locViolations(scannableFiles(), maxLines);
      expect(
        violations,
        isEmpty,
        reason:
            'god-file ceiling violated: ${violations.map((v) => '${v.$1} '
                '(${v.$2} > $maxLines)').join(', ')}. Split by concern into '
            'part files per AGENTS.md — never by extracting public API. '
            'PR #2475 landed exactly this class (agent_cli.dart 2806 > '
            '2800) behind the review legs.',
      );
    });
  });
}
