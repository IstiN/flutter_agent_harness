// Unit tests for the composer's path-candidate walk and TTL cache
// (issue #275). The walker lives behind the conditional import
// (path_candidates.dart) — the io variant is tested directly here.
library;

import 'dart:io';

import 'package:flutter_agent_harness/src/cli/path_candidates_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Directory previousCwd;

  setUp(() {
    previousCwd = Directory.current;
    temp = Directory.systemTemp.createTempSync('fah_path_candidates_');
    Directory.current = temp.path;
    resetPathCandidatesCache();
  });

  tearDown(() {
    Directory.current = previousCwd;
    temp.deleteSync(recursive: true);
  });

  test('walks breadth-first relative to the cwd', () {
    File('root.md').writeAsStringSync('');
    Directory('a').createSync();
    Directory('a/deep').createSync();
    File('a/inner.dart').writeAsStringSync('');
    File('a/deep/leaf.dart').writeAsStringSync('');

    final paths = workspaceFileCandidates();

    expect(paths, containsAll(['root.md', 'a/inner.dart', 'a/deep/leaf.dart']));
    // Shallow files complete first: root.md precedes the nested leaf.
    expect(paths.indexOf('root.md'), lessThan(paths.indexOf('a/deep/leaf.dart')));
    // Nothing is absolute — the composer splices these into the input.
    for (final p in paths) {
      expect(p.startsWith('/'), isFalse, reason: p);
    }
  });

  test('skips VCS and build directories', () {
    Directory('.git').createSync();
    File('.git/config').writeAsStringSync('');
    Directory('node_modules').createSync();
    File('node_modules/pkg.js').writeAsStringSync('');
    File('keep.txt').writeAsStringSync('');

    expect(workspaceFileCandidates(), ['keep.txt']);
  });

  test('caps the result at maxEntries', () {
    for (var i = 0; i < 20; i++) {
      File('f$i.txt').writeAsStringSync('');
    }
    expect(workspaceFileCandidates(maxEntries: 5).length, 5);
  });

  test('an unreadable directory is skipped, not fatal', () {
    Directory('locked').createSync();
    File('visible.txt').writeAsStringSync('');
    var lockedIsReadable = true;
    try {
      Directory('locked').listSync();
    } on FileSystemException {
      lockedIsReadable = false;
    }
    Process.runSync('chmod', ['000', 'locked']);
    try {
      final paths = workspaceFileCandidates();
      expect(paths, contains('visible.txt'));
      if (!lockedIsReadable) {
        expect(paths, isNot(contains(contains('locked'))));
      }
    } finally {
      Process.runSync('chmod', ['755', 'locked']);
    }
  });

  test('pathCandidatesFor caches the walk for the TTL window', () async {
    File('first.txt').writeAsStringSync('');
    expect(pathCandidatesFor(''), contains('first.txt'));

    // A file added right after the first call must NOT appear: the cache
    // is the frame-hitch fix (issue #275).
    File('second.txt').writeAsStringSync('');
    expect(pathCandidatesFor(''), isNot(contains('second.txt')));

    // The test hook forces the re-walk the 30s TTL would eventually do.
    await Future<void>.delayed(Duration.zero);
    resetPathCandidatesCache();
    expect(pathCandidatesFor(''), containsAll(['first.txt', 'second.txt']));
  });
}
