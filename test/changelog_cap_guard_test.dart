// gh-1452 — CHANGELOG size guard: pub.dev server-rejects a publish whose
// CHANGELOG.md exceeds its hard 262144-byte content cap (`Message from
// server: CHANGELOG.md exceeds the maximum content length`) — v1.0.538 died
// at `dart pub publish` AFTER the tag + GitHub release existed, so the
// version never reached pub.dev. The changelog is append-only by convention
// and the near-daily auto-release grows it without bound.
//
// The guard lives in scripts/check_changelog_size.sh and must stay wired
// into BOTH release surfaces:
//   - scripts/auto_release.sh — pre-tag: the bump push triggers tag_release,
//     so an over-cap changelog must fail the release BEFORE the push;
//   - ci.yml `publish` job gate — pre-upload: before staging + publish.
import 'dart:io';

import 'package:test/test.dart';

String read(String path) => File(path).readAsStringSync();

final _tmpRoot = Directory.systemTemp.createTempSync('changelog-cap-');

int _run(List<String> args, String cwd) => Process.runSync(
      'bash',
      <String>[File('scripts/check_changelog_size.sh').absolute.path, ...args],
      workingDirectory: cwd,
    ).exitCode;

ProcessResult _runOut(List<String> args, String cwd) => Process.runSync(
      'bash',
      <String>[File('scripts/check_changelog_size.sh').absolute.path, ...args],
      workingDirectory: cwd,
    );

String _fixture(String name) {
  final dir = Directory('${_tmpRoot.path}/$name')
    ..createSync(recursive: true);
  return dir.path;
}

void main() {
  test('under the cap passes (exit 0)', () {
    final dir = _fixture('under');
    File('$dir/CHANGELOG.md').writeAsStringSync('# Changelog\n\nsmall\n');
    expect(_run(const [], dir), 0);
  });

  test('exactly at the cap fails (cap is a strict less-than)', () {
    final dir = _fixture('at-cap');
    File('$dir/CHANGELOG.md').writeAsStringSync('x' * 100);
    final r = _runOut(['CHANGELOG.md', '100'], dir);
    expect(r.exitCode, 1);
    expect(r.stdout, contains('::error::'));
    expect(r.stdout, contains('100 bytes'));
  });

  test('over the cap fails naming the size, cap and the fix', () {
    final dir = _fixture('over');
    File('$dir/CHANGELOG.md').writeAsStringSync('x' * 101);
    final r = _runOut(['CHANGELOG.md', '100'], dir);
    expect(r.exitCode, 1);
    expect(r.stdout, contains('101 bytes'));
    expect(r.stdout, contains('100'));
    expect(r.stdout, contains('CHANGELOG_ARCHIVE.md'));
  });

  test('default cap is the pub.dev constant: 262145 bytes fails, 262143 passes', () {
    final dir = _fixture('default-cap');
    File('$dir/CHANGELOG.md').writeAsStringSync('x' * 262145);
    expect(_run(const [], dir), 1);
    File('$dir/CHANGELOG.md').writeAsStringSync('x' * 262143);
    expect(_run(const [], dir), 0);
  });

  test('missing changelog fails loudly', () {
    final dir = _fixture('missing');
    expect(_run(const [], dir), 1);
  });

  test('repo CHANGELOG.md is under the cap (the gh-1452 trim landed)', () {
    final f = File('CHANGELOG.md');
    expect(f.existsSync(), isTrue);
    expect(
      f.lengthSync(),
      lessThan(262144),
      reason: 'CHANGELOG.md regrew to the pub.dev cap on main — archive the '
          'tail to CHANGELOG_ARCHIVE.md again (gh-1452) before the next '
          'release server-rejects mid-upload.',
    );
  });

  test('repo keeps the archive sibling and references it inline', () {
    expect(File('CHANGELOG_ARCHIVE.md').existsSync(), isTrue);
    expect(read('CHANGELOG.md'), contains('CHANGELOG_ARCHIVE.md'));
  });

  test('auto_release.sh runs the guard after the changelog rewrite, before the bump commit', () {
    final auto = read('scripts/auto_release.sh');
    final rewrite = auto.indexOf('BULLETS');
    final guard = auto.indexOf('check_changelog_size.sh');
    final commit = auto.indexOf('git add pubspec.yaml');
    expect(guard, greaterThan(rewrite),
        reason: 'the guard must measure the POST-release-entry changelog');
    expect(guard, lessThan(commit),
        reason: 'an over-cap changelog must abort before the bump commit is '
            'authored and pushed (the push is what fires tag_release)');
  });

  test('ci.yml publish gate runs the guard before staging/upload', () {
    final ci = read('.github/workflows/ci.yml');
    final publish = ci.indexOf('  publish:');
    expect(publish, greaterThan(0));
    final gate = ci.indexOf('check_changelog_size.sh', publish);
    expect(gate, greaterThan(publish),
        reason: 'the publish job must fast-fail before dart pub publish — '
            'the server reject (v1.0.538) is the worst possible discovery '
            'point');
    final stage = ci.indexOf('stage_publish_package.sh /tmp/publish-stage', publish);
    expect(gate, lessThan(stage),
        reason: 'the guard belongs in the gate step, ahead of staging');
  });
}
