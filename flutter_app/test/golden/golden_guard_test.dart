/// Guardrail: every UI widget file in `lib/` has golden (screenshot) test
/// coverage, and the golden test files actually assert against snapshots.
///
/// When you add a widget to `lib/`, this test fails until you:
///  1. write golden tests for it in `test/golden/<area>_golden_test.dart`
///     (see `golden_test_helper.dart`), and
///  2. register the lib file in [_coverage] below (or add it to
///     [_exempt] with a comment explaining why it can never render in a
///     host test).
///
/// Generate/update snapshots with:
/// `flutter test test/golden --update-goldens`
/// — then review every changed PNG by eye before committing; the suite
/// (`flutter test`) compares pixel-by-pixel afterwards.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// lib file (relative to flutter_app/) → golden test file covering it.
const _coverage = <String, String>{
  'lib/main.dart': 'test/golden/setup_golden_test.dart',
  'lib/ui/screens/settings.dart': 'test/golden/settings_golden_test.dart',
  'lib/ui/screens/provider_editor_page.dart':
      'test/golden/settings_golden_test.dart',
  'lib/ui/screens/providers_section.dart':
      'test/golden/settings_golden_test.dart',
  'lib/ui/screens/media_slot_editor_page.dart':
      'test/golden/settings_golden_test.dart',
  'lib/ui/screens/chat_screen.dart': 'test/golden/chat_golden_test.dart',
  'lib/ui/widgets/fa_mark.dart': 'test/golden/chat_golden_test.dart',
  'lib/ui/widgets/model_mark.dart': 'test/golden/widgets_golden_test.dart',
  'lib/ui/widgets/session_sidebar.dart': 'test/golden/sidebar_golden_test.dart',
  'lib/ui/widgets/file_browser.dart': 'test/golden/files_golden_test.dart',
  'lib/ui/widgets/file_preview.dart': 'test/golden/files_golden_test.dart',
  'lib/ui/widgets/approval_ui.dart': 'test/golden/dialogs_golden_test.dart',
  'lib/ui/widgets/ask_ui.dart': 'test/golden/dialogs_golden_test.dart',
  'lib/apps/app_icon.dart': 'test/golden/apps_golden_test.dart',
  'lib/apps/apps_grid.dart': 'test/golden/apps_golden_test.dart',
  'lib/apps/fa_work_bar.dart': 'test/golden/apps_golden_test.dart',
  'lib/apps/js_app_view.dart': 'test/golden/apps_golden_test.dart',
  'lib/ui/widgets/downloaded_models_quick_start.dart':
      'test/golden/sections_golden_test.dart',
  'lib/gemma/gemma_cache_section.dart': 'test/golden/sections_golden_test.dart',
  'lib/webllm/webllm_cache_section.dart':
      'test/golden/sections_golden_test.dart',
  'lib/transformers_js/transformers_js_cache_section.dart':
      'test/golden/sections_golden_test.dart',
  'lib/ui/widgets/html_preview_stub.dart':
      'test/golden/sections_golden_test.dart',
};

/// Widget files that legitimately cannot be snapshot-tested on the host.
const _exempt = <String, String>{
  'lib/ui/widgets/html_preview_web.dart':
      'web-only conditional implementation; the '
      'stub variant (same widget API) is covered instead',
};

final _widgetPattern = RegExp(
  r'extends\s+(StatelessWidget|StatefulWidget|ConsumerWidget)\b',
);

Iterable<String> _libWidgetFiles() sync* {
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = entity.path.replaceAll('\\', '/');
    if (path.startsWith('lib/l10n/')) continue;
    if (_widgetPattern.hasMatch(entity.readAsStringSync())) yield path;
  }
}

void main() {
  group('golden coverage guard', () {
    test('every lib widget file is covered or explicitly exempt', () {
      final uncovered = <String>[
        for (final file in _libWidgetFiles())
          if (!_coverage.containsKey(file) && !_exempt.containsKey(file)) file,
      ];
      expect(
        uncovered,
        isEmpty,
        reason:
            'Widget files without golden coverage — add golden tests in '
            'test/golden/ and register the file in golden_guard_test.dart:\n'
            '${uncovered.join('\n')}',
      );
    });

    test('coverage map points at real golden tests with real assertions', () {
      final problems = <String>[];
      for (final entry in _coverage.entries) {
        final libFile = File(entry.key);
        if (!libFile.existsSync()) {
          problems.add(
            '${entry.key}: lib file no longer exists — remove or '
            'update the map entry',
          );
          continue;
        }
        final testFile = File(entry.value);
        if (!testFile.existsSync()) {
          problems.add('${entry.key}: golden test ${entry.value} is missing');
          continue;
        }
        final content = testFile.readAsStringSync();
        if (!content.contains('matchesGoldenFile') &&
            !content.contains('expectGolden(')) {
          problems.add('${entry.value}: no golden assertion found');
        }
        // The golden test must reference the lib file's widgets — a bare
        // basename mention is the cheapest robust proxy.
        final base = entry.key.split('/').last.replaceAll('.dart', '');
        if (!content.contains(base) &&
            !content.contains(entry.key.replaceAll('lib/', 'package:fa/'))) {
          problems.add('${entry.value}: never references ${entry.key}');
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    test('every golden test has generated snapshots on disk', () {
      final goldenDir = Directory('test/golden/goldens');
      expect(
        goldenDir.existsSync(),
        isTrue,
        reason: 'run `flutter test test/golden --update-goldens`',
      );
      final problems = <String>[];
      for (final testPath in _coverage.values.toSet()) {
        final testFile = File(testPath);
        if (!testFile.existsSync()) continue;
        // Golden names are referenced either via the helper
        // (expectGolden(tester, 'name')) or directly
        // (matchesGoldenFile('goldens/name.png')).
        final content = testFile.readAsStringSync();
        final names = <String>{
          ...RegExp(
            r"expectGolden\(\s*tester,\s*'([^']+)'",
          ).allMatches(content).map((m) => m.group(1)!),
          ...RegExp(
            r"matchesGoldenFile\('goldens/([a-z0-9_/.-]+)\.png'\)",
          ).allMatches(content).map((m) => m.group(1)!),
        };
        if (names.isEmpty) {
          problems.add('$testPath: no goldens/<name>.png references found');
          continue;
        }
        for (final name in names) {
          if (!File('test/golden/goldens/$name.png').existsSync()) {
            problems.add(
              '$testPath: missing snapshot goldens/$name.png — '
              'run `flutter test test/golden --update-goldens`',
            );
          }
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  });
}
