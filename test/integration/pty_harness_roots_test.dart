/// Harness-hygiene contract REG tests (gh-936): the PTY suites used to
/// share FIXED `/tmp` paths (`/tmp/fa_pty_cwd`, `/tmp/fa_<issue>_*`), so
/// two overlapping runs deleted each other's dirs mid-test —
/// `PathNotFoundException: Deletion failed, path = '/tmp/fa_539_home'`
/// and `Getting current working directory failed` under a live CLI.
///
/// The contract: every run gets a unique root (`fa_pty_` prefix), every
/// default-CWD spawn gets a unique git-shaped dir inside it, and the
/// [FaCliHarness.uniqueTempDir] helper never repeats a path.
@TestOn('vm')
@Tags(['io', 'integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  test('the run root is unique per run, short, and under /tmp', () {
    final root = FaCliHarness.runRoot;
    expect(root.path, startsWith('/tmp'),
        reason: 'short paths — the status row renders the cwd verbatim and '
            'elides the asserted tail segments on long paths');
    expect(root.basenameSync(), startsWith('fa_pty_'),
        reason: 'the leg-start preflight sweeps this exact prefix');
    expect(root.basenameSync().length, lessThanOrEqualTo(14),
        reason: 'the root doubles as the default cwd: keep it short');
    expect(root.existsSync(), isTrue);
  });

  test('default-CWD spawns share the per-run root with the checkout shape',
      () async {
    final first = await FaCliHarness.spawn(args: ['--help']);
    addTearDown(first.close);
    final second = await FaCliHarness.spawn(args: ['--help']);
    addTearDown(second.close);

    expect(first.workingDirectory, FaCliHarness.runRoot.path);
    expect(second.workingDirectory, FaCliHarness.runRoot.path);
    expect(Directory('${first.workingDirectory}/.git').existsSync(), isTrue,
        reason: 'the cwd keeps the checkout shape (git root discovery)');
  });

  test('uniqueTempDir never repeats a path and survives failure cleanup',
      () {
    final dirs = [
      for (var i = 0; i < 3; i++) FaCliHarness.uniqueTempDir('froot'),
    ];
    addTearDown(() {
      for (final dir in dirs) {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      }
    });
    expect(dirs.map((d) => d.path).toSet(), hasLength(dirs.length),
        reason: 'no two callers ever share a directory');
    for (final dir in dirs) {
      expect(dir.existsSync(), isTrue);
      expect(dir.basenameSync(), startsWith('froot'));
      expect(dir.path.length, lessThanOrEqualTo('/tmp/'.length + 5 + 4),
          reason: 'suite cwd paths stay short for the status row');
    }
  });
}

extension on Directory {
  String basenameSync() => path.split(Platform.pathSeparator).last;
}
