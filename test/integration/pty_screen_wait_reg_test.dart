// REG guard for the gh-1049 flake family: a bare `waitForScreen(...)` whose
// result is discarded, followed within a few lines by a fresh
// `screenText`/`viewportLines` read, samples the screen MID-RENDER — the wait
// returns the first frame containing the pattern (no settle) while pickers
// and cards paint their remaining rows a frame later, and the read loses
// that race on loaded CI hosts. The anchored convention is to CAPTURE the
// returned screen and assert on it (see `waitForScreen`'s doc in
// pty_harness.dart); re-reading the live screen is only legal after a
// `waitForOutput(settleMs:)` settle.
//
// This is a hermetic source grep (no PTY, no network) and deliberately runs
// in the DEFAULT suite (no integration tag) so the pre-commit gate enforces
// it — the flake it prevents only reproduces on loaded runners.
import 'dart:io';

import 'package:test/test.dart';

/// Screen-content reads that must be anchored on a captured waitForScreen
/// result (or follow a settle).
const _screenReads = [
  'screenText',
  'screenLines',
  'viewportLines',
  'viewportContentLines',
];

/// Wait/settle calls that end the danger window after a bare waitForScreen.
const _windowEnders = [
  'waitForScreen(',
  'waitForText(',
  'waitForOutput(',
  'waitForBoot(',
];

/// The primitive itself: its internal `screenText` polls ARE the wait.
const _excluded = {
  'pty_harness.dart',
  // This file's own scan literals would trip the naive matcher.
  'pty_screen_wait_reg_test.dart',
};

void main() {
  test(
    'no bare waitForScreen is followed by a mid-render screen read (gh-1049)',
    () {
      final violations = <String>[];
      final testDir = Directory('test');
      final files =
          testDir
              .listSync(recursive: true)
              .whereType<File>()
              .where(
                (f) =>
                    f.path.endsWith('.dart') &&
                    !_excluded.contains(f.uri.pathSegments.last),
              )
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));

      for (final file in files) {
        final lines = _codeLines(file.readAsLinesSync());
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (!line.contains('waitForScreen(')) continue;
          final captured =
              line.contains(RegExp(r'=\s*(await\s+)?[\w.]*waitForScreen')) ||
              (i > 0 && lines[i - 1].trimRight().endsWith('='));
          final end = _statementEnd(lines, i);
          for (var j = i + 1; j <= end + 4 && j < lines.length; j++) {
            final l = lines[j];
            if (_windowEnders.any(l.contains)) break;
            for (final read in _screenReads) {
              if (l.contains(read) && !captured) {
                violations.add(
                  '${file.path}:${j + 1}: `$read` read within the window of '
                  'a discarded waitForScreen at line ${i + 1}. Capture the '
                  'wait: `final screen = await harness.waitForScreen(marker)` '
                  'and assert on `screen` — a fresh screen re-read races the '
                  'picker/card rows that paint a frame later (gh-1049).',
                );
              }
            }
          }
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    },
  );

  test('_statementEnd ignores parens inside string literals (gh-1049 '
      'review)', () {
    // A marker string with an unbalanced `(` must not inflate the depth
    // scan: the statement ends on its own line, and the danger window must
    // not bleed into the FOLLOWING, unrelated statements.
    const lines = [
      "await h.waitForScreen('heading (of doom');",
      "final screen = h.screenText;",
      "expect(screen, contains('done'));",
    ];
    expect(
      _statementEnd(lines, 0),
      0,
      reason:
          "the `(` inside 'heading (of doom' is a string literal — the "
          'call closes on its own line',
    );
    expect(_statementEnd(lines, 2), 2);
  });
}

/// Strips full-line comments and trailing `//` comments (a `://` inside a
/// string URI is kept) so doc mentions of the APIs never trip the matcher.
List<String> _codeLines(List<String> raw) => [
  for (final line in raw)
    if (!line.trimLeft().startsWith('//') &&
        !line.trimLeft().startsWith('/*') &&
        !line.trimLeft().startsWith('*'))
      _stripTrailingComment(line),
];

String _stripTrailingComment(String line) {
  final idx = line.indexOf('//');
  if (idx <= 0) return line;
  if (line[idx - 1] == ':') return line; // scheme:// in a string literal
  return line.substring(0, idx);
}

/// The line where the call's opening `(` closes (bail-out at file end).
///
/// String literals are skipped while scanning (gh-1049 review): a marker
/// string containing an unbalanced `(` — `waitForScreen('heading (of doom')`
/// — otherwise never lets the depth reach 0 on the call's own lines and the
/// danger window bleeds into following, unrelated statements. The scan is
/// a heuristic: `${…}` interpolation carrying the OPPOSITE quote char, or a
/// raw multi-line string, can still confuse it — comment lines are stripped
/// before the scan and the four covered accessors are matched exactly, so a
/// diagnosable false positive beats a silent blind spot.
int _statementEnd(List<String> lines, int start) {
  var depth = 0;
  for (var j = start; j < lines.length; j++) {
    final line = lines[j];
    var quote = 0; // the open quote char (' or "), 0 = not in a literal
    for (var k = 0; k < line.length; k++) {
      final c = line.codeUnitAt(k);
      if (quote != 0) {
        if (c == 0x5c) {
          k++; // backslash escapes the next char inside the literal
        } else if (c == quote) {
          quote = 0;
        }
        continue;
      }
      if (c == 0x27 || c == 0x22) {
        quote = c; // ' or "
        continue;
      }
      if (c == 0x28) depth++; // (
      if (c == 0x29) depth--; // )
    }
    if (depth <= 0) return j;
  }
  return lines.length - 1;
}
