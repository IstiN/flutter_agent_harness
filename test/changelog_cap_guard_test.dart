// gh-1452 — CHANGELOG size guard: pub.dev server-rejects a publish whose
// CHANGELOG.md exceeds its hard 262144-byte content cap (`Message from
// server: CHANGELOG.md exceeds the maximum content length`) — v1.0.538 died
// at `dart pub publish` AFTER the tag + GitHub release existed, so the
// version never reached pub.dev. The changelog is append-only by convention
// and the near-daily auto-release grows it without bound.
//
// The guard lives in scripts/check_changelog_size.sh and must stay wired
// into BOTH changelog surfaces (gh-1522 rework):
//   - scripts/stamp_staged_release.sh — pre-upload: the stage-time stamper
//     prepends the tag's generated section to the STAGED changelog, then
//     re-measures it (trimming oldest staged sections if over) — the repo
//     file stays curated-only and the published artifact can never trip
//     the server-side cap;
//   - ci.yml `publish` job gate — pre-staging: the repo CHANGELOG.md is
//     authored by humans now; an over-cap repo file fails fast before the
//     stage even runs.
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

  test('stamp_staged_release.sh runs the guard after prepending the tag section', () {
    final stamp = read('scripts/stamp_staged_release.sh');
    final prepend = stamp.indexOf('mv "$changelog.new" "$changelog"');
    final guard = stamp.indexOf('check_changelog_size.sh');
    expect(prepend, greaterThan(0),
        reason: 'fixture: the section prepend must be locatable');
    expect(guard, greaterThan(prepend),
        reason: 'the guard must measure the POST-section staged changelog — '
            'the stage just grew by the fresh tag section (gh-1522)');
  });

  test('stamp_staged_release.sh trims staged sections and re-checks when over the cap', () {
    final stamp = read('scripts/stamp_staged_release.sh');
    expect(stamp, contains('trimming oldest staged sections'));
    final trim = stamp.indexOf('trimming oldest staged sections');
    final recheck = stamp.indexOf('check_changelog_size.sh "$changelog"', trim);
    expect(recheck, greaterThan(trim),
        reason: 'after the trim the staged changelog must be re-measured — '
            'a trim that cannot reach under the cap fails loudly');
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
