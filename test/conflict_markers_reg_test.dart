// REG guard for the gh-1049 CI breakage family: a merge abandoned
// mid-resolution left literal git conflict markers (`<<<<<<< HEAD` /
// `=======` / `>>>>>>> origin/main`) COMMITTED into source files. The
// markers are parse errors for `dart analyze`/`dart test` (the suite cannot
// even LOAD — Static gates, Core tests, Hostile-env and both PTY shards all
// went red on the same root cause), and a marker inside `memory/.gitattributes`
// additionally corrupts git attribute parsing repo-wide (a warning on every
// git invocation).
//
// Hermetic source grep (no PTY, no network), runs in the DEFAULT suite so
// the pre-commit fast gate enforces it: no commit may carry a conflict
// marker. A real merge resolves before it is committed — `git status`
// surfaces the conflicted paths and this guard is the belt to those
// suspenders.
import 'dart:io';

import 'package:test/test.dart';

/// Directories scanned. `memory/` is included because its `.gitattributes`
/// broke repo-wide git parsing in the gh-1049 breakage; `input/` and
/// `outputs/` are job-harness folders (gitignored, not source).
const _roots = ['lib', 'bin', 'test', 'memory'];

/// Marker shapes: git writes exactly 7 characters for the middle marker;
/// the opening/closing markers carry the label (`HEAD` / `origin/main`)
/// after a space. The bare `=======` shape doubles as a legal Markdown
/// setext underline, so it is only a marker in NON-Markdown files; `.md`
/// files are still checked for the unambiguous `<<<<<<<`/`>>>>>>>` shapes.
final _markerPatterns = [RegExp(r'^<<<<<<<($| )'), RegExp(r'^>>>>>>>($| )')];
const _mdOnlySafeMarker = r'^=======$';

void main() {
  test('no committed git conflict markers in source trees (gh-1049)', () {
    final violations = <String>[];
    for (final root in _roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      final files =
          dir
              .listSync(recursive: true)
              .whereType<File>()
              // Skip derived artifacts (rebuilt on load, never committed).
              .where(
                (f) =>
                    !f.path.contains('/.git/') &&
                    !f.path.endsWith('.revision') &&
                    !f.path.endsWith('/GRAPH.md') &&
                    !f.path.endsWith('/INDEX.md'),
              )
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        var text = '';
        try {
          text = file.readAsStringSync();
        } on FileSystemException {
          continue; // binary or unreadable — not a merge-marker carrier
        }
        final patterns = [
          ..._markerPatterns,
          if (!file.path.endsWith('.md')) RegExp(_mdOnlySafeMarker),
        ];
        final lines = text.split('\n');
        for (var i = 0; i < lines.length; i++) {
          for (final pattern in patterns) {
            if (pattern.hasMatch(lines[i])) {
              violations.add(
                '${file.path}:${i + 1}: literal git conflict marker '
                '`${lines[i].trim()}` — the merge must be resolved BEFORE '
                'committing; a committed marker fails dart analyze/test at '
                'parse (gh-1049 CI breakage).',
              );
            }
          }
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
