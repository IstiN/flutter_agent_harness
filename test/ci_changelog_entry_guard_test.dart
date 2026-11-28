// gh-2463 — CI changelog entries guard (`scripts/check_changelog_entry.py`).
//
// The changelog merge surface is per-entry files now. The guard pins the
// two structural rules of the new flow:
//   1. a PR must ADD at least one `changelog/entries/<issue-or-pr>-<slug>.md`
//      file — or carry the `no-changelog` label (pull_request events only;
//      without PR label context the requirement degrades to a ::warning::
//      so dispatch re-validations never false-red);
//   2. NO PR may hand-edit the generated CHANGELOG.md, the root
//      CHANGELOG_ARCHIVE.md, or changelog/archive/** (hard everywhere).
// Wiring in the ci.yml `static` job is pinned too, and the repo allow-list
// must carry the new `changelog/` root dir.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

final _tmpRoot = Directory.systemTemp.createTempSync('changelog-entry-guard-');

late String _guard;

ProcessResult _run(List<String> args, String cwd) => Process.runSync(
  'python3',
  [_guard, ...args],
  workingDirectory: cwd,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);

/// Fixture repo with an initial commit so diffs have a base.
String _repo(String name) {
  final dir = '${_tmpRoot.path}/$name';
  Directory(dir).createSync(recursive: true);
  void git(List<String> args) => Process.runSync(
    'git',
    ['-c', 'user.email=t@t', '-c', 'user.name=t', ...args],
    workingDirectory: dir,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  git(['init', '-q', '-b', 'main']);
  File('$dir/CHANGELOG.md').writeAsStringSync('# Changelog\n');
  File('$dir/README.md').writeAsStringSync('# t\n');
  git(['add', '-A']);
  git(['commit', '-qm', 'init']);
  return dir;
}

void _commit(String dir, String msg) => Process.runSync(
  'git',
  ['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', msg],
  workingDirectory: dir,
);

String _addEntry(String dir, String name) {
  final path = '$dir/changelog/entries/$name';
  File(path).parent.createSync(recursive: true);
  File(path).writeAsStringSync(
    '---\ntype: fix\nissue: ${name.split('-').first}\n---\n\n- bullet\n',
  );
  return path;
}

void main() {
  setUpAll(() {
    _guard = File('scripts/check_changelog_entry.py').absolute.path;
  });

  test('PR adding an entry file and nothing else → pass', () {
    final dir = _repo('entry-added');
    _addEntry(dir, '100-fix.md');
    Process.runSync('git', ['add', '-A'], workingDirectory: dir);
    _commit(dir, 'feat: x');
    final r = _run(['--base', 'HEAD~1', '--head', 'HEAD', '--pr-context', 'true'], dir);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
  });

  test('PR editing CHANGELOG.md directly (≠ regenerated) → ::error::, exit 1',
    () {
    final dir = _repo('changelog-edit');
    _addEntry(dir, '101-fix.md'); // has an entry, still forbidden
    File('$dir/CHANGELOG.md').writeAsStringSync('# hand edited\n');
    Process.runSync('git', ['add', '-A'], workingDirectory: dir);
    _commit(dir, 'edit');
    final r = _run(['--base', 'HEAD~1', '--head', 'HEAD', '--pr-context', 'true'], dir);
    expect(r.exitCode, 1);
    expect(r.stdout, contains('::error::'));
    expect(r.stdout, contains('CHANGELOG.md'));
  });

  test(
    'a pure generator rewrite of CHANGELOG.md passes (gh-2463 migration/'
    'regeneration path)',
    () {
      final dir = _repo('generator-rewrite');
      _addEntry(dir, '102-fix.md');
      // Regenerate FOR REAL (dart is on PATH in the test environment):
      // the committed CHANGELOG.md must equal the generator's output.
      final gen = Process.runSync('dart', [
        File('scripts/gen_changelog.dart').absolute.path,
        '--write-changelog',
      ], workingDirectory: dir, stdoutEncoding: utf8, stderrEncoding: utf8);
      expect(gen.exitCode, 0, reason: gen.stderr);
      Process.runSync('git', ['add', '-A'], workingDirectory: dir);
      _commit(dir, 'chore: regenerate changelog');
      final r = _run(['--base', 'HEAD~1', '--head', 'HEAD', '--pr-context', 'true'], dir);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    },
  );

  test('archive ADDITION passes (the migration/housekeeping path)', () {
    final dir = _repo('archive-add');
    _addEntry(dir, '103-fix.md');
    File('$dir/changelog/archive/1.0.551.md').parent.createSync(recursive: true);
    File('$dir/changelog/archive/1.0.551.md').writeAsStringSync('## 1.0.551\n');
    Process.runSync('git', ['add', '-A'], workingDirectory: dir);
    _commit(dir, 'archive add');
    final r = _run(['--base', 'HEAD~1', '--head', 'HEAD', '--pr-context', 'true'], dir);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
  });

  test('archive MODIFICATION (history rewrite) → exit 1', () {
    final dir = _repo('archive-edit');
    // An archive file that ALREADY EXISTS in the base commit.
    final archive = '$dir/changelog/archive/1.0.551.md';
    Directory(archive).parent.createSync(recursive: true);
    File(archive).writeAsStringSync('## 1.0.551\n');
    Process.runSync('git', ['add', '-A'], workingDirectory: dir);
    _commit(dir, 'seed archive');
    File(archive).writeAsStringSync('## 1.0.551\n\n- tampered\n');
    Process.runSync('git', ['add', '-A'], workingDirectory: dir);
    _commit(dir, 'rewrite history');
    final r = _run(['--base', 'HEAD~1', '--head', 'HEAD', '--pr-context', 'true'], dir);
    expect(r.exitCode, 1);
    expect(r.stdout, contains('::error::'));
    expect(r.stdout, contains('changelog/archive'));
  });

  test('CHANGELOG_ARCHIVE.md (root tail) modification → exit 1', () {
    final dir = _repo('root-archive-edit');
    final tail = '$dir/CHANGELOG_ARCHIVE.md';
    File(tail).writeAsStringSync('# archive tail\n');
    Process.runSync('git', ['add', '-A'], workingDirectory: dir);
    _commit(dir, 'seed tail');
    File(tail).writeAsStringSync('# rewritten\n');
    Process.runSync('git', ['add', '-A'], workingDirectory: dir);
    _commit(dir, 'rewrite tail');
    final r = _run(['--base', 'HEAD~1', '--head', 'HEAD', '--pr-context', 'true'], dir);
    expect(r.exitCode, 1);
    expect(r.stdout, contains('::error::'));
    expect(r.stdout, contains('CHANGELOG_ARCHIVE.md'));
  });

  test('no entry file and no label (pr context) → exit 1', () {
    final dir = _repo('no-entry');
    File('$dir/lib.dart').writeAsStringSync('void f() {}\n');
    Process.runSync('git', ['add', '-A'], workingDirectory: dir);
    _commit(dir, 'code');
    final r = _run(['--base', 'HEAD~1', '--head', 'HEAD', '--pr-context', 'true'], dir);
    expect(r.exitCode, 1);
    expect(r.stdout, contains('::error::'));
    expect(r.stdout, contains('no-changelog'));
  });

  test('no-changelog label waives the entry requirement', () {
    final dir = _repo('labeled');
    File('$dir/lib.dart').writeAsStringSync('void f() {}\n');
    Process.runSync('git', ['add', '-A'], workingDirectory: dir);
    _commit(dir, 'code');
    final r = _run(
      ['--base', 'HEAD~1', '--head', 'HEAD', '--pr-context', 'true',
        '--labels', 'no-changelog,ci'],
      dir,
    );
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
  });

  test('an unrelated label does NOT waive the requirement', () {
    final dir = _repo('wrong-label');
    File('$dir/lib.dart').writeAsStringSync('void f() {}\n');
    Process.runSync('git', ['add', '-A'], workingDirectory: dir);
    _commit(dir, 'code');
    final r = _run(
      ['--base', 'HEAD~1', '--head', 'HEAD', '--pr-context', 'true',
        '--labels', 'some-other-label'],
      dir,
    );
    expect(r.exitCode, 1);
  });

  test(
    'no entry and NO pr-context (dispatch/push arm) → ::warning::, exit 0',
    () {
      final dir = _repo('dispatch');
      File('$dir/lib.dart').writeAsStringSync('void f() {}\n');
      Process.runSync('git', ['add', '-A'], workingDirectory: dir);
      _commit(dir, 'code');
      final r = _run(['--base', 'HEAD~1', '--head', 'HEAD'], dir);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(r.stdout, contains('::warning::'));
    },
  );

  test('empty diff (already-merged push) → pass', () {
    final dir = _repo('empty-diff');
    final r = _run(['--base', 'HEAD', '--head', 'HEAD', '--pr-context', 'true'], dir);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
  });

  test('added-but-deleted entry net change still counts as added', () {
    // A PR that adds an entry file and ALSO deletes a DIFFERENT entry file
    // (housekeeping of its own consumed entry) satisfies the requirement.
    final dir = _repo('housekeeping');
    _addEntry(dir, '200-keep.md');
    _addEntry(dir, '190-consumed.md');
    Process.runSync('git', ['add', '-A'], workingDirectory: dir);
    _commit(dir, 'entries');
    File('$dir/changelog/entries/190-consumed.md').deleteSync();
    _addEntry(dir, '210-new.md');
    Process.runSync('git', ['add', '-A'], workingDirectory: dir);
    _commit(dir, 'housekeep');
    final r = _run(['--base', 'HEAD~1', '--head', 'HEAD', '--pr-context', 'true'], dir);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
  });

  test('ci.yml static job wires the guard (self-test + real run)', () {
    final wf = File('.github/workflows/ci.yml').readAsStringSync();
    expect(wf, contains('scripts/check_changelog_entry.py --self-test'));
    expect(wf, contains('python3 scripts/check_changelog_entry.py'));
  });

  test('the real repo passes the guard (allow-list carries changelog/)', () {
    final r = Process.runSync(
      'python3',
      [File('scripts/check_root_allowlist.py').absolute.path],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
  });
}
