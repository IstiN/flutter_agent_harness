// gh-2463 — release_notes.sh consumes the changelog/entries aggregate.
//
// New preference level 1b in scripts/release_notes.sh: after the curated
// `## <version>` section, the pending changelog/entries/*.md aggregate (via
// scripts/gen_changelog.dart) becomes the release body; the legacy curated
// `## Unreleased` file body drops to level 1c and still wins over the
// conventional-commits fallback. AC2 parity: for the same set of changes the
// new flow (entry files) and the old flow (curated Unreleased body) yield
// the same bullet set.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

final _tmpRoot = Directory.systemTemp.createTempSync('release-notes-entries-');

late String _notes;

ProcessResult _run(String version, String cwd) => Process.runSync(
  'bash',
  [_notes, version],
  workingDirectory: cwd,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);

String _fixture(String name) {
  final dir = '${_tmpRoot.path}/$name';
  Directory(dir).createSync(recursive: true);
  return dir;
}

void _entry(String dir, String name, String bullet) {
  Directory('$dir/changelog/entries').createSync(recursive: true);
  File('$dir/changelog/entries/$name').writeAsStringSync(
    '---\ntype: fix\nissue: ${name.split('-').first}\n---\n\n$bullet\n',
  );
}

void main() {
  setUpAll(() {
    _notes = File('scripts/release_notes.sh').absolute.path;
  });

  test(
    'level 1b — pending entries aggregate into the release body',
    () {
      final dir = _fixture('entries-level');
      _entry(dir, '7-feat.md', '- entry feat bullet');
      _entry(dir, '12-fix.md', '- entry fix bullet');
      final r = _run('1.2.3', dir);
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, contains('- entry feat bullet'));
      expect(r.stdout, contains('- entry fix bullet'));
      // No conventional-commits fallback noise mixed in.
      expect(r.stdout, isNot(contains("What's changed")));
    },
  );

  test(
    'level 1 still wins — a curated ## <version> section outranks entries',
    () {
      final dir = _fixture('curated-wins');
      _entry(dir, '7-feat.md', '- entry bullet');
      File(
        '$dir/CHANGELOG.md',
      ).writeAsStringSync('# Changelog\n\n## 1.2.3\n\n- curated wins\n');
      final r = _run('1.2.3', dir);
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, contains('- curated wins'));
      expect(r.stdout, isNot(contains('- entry bullet')));
    },
  );

  test(
    'legacy level 1c — a curated ## Unreleased body still outranks commits '
    'but loses to entries',
    () {
      final dir = _fixture('legacy-unreleased');
      _entry(dir, '7-feat.md', '- entry bullet');
      File('$dir/CHANGELOG.md').writeAsStringSync(
        '# Changelog\n\n## Unreleased\n\n- legacy body bullet\n',
      );
      final r = _run('1.2.3', dir);
      expect(r.exitCode, 0, reason: r.stderr);
      expect(r.stdout, contains('- entry bullet'));
      expect(r.stdout, isNot(contains('- legacy body bullet')));
    },
  );

  test('no entries dir and no CHANGELOG.md → commit fallback unchanged', () {
    final dir = _fixture('fallback');
    Directory('$dir/changelog').createSync();
    Process.runSync(
      'git',
      ['init', '-q'],
      workingDirectory: dir,
    );
    Process.runSync(
      'git',
      ['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '--allow-empty',
        '-qm', 'feat: fallback subject'],
      workingDirectory: dir,
    );
    final r = _run('1.2.3', dir);
    expect(r.exitCode, 0, reason: r.stderr);
    expect(r.stdout, contains('feat: fallback subject'));
  });

  test(
    'AC2 parity — same changes: old flow (curated Unreleased body) and new '
    'flow (entry files) produce the same bullet set',
    () {
      final bullets = '- fix: alpha one\n- fix: beta two\n- feat: gamma three\n';
      final oldDir = _fixture('parity-old');
      File(
        '$oldDir/CHANGELOG.md',
      ).writeAsStringSync('# Changelog\n\n## Unreleased\n\n$bullets\n');
      final newDir = _fixture('parity-new');
      _entry(newDir, '1-a.md', '- fix: alpha one');
      _entry(newDir, '2-b.md', '- fix: beta two');
      _entry(newDir, '3-c.md', '---\ntype: feat\nissue: 3\n---\n\n- feat: gamma three\n');
      final oldOut = _run('1.2.3', oldDir).stdout;
      final newOut = _run('1.2.3', newDir).stdout;
      Set<String> bulletSet(String out) => out
          .split('\n')
          .where((l) => l.startsWith('- '))
          .toSet();
      expect(bulletSet(newOut), bulletSet(oldOut));
      expect(bulletSet(newOut), isNotEmpty);
    },
  );
}
