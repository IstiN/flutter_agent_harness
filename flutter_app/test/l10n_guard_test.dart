// Guardrails that keep the UI free of hardcoded user-visible strings.
//
// 1. No raw string literals in Text widgets or input decoration labels —
//    user-visible copy goes through `context.l10n.*` (lib/l10n/*.arb).
// 2. The en/ru arb files carry identical key sets (nothing untranslated).
// 3. Every `l10n.<key>` referenced in lib/ exists in the arb template
//    (catches typos that would only explode at runtime in a locale we do
//    not exercise in tests).
//
// Opt-outs: a line ending in `// l10n:ignore`, a file starting with
// `// l10n:ignore-file`, and the explicit allowlist below (example URLs and
// other non-prose).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/l10n_ext.dart';

/// Directories that never contain UI copy.
const _skippedDirs = ['lib/l10n/'];

/// Generated files.
const _skippedFiles = ['lib/prompts.g.dart'];

/// `path:line-fragment` pairs we deliberately keep hardcoded.
const _allowlist = <String, List<String>>{
  'lib/settings.dart': ['https://example.com/v1'],
};

final _textPattern = RegExp(
  '''Text\\(\\s*['"]([^'"]*[A-Za-zА-Яа-я][^'"]*)['"]''',
);
final _decorationPattern = RegExp(
  '''(?:labelText|hintText|helperText|counterText|prefixText|suffixText|tooltip)\\s*:\\s*['"]([^'"]*[A-Za-zА-Яа-я][^'"]*)['"]''',
);
final _l10nUsagePattern = RegExp(r'\bl10n\.([a-z][A-Za-z0-9]*)\s*[(\n]');

Iterable<File> _libFiles() sync* {
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = entity.path.replaceAll('\\', '/');
    if (_skippedDirs.any(path.startsWith)) continue;
    if (_skippedFiles.contains(path)) continue;
    yield entity;
  }
}

void main() {
  group('l10n guard', () {
    test('no hardcoded user-visible strings in widgets', () {
      final violations = <String>[];
      for (final file in _libFiles()) {
        final path = file.path.replaceAll('\\', '/');
        final lines = file.readAsLinesSync();
        if (lines.isNotEmpty && lines.first.contains('l10n:ignore-file')) {
          continue;
        }
        final allowed = _allowlist[path] ?? const <String>[];
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.contains('// l10n:ignore')) continue;
          for (final pattern in [_textPattern, _decorationPattern]) {
            for (final match in pattern.allMatches(line)) {
              final literal = match.group(1)!;
              if (allowed.any(literal.contains)) continue;
              violations.add('$path:${i + 1}: ${line.trim()}');
            }
          }
        }
      }
      expect(
        violations,
        isEmpty,
        reason:
            'Hardcoded UI strings found — route them through '
            'context.l10n (lib/l10n/app_en.arb + app_ru.arb):\n'
            '${violations.join('\n')}',
      );
    });

    test('en and ru arb files carry identical key sets', () {
      final en =
          json.decode(File('lib/l10n/app_en.arb').readAsStringSync())
              as Map<String, dynamic>;
      final ru =
          json.decode(File('lib/l10n/app_ru.arb').readAsStringSync())
              as Map<String, dynamic>;
      Set<String> keysOf(Map<String, dynamic> arb) =>
          arb.keys.where((k) => !k.startsWith('@')).toSet();
      final enKeys = keysOf(en);
      final ruKeys = keysOf(ru);
      expect(
        ruKeys.difference(enKeys),
        isEmpty,
        reason: 'keys only in app_ru.arb',
      );
      expect(
        enKeys.difference(ruKeys),
        isEmpty,
        reason: 'keys missing from app_ru.arb (untranslated)',
      );
      // Placeholders must match between locales.
      final placeholder = RegExp(r'\{[a-zA-Z0-9]+\}');
      for (final key in enKeys) {
        if (en[key] is! String || ru[key] is! String) continue;
        final enPh = placeholder
            .allMatches(en[key] as String)
            .map((m) => m[0]!)
            .toSet();
        final ruPh = placeholder
            .allMatches(ru[key] as String)
            .map((m) => m[0]!)
            .toSet();
        expect(ruPh, enPh, reason: 'placeholder mismatch for "$key"');
      }
    });

    test('every l10n key used in lib exists in the arb template', () {
      final en =
          json.decode(File('lib/l10n/app_en.arb').readAsStringSync())
              as Map<String, dynamic>;
      final missing = <String>[];
      for (final file in _libFiles()) {
        final path = file.path.replaceAll('\\', '/');
        final content = file.readAsStringSync();
        for (final match in _l10nUsagePattern.allMatches(content)) {
          final key = match.group(1)!;
          if (!en.containsKey(key)) {
            missing.add('$path: $key');
          }
        }
      }
      expect(
        missing,
        isEmpty,
        reason:
            'l10n keys used but not defined in app_en.arb:\n'
            '${missing.join('\n')}',
      );
    });

    testWidgets('ru locale resolves Russian copy at runtime', (tester) async {
      late String cancel;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              cancel = context.l10n.commonCancel;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(cancel, 'Отмена');
    });

    testWidgets('en locale resolves English copy at runtime', (tester) async {
      late String cancel;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              cancel = context.l10n.commonCancel;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(cancel, 'Cancel');
    });
  });
}
