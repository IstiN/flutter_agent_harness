// gh-2185 AC7/AC6 — repo-root allow-list guard.
//
// The repository root carries only first-class project artifacts (source,
// docs, configs, CI). Runtime state JSONs, logs, generated dumps and the
// duplicate-store directories that accumulated at the root were purged in
// gh-2185; `scripts/check_root_allowlist.py` keeps the root that way:
//   - every TRACKED depth-0 entry must be allow-listed (a stray new file
//     fails pre-commit via ci_fast_gate.sh stage_analyze and the whole-tree
//     CI `static` job);
//   - any root entry whose NAME embeds an unexpanded template (`${...}`)
//     fails outright, tracked or not — the gh-2185 artifact class (a Dart
//     string template executed verbatim as a path, e.g. the empty
//     `${Directory.systemTemp.path}` directory the audit found).
import 'dart:io';

import 'package:test/test.dart';

final _tmpRoot = Directory.systemTemp.createTempSync('root-allowlist-');

/// The gh-2185 artifact name — an unexpanded Dart template executed
/// verbatim as a path (raw string so Dart never interpolates it).
const _templateDirName = r'${Directory.systemTemp.path}';

ProcessResult _runOut(List<String> args, String cwd) {
  return Process.runSync('python3', <String>[
    File('scripts/check_root_allowlist.py').absolute.path,
    ...args,
  ], workingDirectory: cwd);
}

/// Minimal git repo carrying only allow-listed root entries.
String _fixture(String name) {
  final dir = Directory('${_tmpRoot.path}/$name')..createSync(recursive: true);
  _git(dir.path, <String>['init', '-q']);
  File('${dir.path}/README.md').writeAsStringSync('# fixture\n');
  File('${dir.path}/pubspec.yaml').writeAsStringSync('name: fixture\n');
  _git(dir.path, <String>['add', '-A']);
  _git(dir.path, <String>[
    '-c',
    'user.email=t@t',
    '-c',
    'user.name=t',
    'commit',
    '-qm',
    'init',
  ]);
  return dir.path;
}

void _git(String dir, List<String> args) {
  final r = Process.runSync('git', args, workingDirectory: dir);
  expect(
    r.exitCode,
    0,
    reason: 'fixture git step failed: git ${args.join(' ')}\n${r.stderr}',
  );
}

void main() {
  test('shebang + executable bit (guard runs from hook and CI)', () {
    final f = File('scripts/check_root_allowlist.py');
    expect(f.existsSync(), isTrue, reason: 'the guard script must exist');
    expect(
      f.readAsStringSync().startsWith('#!'),
      isTrue,
      reason: 'guard script must start with a shebang',
    );
    expect(
      f.statSync().modeString().substring(0, 3),
      contains('x'),
      reason: 'guard script must be executable (hook/CI call it directly)',
    );
  });

  test(r'self-test: clean repo, stray file, and the ${...} template class', () {
    final r = _runOut(const ['--self-test'], '.');
    expect(
      r.exitCode,
      0,
      reason: 'guard self-test failed:\n${r.stdout}\n${r.stderr}',
    );
    expect(r.stdout, contains('self-test: PASS'));
  });

  test('a stray tracked root file fails with the state-dir pointer', () {
    final dir = _fixture('stray');
    File('$dir/chat_read_cursors.json').writeAsStringSync('{}');
    _git(dir, <String>['add', '-A']);
    _git(dir, <String>[
      '-c',
      'user.email=t@t',
      '-c',
      'user.name=t',
      'commit',
      '-qm',
      'stray',
    ]);
    final r = _runOut(const [], dir);
    expect(r.exitCode, 1);
    expect(r.stdout, contains('chat_read_cursors.json'));
    expect(r.stdout, contains('.fah/state'));
  });

  test(r'an untracked ${...}-named dir fails (gh-2185 artifact class)', () {
    final dir = _fixture('template');
    Directory('$dir/$_templateDirName').createSync();
    final r = _runOut(const [], dir);
    expect(r.exitCode, 1);
    expect(r.stdout, contains(_templateDirName));
  });

  test('wiring: ci_fast_gate.sh analyze stage runs the guard', () {
    final gate = File('scripts/ci_fast_gate.sh').readAsStringSync();
    final analyze = gate.indexOf('stage_analyze()');
    expect(analyze, greaterThan(0), reason: 'fixture: analyze stage exists');
    expect(
      gate.indexOf('check_root_allowlist.py', analyze),
      greaterThan(analyze),
      reason:
          'the guard must run inside the analyze stage so the hook '
          'path (docs-only commits included) pays it',
    );
  });

  test('wiring: ci.yml static job runs the guard whole-tree', () {
    final ci = File('.github/workflows/ci.yml').readAsStringSync();
    final staticJob = ci.indexOf('  static:');
    expect(staticJob, greaterThan(0), reason: 'fixture: static job exists');
    expect(
      ci.indexOf('check_root_allowlist.py', staticJob),
      greaterThan(staticJob),
      reason:
          'the Static gates job must invoke the guard — CI is the '
          'authority when hooks are skipped (--no-verify)',
    );
  });
}
